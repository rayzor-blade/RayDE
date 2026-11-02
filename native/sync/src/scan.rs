//! The desktop engine: reads a Git working tree into a manifest and the chunks it names. It runs `git` for what Git alone knows (the index,
//! ignore rules across nested files and global excludes, worktrees, the unborn case) and the file system for content. It never commits,
//! resets, checks out or writes into the repository, and it never uploads `.git`: history travels as a bundle of selected refs.
use crate::{
    FORMAT,
    chunk::{self, sha256_hex},
    exclude::{Decision, Selection, classify},
    ids::WorkspaceId,
    lifecycle::Limits,
    manifest::{BufferEntry, ChunkRef, FileEntry, FileKind, GitState, HistoryRef, IndexEntry, Manifest, Omission, Origin, Reason, Totals, link_problem},
};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    fs,
    io::{self, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Debug)]
pub enum ScanError {
    NotARepository(String),
    /// The folder is inside a repository but is not its top: Cloud Sync takes a whole working tree.
    NotTheTop { top: String },
    /// Git was busy or HEAD moved while scanning; the caller retries.
    Busy(String),
    Git(String),
    Io(io::Error),
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScanError::NotARepository(m) => write!(f, "not a Git repository: {m}"),
            ScanError::NotTheTop { top } => write!(f, "this folder is inside a repository whose top is {top}; open that folder to sync it"),
            ScanError::Busy(m) => write!(f, "Git is busy: {m}"),
            ScanError::Git(m) => write!(f, "git failed: {m}"),
            ScanError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ScanError {}

impl From<io::Error> for ScanError {
    fn from(e: io::Error) -> Self {
        ScanError::Io(e)
    }
}

/// An editor buffer with unsaved changes, from the editor's own state.
pub struct UnsavedBuffer {
    pub path: String,
    pub content: Vec<u8>,
}

pub struct Options {
    pub workspace: WorkspaceId,
    pub base_generation: u64,
    pub device: String,
    pub now_ms: u64,
    pub limits: Limits,
    pub selection: Selection,
    /// Whether the selected history goes too. Off is a working-tree-only snapshot.
    pub history: bool,
    pub buffers: Vec<UnsavedBuffer>,
}

/// Where a chunk's bytes are, so they can be read again when the upload asks for them.
#[derive(Clone, Debug)]
enum Source {
    File { path: PathBuf, offset: u64 },
    Memory(Vec<u8>),
    History { offset: u64 },
}

/// A manifest and the means to read the chunks it names. Dropping it removes the history bundle's temporary file.
pub struct Snapshot {
    pub manifest: Manifest,
    /// Things worth telling the person that are not omissions: a history over the budget, LFS.
    pub notes: Vec<String>,
    sources: BTreeMap<String, (Source, u32)>,
    bundle: Option<PathBuf>,
}

impl Snapshot {
    /// The unique chunks to store, with their sizes.
    pub fn chunks(&self) -> impl Iterator<Item = (&str, u32)> {
        self.sources.iter().map(|(hash, (_, size))| (hash.as_str(), *size))
    }

    /// The bytes of one chunk, checked against its hash: a file that changed since the scan is an error, never a silent upload of other bytes.
    pub fn read_chunk(&self, hash: &str) -> io::Result<Vec<u8>> {
        let (source, size) = self.sources.get(hash).ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no such chunk in this snapshot"))?;
        let bytes = match source {
            Source::Memory(bytes) => bytes.clone(),
            Source::File { path, offset } => read_at(path, *offset, *size as usize)?,
            Source::History { offset } => read_at(self.bundle.as_ref().expect("a history chunk has a bundle"), *offset, *size as usize)?,
        };
        if sha256_hex(&bytes) != hash {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "the file changed after it was scanned"));
        }
        Ok(bytes)
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        if let Some(path) = &self.bundle {
            let _ = fs::remove_file(path);
        }
    }
}

fn read_at(path: &Path, offset: u64, size: usize) -> io::Result<Vec<u8>> {
    let mut file = fs::File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = vec![0u8; size];
    file.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn git(root: &Path, args: &[&str]) -> Result<Vec<u8>, ScanError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        // Nothing the repository's config or the environment says may make git prompt, page, or run something of the user's.
        .args(["-c", "core.quotepath=off", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "--no-optional-locks"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .map_err(|e| ScanError::Git(format!("could not run git: {e}")))?;
    if !output.status.success() {
        return Err(ScanError::Git(String::from_utf8_lossy(&output.stderr).trim().to_string()));
    }
    Ok(output.stdout)
}

fn text(bytes: Vec<u8>) -> String {
    String::from_utf8_lossy(&bytes).trim().to_string()
}

fn nul_list(bytes: &[u8]) -> Vec<Vec<u8>> {
    bytes.split(|b| *b == 0).filter(|p| !p.is_empty()).map(|p| p.to_vec()).collect()
}

/// Of paths that name one file on a case-insensitive disk, the first (in order) stays; the others are returned to be left out.
pub fn case_collisions(paths: &[String]) -> Vec<String> {
    let mut seen: BTreeMap<String, &String> = BTreeMap::new();
    let mut dropped = Vec::new();
    for path in paths {
        if seen.insert(path.to_lowercase(), path).is_some() {
            dropped.push(path.clone());
        }
    }
    dropped
}

/// The directory that made a path a cache or output, for one omission instead of thousands.
fn omission_path(path: &str, reason: Reason) -> String {
    if reason != Reason::Cache {
        return path.to_string();
    }
    let parts: Vec<&str> = path.split('/').collect();
    for (i, part) in parts.iter().enumerate().take(parts.len().saturating_sub(1)) {
        let known = ["node_modules", ".cache", "__pycache__", ".gradle", ".idea", ".haxelib", ".rayzor", ".haxe", ".sass-cache", ".next", ".nuxt", ".turbo", ".parcel-cache", ".pytest_cache", ".mypy_cache", ".venv", "bin", "obj", "dist", "build", "out", "target", "export", "output"];
        if known.contains(part) {
            return parts[..=i].join("/");
        }
    }
    path.to_string()
}

struct Content {
    size: u64,
    hash: String,
    chunks: Vec<ChunkRef>,
}

/// Reads and chunks a file, trying again if it changes underneath: a build or an editor saving mid-scan must not make a torn upload.
fn read_stable(path: &Path, sources: &mut BTreeMap<String, (Source, u32)>, limits: &Limits) -> io::Result<Option<Content>> {
    for _ in 0..3 {
        let before = fs::metadata(path)?;
        if before.len() > limits.max_file_bytes {
            return Ok(Some(Content { size: before.len(), hash: String::new(), chunks: vec![] }));
        }
        let mut hasher = Sha256::new();
        let mut found: Vec<(String, u32, u64)> = Vec::new();
        let pieces = chunk::chunks(fs::File::open(path)?, |piece, bytes| {
            hasher.update(bytes);
            found.push((piece.hash.clone(), piece.size as u32, piece.offset));
            Ok(())
        })?;
        let after = fs::metadata(path)?;
        let read: u64 = pieces.iter().map(|p| p.size as u64).sum();
        if before.len() == after.len() && before.modified().ok() == after.modified().ok() && read == after.len() {
            for (hash, size, offset) in found {
                sources.entry(hash).or_insert_with(|| (Source::File { path: path.to_path_buf(), offset }, size));
            }
            return Ok(Some(Content { size: read, hash: chunk::hex(&hasher.finalize()), chunks: pieces.iter().map(|p| ChunkRef { hash: p.hash.clone(), size: p.size as u32 }).collect() }));
        }
    }
    Ok(None)
}

/// What a walk over candidate paths yields: entries, what was left out and why, where each chunk's bytes are, and tracked files that are gone.
struct Collected {
    files: Vec<FileEntry>,
    omissions: BTreeSet<(String, u8)>,
    sources: BTreeMap<String, (Source, u32)>,
    deleted: Vec<String>,
    reasons: BTreeMap<u8, Reason>,
}

#[cfg_attr(unix, allow(unused_variables))]
/// Turns candidate paths under `root` into manifest entries: classifies each, reads it stably and chunks it.
fn collect(root: &Path, candidates: Vec<Vec<u8>>, tracked: &HashSet<Vec<u8>>, submodules: &BTreeSet<String>, index: &[IndexEntry], options: &Options) -> Collected {
    let reasons: BTreeMap<u8, Reason> = [Reason::GitInternal, Reason::Secret, Reason::Cache, Reason::SessionState, Reason::OsFile, Reason::TooLarge, Reason::UnsafeLink, Reason::Collision, Reason::Submodule, Reason::Excluded, Reason::Unstable, Reason::BadPath, Reason::Unreadable].into_iter().map(|r| (r as u8, r)).collect();
    let mut files: Vec<FileEntry> = Vec::new();
    let mut omissions: BTreeSet<(String, u8)> = BTreeSet::new();
    let mut omit = |path: String, reason: Reason| {
        omissions.insert((path, reason as u8));
    };
    let mut sources: BTreeMap<String, (Source, u32)> = BTreeMap::new();
    let mut deleted = Vec::new();

    let mut sorted = candidates;
    sorted.sort();
    sorted.dedup();
    for raw in sorted {
        let is_tracked = tracked.contains(&raw);
        let Ok(path) = String::from_utf8(raw.clone()) else {
            omit(String::from_utf8_lossy(&raw).to_string(), Reason::BadPath);
            continue;
        };
        if submodules.contains(&path) {
            omit(path, Reason::Submodule);
            continue;
        }
        match classify(&path, is_tracked, &options.selection) {
            Decision::Exclude(reason) | Decision::NeedsDecision(reason) => {
                omit(omission_path(&path, reason), reason);
                continue;
            }
            Decision::Include => {}
        }
        let full = root.join(&path);
        let meta = match fs::symlink_metadata(&full) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if is_tracked {
                    deleted.push(path);
                }
                continue;
            }
            Err(_) => {
                omit(path, Reason::Unreadable);
                continue;
            }
        };
        let origin = if is_tracked { Origin::Tracked } else { Origin::Untracked };
        if meta.file_type().is_symlink() {
            let target = fs::read_link(&full).ok().and_then(|t| t.to_str().map(crate::links::manifest_target));
            match target {
                Some(target) if link_problem(&path, &target).is_none() => {
                    let size = target.len() as u64;
                    files.push(FileEntry { path, kind: FileKind::Symlink, origin, size, hash: sha256_hex(target.as_bytes()), chunks: vec![], link: Some(target) });
                }
                _ => omit(path, Reason::UnsafeLink),
            }
            continue;
        }
        if !meta.is_file() {
            continue;
        }
        match read_stable(&full, &mut sources, &options.limits) {
            Ok(Some(read)) if read.hash.is_empty() => {
                let _ = read;
                omit(path, Reason::TooLarge);
            }
            Ok(Some(read)) => {
                #[cfg(unix)]
                let executable = std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o111 != 0;
                #[cfg(not(unix))]
                let executable = index.iter().any(|e| e.path == path && e.mode == "100755");
                files.push(FileEntry { path, kind: if executable { FileKind::Executable } else { FileKind::Regular }, origin, size: read.size, hash: read.hash, chunks: read.chunks, link: None });
            }
            Ok(None) => omit(path, Reason::Unstable),
            Err(_) => omit(path, Reason::Unreadable),
        }
    }

    // Names that are one file on a case-insensitive disk cannot both be stored.
    let names: Vec<String> = files.iter().map(|f| f.path.clone()).collect();
    for dropped in case_collisions(&names) {
        files.retain(|f| f.path != dropped);
        omit(dropped, Reason::Collision);
    }

    Collected { files, omissions, sources, deleted, reasons }
}

/// Reads the working tree at `root` into a snapshot.
pub fn scan(root: &Path, options: &Options) -> Result<Snapshot, ScanError> {
    let root = fs::canonicalize(root)?;
    let top = git(&root, &["rev-parse", "--show-toplevel"]).map_err(|e| ScanError::NotARepository(e.to_string()))?;
    let top = fs::canonicalize(text(top))?;
    if top != root {
        return Err(ScanError::NotTheTop { top: top.display().to_string() });
    }
    let lock = text(git(&root, &["rev-parse", "--git-path", "index.lock"])?);
    let lock = if Path::new(&lock).is_absolute() { PathBuf::from(lock) } else { root.join(lock) };
    if lock.exists() {
        return Err(ScanError::Busy("a Git operation is in progress".into()));
    }
    let head_at_start = git(&root, &["rev-parse", "--verify", "-q", "HEAD"]).ok().map(text);

    let tracked: HashSet<Vec<u8>> = nul_list(&git(&root, &["ls-files", "-z", "--cached"])?).into_iter().collect();
    let candidates = nul_list(&git(&root, &["ls-files", "-z", "--cached", "--others", "--exclude-standard"])?);
    let index_raw = git(&root, &["ls-files", "-z", "--stage"])?;
    let mut index = Vec::new();
    let mut submodules = BTreeSet::new();
    for entry in nul_list(&index_raw) {
        let entry = String::from_utf8_lossy(&entry).to_string();
        let Some((meta, path)) = entry.split_once('\t') else { continue };
        let mut fields = meta.split(' ');
        let (mode, oid, stage) = (fields.next().unwrap_or(""), fields.next().unwrap_or(""), fields.next().unwrap_or("0"));
        if mode == "160000" {
            submodules.insert(path.to_string());
        }
        index.push(IndexEntry { path: path.to_string(), mode: mode.to_string(), oid: oid.to_string(), stage: stage.parse().unwrap_or(0) });
    }

    let Collected { files, omissions, mut sources, mut deleted, reasons } = collect(&root, candidates, &tracked, &submodules, &index, options);

    let mut notes = Vec::new();
    let head = git(&root, &["rev-parse", "--verify", "-q", "HEAD"]).ok().map(text);
    if head != head_at_start {
        return Err(ScanError::Busy("HEAD moved while scanning".into()));
    }
    let branch = git(&root, &["symbolic-ref", "-q", "--short", "HEAD"]).ok().map(text).filter(|b| !b.is_empty());
    let unborn = head.is_none();
    let lfs = fs::read_to_string(root.join(".gitattributes")).is_ok_and(|a| a.contains("filter=lfs"));
    if lfs {
        notes.push("This repository uses Git LFS: pointer files are synced, the large objects are not.".into());
    }
    if !submodules.is_empty() {
        notes.push(format!("{} submodule(s) are listed but their content is not synced.", submodules.len()));
    }

    let mut bundle_path = None;
    let mut history = None;
    if options.history && !unborn {
        let temp = std::env::temp_dir().join(format!("rayde-sync-{}-{}.bundle", std::process::id(), &sha256_hex(root.to_string_lossy().as_bytes())[..12]));
        let made = git(&root, &["bundle", "create", &temp.to_string_lossy(), "--branches", "--tags", "HEAD"]).or_else(|_| git(&root, &["bundle", "create", &temp.to_string_lossy(), "HEAD"]));
        match made {
            Ok(_) => {
                let size = fs::metadata(&temp)?.len();
                if size > options.limits.max_history_bytes {
                    notes.push(format!("The Git history is {size} bytes, over the {} allowed: this snapshot has the working tree only.", options.limits.max_history_bytes));
                    let _ = fs::remove_file(&temp);
                } else {
                    let mut hasher = Sha256::new();
                    let mut found = Vec::new();
                    let pieces = chunk::chunks(fs::File::open(&temp)?, |piece, bytes| {
                        hasher.update(bytes);
                        found.push((piece.hash.clone(), piece.size as u32, piece.offset));
                        Ok(())
                    })?;
                    for (hash, size, offset) in found {
                        sources.entry(hash).or_insert((Source::History { offset }, size));
                    }
                    let refs = text(git(&root, &["bundle", "list-heads", &temp.to_string_lossy()])?)
                        .lines()
                        .filter_map(|l| l.split_once(' ').map(|(_, r)| r.to_string()))
                        .filter(|r| r.starts_with("refs/"))
                        .collect();
                    history = Some(HistoryRef { size, hash: chunk::hex(&hasher.finalize()), chunks: pieces.iter().map(|p| ChunkRef { hash: p.hash.clone(), size: p.size as u32 }).collect(), refs });
                    bundle_path = Some(temp);
                }
            }
            Err(e) => notes.push(format!("The Git history could not be exported: {e}")),
        }
    } else if !options.history {
        notes.push("History is not included: the cloud copy has this working tree and the current branch name, and cannot show or restore earlier commits.".into());
    }

    let mut buffers = Vec::new();
    for buffer in &options.buffers {
        let hash = sha256_hex(&buffer.content);
        let mut chunks = Vec::new();
        for piece in chunk::chunks(&buffer.content[..], |_, _| Ok(()))? {
            let bytes = buffer.content[piece.offset as usize..piece.offset as usize + piece.size].to_vec();
            sources.entry(piece.hash.clone()).or_insert((Source::Memory(bytes), piece.size as u32));
            chunks.push(ChunkRef { hash: piece.hash, size: piece.size as u32 });
        }
        let base = files.iter().find(|f| f.path == buffer.path).map(|f| f.hash.clone());
        buffers.push(BufferEntry { path: buffer.path.clone(), base, size: buffer.content.len() as u64, hash, chunks });
    }

    deleted.sort();
    let mut manifest = Manifest {
        format: FORMAT,
        workspace: options.workspace.clone(),
        generation: options.base_generation + 1,
        base_generation: options.base_generation,
        device: options.device.clone(),
        taken_at: options.now_ms,
        name: root.file_name().map_or_else(|| "workspace".into(), |n| n.to_string_lossy().into_owned()),
        git: GitState { branch, head, unborn, index, deleted, history, submodules: submodules.into_iter().collect(), lfs },
        files,
        buffers,
        omissions: omissions.into_iter().filter_map(|(path, reason)| reasons.get(&reason).map(|r| Omission { path, reason: *r })).collect(),
        totals: Totals::default(),
        checksum: String::new(),
    };
    manifest.finalize();
    Ok(Snapshot { manifest, notes, sources, bundle: bundle_path })
}

/// Reads a restored working tree, which has no `.git`, into a snapshot taken against `previous`: files are found by walking the tree under its own
/// `.gitignore` files, the ones `previous` listed as tracked stay tracked, and its Git section carries over with the deletions found now.
pub fn scan_tree(root: &Path, previous: &Manifest, options: &Options) -> Result<Snapshot, ScanError> {
    let root = fs::canonicalize(root)?;
    let tracked: HashSet<Vec<u8>> = previous.files.iter().filter(|f| f.origin == Origin::Tracked).map(|f| f.path.clone().into_bytes()).collect();
    let mut found: BTreeSet<Vec<u8>> = tracked.iter().cloned().collect();
    let walk = ignore::WalkBuilder::new(&root)
        .hidden(false)
        .parents(false)
        .git_global(false)
        .git_exclude(false)
        .require_git(false)
        .follow_links(false)
        .filter_entry(|entry| entry.file_name() != ".git")
        .build();
    for entry in walk {
        let entry = entry.map_err(|e| io::Error::other(e.to_string()))?;
        if entry.file_type().is_none_or(|kind| kind.is_dir()) {
            continue;
        }
        let Ok(relative) = entry.path().strip_prefix(&root) else { continue };
        found.insert(relative.to_string_lossy().replace('\\', "/").into_bytes());
    }
    let Collected { files, omissions, sources, mut deleted, reasons } = collect(&root, found.into_iter().collect(), &tracked, &previous.git.submodules.iter().cloned().collect(), &previous.git.index, options);
    deleted.sort();
    let mut manifest = Manifest {
        format: FORMAT,
        workspace: options.workspace.clone(),
        generation: options.base_generation + 1,
        base_generation: options.base_generation,
        device: options.device.clone(),
        taken_at: options.now_ms,
        name: previous.name.clone(),
        git: GitState { deleted, ..previous.git.clone() },
        files,
        buffers: Vec::new(),
        omissions: omissions.into_iter().filter_map(|(path, reason)| reasons.get(&reason).map(|r| Omission { path, reason: *r })).collect(),
        totals: Totals::default(),
        checksum: String::new(),
    };
    manifest.finalize();
    Ok(Snapshot { manifest, notes: Vec::new(), sources, bundle: None })
}
