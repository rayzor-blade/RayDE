//! The description of one synced generation of a workspace: its files as chunk references, the Git state to rebuild, unsaved editor buffers,
//! and what was left out and why. It is data: the desktop produces it, the gateway validates the same rules before accepting an upload and
//! again before publishing, and the checksum binds the whole to what was uploaded.
use crate::{
    FORMAT,
    chunk::{MAX_CHUNK, sha256_hex},
    ids::WorkspaceId,
    lifecycle::Limits,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct ChunkRef {
    /// SHA-256 of the chunk, lowercase hex.
    pub hash: String,
    pub size: u32,
}

/// How a file is stored. Executable is the only mode bit carried; other permissions are the sandbox's.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FileKind {
    Regular,
    Executable,
    /// A link inside the workspace: its target is relative and stays inside the tree. Never dereferenced.
    Symlink,
}

/// Whether Git knew the file when the generation was taken.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    Tracked,
    /// Not in the index; selected by ignore rules or by the person.
    Untracked,
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct FileEntry {
    /// `/`-separated, relative, normalized.
    pub path: String,
    pub kind: FileKind,
    pub origin: Origin,
    pub size: u64,
    /// SHA-256 of the whole content, lowercase hex.
    pub hash: String,
    /// The content as chunks in order; empty for an empty file and for a symlink.
    pub chunks: Vec<ChunkRef>,
    /// A symlink's target.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub link: Option<String>,
}

/// One Git index entry, so staged and unstaged state can be rebuilt without copying `.git`.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct IndexEntry {
    pub path: String,
    /// `100644`, `100755`, `120000` or `160000` (a submodule).
    pub mode: String,
    pub oid: String,
    /// 0, or 1 to 3 while a merge is unresolved.
    pub stage: u8,
}

/// The selected history as a Git bundle: refs and the objects they need, with no hooks, config or credentials.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct HistoryRef {
    pub size: u64,
    pub hash: String,
    pub chunks: Vec<ChunkRef>,
    /// The refs in the bundle, for example `refs/heads/main`.
    pub refs: Vec<String>,
}

#[derive(Clone, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub struct GitState {
    /// None when HEAD is detached or the repository has no commit.
    pub branch: Option<String>,
    pub head: Option<String>,
    /// A repository with no commit yet: files and index only, no bundle.
    pub unborn: bool,
    pub index: Vec<IndexEntry>,
    /// Tracked files absent from the working tree: the deletes to apply.
    pub deleted: Vec<String>,
    /// None for a working-tree-only snapshot: history is excluded, and the tradeoff is the person's to accept.
    pub history: Option<HistoryRef>,
    /// Submodule paths: listed, never dereferenced; their content needs its own authorized transfer.
    pub submodules: Vec<String>,
    /// Whether the repository uses Git LFS: pointers are files like any other and the objects are not included.
    pub lfs: bool,
}

/// An unsaved editor buffer, kept apart from the saved file it edits.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct BufferEntry {
    pub path: String,
    /// The hash of the saved content the buffer was edited from, if the file exists, so a reconciliation knows its base.
    pub base: Option<String>,
    pub size: u64,
    pub hash: String,
    pub chunks: Vec<ChunkRef>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reason {
    /// `.git` itself: never uploaded.
    GitInternal,
    /// A credential, key or environment secret: needs an explicit decision to include.
    Secret,
    /// Generated output or a package, LSP or editor cache: rebuildable.
    Cache,
    /// RayDE's own session state.
    SessionState,
    /// Operating system litter.
    OsFile,
    TooLarge,
    /// A symlink that is absolute, escapes the tree, or cannot be represented.
    UnsafeLink,
    /// A path that names the same file as another on a case-insensitive disk.
    Collision,
    Submodule,
    /// Left out by the person's choice.
    Excluded,
    /// Changed while it was being read, repeatedly.
    Unstable,
    /// A path that cannot be stored (not UTF-8, control characters, too long).
    BadPath,
    Unreadable,
}

/// Something left out of a generation, shown to the person before the first sync.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Omission {
    pub path: String,
    pub reason: Reason,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub struct Totals {
    pub files: u64,
    /// Expanded size of every file and symlink target.
    pub bytes: u64,
    /// The bytes that must be stored for this generation: unique chunks of files, buffers and history.
    pub stored_bytes: u64,
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub format: u32,
    pub workspace: WorkspaceId,
    /// This generation's number, one more than the one it was taken against.
    pub generation: u64,
    /// The generation the desktop saw as current: publication is a compare and swap against it.
    pub base_generation: u64,
    /// The device that took it, as the account directory names devices.
    pub device: String,
    /// Client time in milliseconds. Information only; the server's clock decides expiry.
    pub taken_at: u64,
    /// The folder's name, for display.
    pub name: String,
    pub git: GitState,
    pub files: Vec<FileEntry>,
    pub buffers: Vec<BufferEntry>,
    pub omissions: Vec<Omission>,
    pub totals: Totals,
    /// SHA-256 of the manifest with this field empty, in canonical order: see `finalize`.
    pub checksum: String,
}

/// A problem found in a manifest. `code` is stable, `message` is for people.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Problem {
    pub path: Option<String>,
    pub code: &'static str,
    pub message: String,
}

fn problem(path: Option<&str>, code: &'static str, message: impl Into<String>) -> Problem {
    Problem { path: path.map(String::from), code, message: message.into() }
}

fn is_hex(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Whether `path` can be stored in a workspace: relative, normalized, and inside it.
pub fn path_problem(path: &str, limits: &Limits) -> Option<&'static str> {
    if path.is_empty() || path.len() > limits.max_path_bytes {
        return Some("bad-path");
    }
    if path.starts_with('/') || path.contains('\\') || path.chars().any(|c| c.is_control()) {
        return Some("bad-path");
    }
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() > limits.max_path_depth || parts.iter().any(|p| p.is_empty() || *p == "." || *p == "..") {
        return Some("bad-path");
    }
    // `.git` names Git's own state, which is never uploaded; on a case-insensitive disk `.GIT` is the same directory.
    if parts.iter().any(|p| p.eq_ignore_ascii_case(".git")) {
        return Some("git-internal");
    }
    if parts[0] == ".rayde-session" {
        return Some("session-state");
    }
    None
}

/// Whether a symlink at `path` pointing to `target` stays inside the tree, judged by its text alone: it is never resolved on the disk.
pub fn link_problem(path: &str, target: &str) -> Option<&'static str> {
    if target.is_empty() || target.starts_with('/') || target.contains('\\') || target.contains('\0') || target.chars().nth(1) == Some(':') {
        return Some("unsafe-link");
    }
    let mut depth = path.matches('/').count() as i64;
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                depth -= 1;
                if depth < 0 {
                    return Some("unsafe-link");
                }
            }
            p if p.eq_ignore_ascii_case(".git") => return Some("unsafe-link"),
            _ => depth += 1,
        }
    }
    None
}

fn chunk_problems(owner: &str, size: u64, chunks: &[ChunkRef], out: &mut Vec<Problem>) {
    let mut sum = 0u64;
    for c in chunks {
        if !is_hex(&c.hash, 64) {
            out.push(problem(Some(owner), "bad-chunk", "a chunk hash is not 64 lowercase hex digits"));
        }
        if c.size == 0 || c.size as usize > MAX_CHUNK {
            out.push(problem(Some(owner), "bad-chunk", format!("a chunk of {} bytes is outside 1 to {MAX_CHUNK}", c.size)));
        }
        sum += c.size as u64;
    }
    if sum != size {
        out.push(problem(Some(owner), "size-mismatch", format!("its chunks add up to {sum} bytes, not {size}")));
    }
}

impl Manifest {
    /// Every rule a manifest must satisfy, with the limits it is held to. An empty result means it may be accepted.
    pub fn validate(&self, limits: &Limits) -> Vec<Problem> {
        let mut out = Vec::new();
        if self.format != FORMAT {
            out.push(problem(None, "format", format!("format {} is not the supported {FORMAT}", self.format)));
            return out;
        }
        if self.generation != self.base_generation + 1 {
            out.push(problem(None, "generation", "a generation is one more than the one it was taken against"));
        }
        if self.files.len() > limits.max_files {
            out.push(problem(None, "too-many-files", format!("{} files, at most {}", self.files.len(), limits.max_files)));
        }
        let (mut seen, mut folded): (BTreeMap<&str, ()>, BTreeMap<String, &str>) = (BTreeMap::new(), BTreeMap::new());
        let (mut bytes, mut files) = (0u64, 0u64);
        for f in &self.files {
            if let Some(code) = path_problem(&f.path, limits) {
                out.push(problem(Some(&f.path), code, "this path cannot be stored in a workspace"));
                continue;
            }
            if seen.insert(&f.path, ()).is_some() {
                out.push(problem(Some(&f.path), "duplicate", "listed twice"));
            }
            if let Some(other) = folded.insert(f.path.to_lowercase(), &f.path) {
                if other != f.path {
                    out.push(problem(Some(&f.path), "collision", format!("names the same file as {other} on a case-insensitive disk")));
                }
            }
            files += 1;
            bytes += f.size;
            if f.size > limits.max_file_bytes {
                out.push(problem(Some(&f.path), "too-large", format!("{} bytes, at most {}", f.size, limits.max_file_bytes)));
            }
            if !is_hex(&f.hash, 64) {
                out.push(problem(Some(&f.path), "bad-hash", "the content hash is not 64 lowercase hex digits"));
            }
            match f.kind {
                FileKind::Symlink => {
                    match f.link.as_deref() {
                        None => out.push(problem(Some(&f.path), "unsafe-link", "a symlink without a target")),
                        Some(target) => {
                            if let Some(code) = link_problem(&f.path, target) {
                                out.push(problem(Some(&f.path), code, "this link leaves the workspace or cannot be represented"));
                            }
                            if f.size != target.len() as u64 {
                                out.push(problem(Some(&f.path), "size-mismatch", "a link's size is its target's length"));
                            }
                        }
                    }
                    if !f.chunks.is_empty() {
                        out.push(problem(Some(&f.path), "bad-chunk", "a symlink has no content chunks"));
                    }
                }
                _ => {
                    if f.link.is_some() {
                        out.push(problem(Some(&f.path), "bad-entry", "only a symlink has a target"));
                    }
                    chunk_problems(&f.path, f.size, &f.chunks, &mut out);
                }
            }
        }
        // A path cannot be both a file and a directory: "a" and "a/b".
        for path in seen.keys() {
            let mut at = 0;
            while let Some(i) = path[at..].find('/') {
                at += i;
                if seen.contains_key(&path[..at]) {
                    out.push(problem(Some(path), "path-conflict", format!("{} is a file, and this is inside it", &path[..at])));
                }
                at += 1;
            }
        }
        for b in &self.buffers {
            if let Some(code) = path_problem(&b.path, limits) {
                out.push(problem(Some(&b.path), code, "this buffer's path cannot be stored in a workspace"));
            }
            if b.size > limits.max_buffer_bytes {
                out.push(problem(Some(&b.path), "too-large", format!("a buffer of {} bytes, at most {}", b.size, limits.max_buffer_bytes)));
            }
            if !is_hex(&b.hash, 64) || b.base.as_deref().is_some_and(|h| !is_hex(h, 64)) {
                out.push(problem(Some(&b.path), "bad-hash", "a hash is not 64 lowercase hex digits"));
            }
            chunk_problems(&b.path, b.size, &b.chunks, &mut out);
        }
        if self.buffers.len() > limits.max_buffers {
            out.push(problem(None, "too-many-buffers", format!("{} unsaved buffers, at most {}", self.buffers.len(), limits.max_buffers)));
        }
        for e in &self.git.index {
            if path_problem(&e.path, limits).is_some() || !["100644", "100755", "120000", "160000"].contains(&e.mode.as_str()) || !(is_hex(&e.oid, 40) || is_hex(&e.oid, 64)) || e.stage > 3 {
                out.push(problem(Some(&e.path), "bad-index", "an index entry is not a valid path, mode, object id and stage"));
            }
        }
        for d in &self.git.deleted {
            if path_problem(d, limits).is_some() {
                out.push(problem(Some(d), "bad-path", "a deleted path cannot be stored in a workspace"));
            }
        }
        if self.git.unborn && (self.git.history.is_some() || self.git.head.is_some()) {
            out.push(problem(None, "bad-git", "an unborn repository has no head and no history"));
        }
        if let Some(h) = &self.git.history {
            if !is_hex(&h.hash, 64) {
                out.push(problem(None, "bad-hash", "the history hash is not 64 lowercase hex digits"));
            }
            if h.size > limits.max_history_bytes {
                out.push(problem(None, "history-too-large", format!("history is {} bytes, at most {}", h.size, limits.max_history_bytes)));
            }
            chunk_problems("history", h.size, &h.chunks, &mut out);
        }
        if bytes > limits.max_expanded_bytes {
            out.push(problem(None, "too-large", format!("{bytes} bytes expanded, at most {}", limits.max_expanded_bytes)));
        }
        let computed = self.computed_totals();
        if (self.totals.files, self.totals.bytes) != (files, bytes) || self.totals != computed {
            out.push(problem(None, "totals", "the totals do not match the entries"));
        }
        if !self.verify() {
            out.push(problem(None, "checksum", "the checksum does not match the manifest"));
        }
        out
    }

    /// The totals the entries add up to.
    pub fn computed_totals(&self) -> Totals {
        let mut unique: BTreeMap<&str, u32> = BTreeMap::new();
        let all = self.files.iter().flat_map(|f| f.chunks.iter()).chain(self.buffers.iter().flat_map(|b| b.chunks.iter())).chain(self.git.history.iter().flat_map(|h| h.chunks.iter()));
        for c in all {
            unique.insert(&c.hash, c.size);
        }
        Totals { files: self.files.len() as u64, bytes: self.files.iter().map(|f| f.size).sum(), stored_bytes: unique.values().map(|s| *s as u64).sum() }
    }

    /// Puts every list in its canonical order, recomputes the totals and sets the checksum. A manifest is final once this has run.
    pub fn finalize(&mut self) {
        self.files.sort_by(|a, b| a.path.cmp(&b.path));
        self.buffers.sort_by(|a, b| a.path.cmp(&b.path));
        self.omissions.sort_by(|a, b| (&a.path, a.reason as u8).cmp(&(&b.path, b.reason as u8)));
        self.git.index.sort_by(|a, b| (&a.path, a.stage).cmp(&(&b.path, b.stage)));
        self.git.deleted.sort();
        self.git.submodules.sort();
        self.totals = self.computed_totals();
        self.checksum = self.checksum_value();
    }

    fn checksum_value(&self) -> String {
        let mut bare = self.clone();
        bare.checksum.clear();
        sha256_hex(&serde_json::to_vec(&bare).expect("a manifest serializes"))
    }

    pub fn verify(&self) -> bool {
        self.checksum == self.checksum_value()
    }

    /// The canonical bytes, as stored and uploaded.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("a manifest serializes")
    }

    /// Reads a manifest, refusing one from a newer format before looking at the rest.
    pub fn from_bytes(bytes: &[u8]) -> Result<Manifest, String> {
        let probe: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| format!("not a manifest: {e}"))?;
        match probe.get("format").and_then(|f| f.as_u64()) {
            Some(f) if f == FORMAT as u64 => serde_json::from_value(probe).map_err(|e| format!("not a manifest: {e}")),
            Some(f) => Err(format!("manifest format {f} is not the supported {FORMAT}")),
            None => Err("not a manifest: no format".into()),
        }
    }
}

#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;

    pub fn chunk(content: &[u8]) -> ChunkRef {
        ChunkRef { hash: sha256_hex(content), size: content.len() as u32 }
    }

    pub fn file(path: &str, content: &[u8]) -> FileEntry {
        FileEntry { path: path.into(), kind: FileKind::Regular, origin: Origin::Tracked, size: content.len() as u64, hash: sha256_hex(content), chunks: if content.is_empty() { vec![] } else { vec![chunk(content)] }, link: None }
    }

    pub fn manifest() -> Manifest {
        let mut m = Manifest {
            format: FORMAT,
            workspace: WorkspaceId::from_random(&[42; 32]),
            generation: 3,
            base_generation: 2,
            device: "device-1".into(),
            taken_at: 1_790_000_000_000,
            name: "game".into(),
            git: GitState {
                branch: Some("main".into()),
                head: Some("a".repeat(40)),
                unborn: false,
                index: vec![IndexEntry { path: "src/Main.hx".into(), mode: "100644".into(), oid: "b".repeat(40), stage: 0 }],
                deleted: vec!["old.txt".into()],
                history: None,
                submodules: vec![],
                lfs: false,
            },
            files: vec![
                file("src/Main.hx", b"class Main {}\n"),
                file("README.md", b"# game\n"),
                FileEntry { origin: Origin::Untracked, ..file("notes.txt", b"todo\n") },
                FileEntry { kind: FileKind::Symlink, size: 7, hash: sha256_hex(b"src/lib"), chunks: vec![], link: Some("src/lib".into()), ..file("current", b"") },
            ],
            buffers: vec![BufferEntry { path: "src/Main.hx".into(), base: Some(sha256_hex(b"class Main {}\n")), size: 20, hash: sha256_hex(b"class Main { var x; }\n"), chunks: vec![ChunkRef { hash: sha256_hex(b"class Main { var x; }\n"), size: 20 }] }],
            omissions: vec![Omission { path: ".env".into(), reason: Reason::Secret }, Omission { path: "node_modules".into(), reason: Reason::Cache }],
            totals: Totals::default(),
            checksum: String::new(),
        };
        m.finalize();
        m
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;

    fn codes(m: &Manifest) -> Vec<&'static str> {
        m.validate(&Limits::default()).iter().map(|p| p.code).collect()
    }

    /// Changes `m` and puts its totals and checksum right again, so only the change under test can be a problem.
    fn edit(mut m: Manifest, change: impl FnOnce(&mut Manifest)) -> Manifest {
        change(&mut m);
        m.finalize();
        m
    }

    #[test]
    fn a_good_manifest_has_no_problems_and_a_stable_checksum() {
        let m = manifest();
        assert!(m.validate(&Limits::default()).is_empty(), "{:?}", m.validate(&Limits::default()));
        assert!(m.verify());
        let mut again = manifest();
        again.files.reverse();
        again.finalize();
        assert_eq!(again.checksum, m.checksum, "order of entry does not matter once finalized");
    }

    #[test]
    fn the_golden_fixture_is_what_the_format_says_today() {
        // Every client and the gateway must read this file and agree on its checksum: a format change fails here first.
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/manifest-v1.json");
        if std::env::var("REGENERATE_FIXTURES").is_ok() {
            std::fs::write(path, serde_json::to_string_pretty(&manifest()).unwrap() + "\n").unwrap();
        }
        let stored = Manifest::from_bytes(&std::fs::read(path).expect("run once with REGENERATE_FIXTURES=1")).unwrap();
        assert_eq!(stored, manifest());
        assert!(stored.verify());
        assert!(stored.validate(&Limits::default()).is_empty());
    }

    #[test]
    fn any_change_breaks_the_checksum() {
        let mut m = manifest();
        m.files[0].size += 1;
        assert!(!m.verify());
        assert!(codes(&m).contains(&"checksum"));
        let mut m = manifest();
        m.omissions.clear();
        assert!(!m.verify());
    }

    #[test]
    fn a_newer_format_is_refused_before_anything_else() {
        let mut value = serde_json::to_value(manifest()).unwrap();
        value["format"] = serde_json::json!(2);
        assert!(Manifest::from_bytes(&serde_json::to_vec(&value).unwrap()).unwrap_err().contains("not the supported 1"));
        assert!(Manifest::from_bytes(b"{}").is_err() && Manifest::from_bytes(b"nope").is_err());
    }

    #[test]
    fn paths_that_leave_the_tree_or_name_git_are_refused() {
        for (path, code) in [
            ("../x", "bad-path"), ("/etc/passwd", "bad-path"), ("a//b", "bad-path"), ("a/./b", "bad-path"), ("a\\b", "bad-path"), ("a/\u{7}b", "bad-path"), ("", "bad-path"),
            (".git/config", "git-internal"), ("sub/.GIT/hooks/x", "git-internal"), (".rayde-session/state", "session-state"),
        ] {
            let m = edit(manifest(), |m| m.files.push(file(path, b"x")));
            assert!(codes(&m).contains(&code), "{path:?} should be {code}: {:?}", codes(&m));
        }
        let long = "a/".repeat(70) + "b";
        assert!(codes(&edit(manifest(), |m| m.files.push(file(&long, b"x")))).contains(&"bad-path"), "too deep");
        for fine in [".gitignore", ".github/workflows/ci.yml", "a b/c d.txt", "ünï/cödé.hx"] {
            assert!(edit(manifest(), |m| m.files.push(file(fine, b"x"))).validate(&Limits::default()).is_empty(), "{fine}");
        }
    }

    #[test]
    fn names_that_collide_on_a_case_insensitive_disk_or_clash_as_file_and_directory_are_reported() {
        let m = edit(manifest(), |m| m.files.push(file("readme.md", b"x")));
        assert_eq!(codes(&m), vec!["collision"]);
        let m = edit(manifest(), |m| m.files.push(file("README.md/inside.txt", b"x")));
        assert_eq!(codes(&m), vec!["path-conflict"]);
        let m = edit(manifest(), |m| m.files.push(file("notes.txt", b"again")));
        assert!(codes(&m).contains(&"duplicate"));
    }

    #[test]
    fn symlinks_must_stay_inside_and_are_never_followed() {
        let link = |path: &str, target: &str| {
            edit(manifest(), |m| m.files.push(FileEntry { kind: FileKind::Symlink, size: target.len() as u64, hash: sha256_hex(target.as_bytes()), chunks: vec![], link: Some(target.into()), ..file(path, b"") }))
        };
        assert!(link("a/ok", "../README.md").validate(&Limits::default()).is_empty(), "up one from a/ lands in the root");
        assert!(link("a/b/ok", "../../src/Main.hx").validate(&Limits::default()).is_empty());
        for (path, target) in [("a/up", "../../x"), ("top", "../x"), ("abs", "/etc/passwd"), ("win", "C:\\x"), ("git", ".git/config"), ("deep", "src/../../x"), ("empty", "")] {
            assert!(codes(&link(path, target)).contains(&"unsafe-link"), "{path} -> {target}: {:?}", codes(&link(path, target)));
        }
    }

    #[test]
    fn chunks_must_add_up_to_the_file_and_be_well_formed() {
        let m = edit(manifest(), |m| m.files[0].chunks[0].size += 1);
        assert!(codes(&m).contains(&"size-mismatch"));
        let m = edit(manifest(), |m| m.files[0].chunks[0].hash = "XYZ".into());
        assert!(codes(&m).contains(&"bad-chunk"));
        let m = edit(manifest(), |m| {
            m.files[0].size = MAX_CHUNK as u64 + 1;
            m.files[0].chunks = vec![ChunkRef { hash: sha256_hex(b"x"), size: MAX_CHUNK as u32 + 1 }];
        });
        assert!(codes(&m).contains(&"bad-chunk"), "a chunk over the maximum");
    }

    #[test]
    fn the_limits_hold_a_small_manifest_to_the_budget() {
        let tight = Limits { max_files: 2, max_file_bytes: 10, max_expanded_bytes: 20, ..Limits::default() };
        let problems: Vec<_> = manifest().validate(&tight).iter().map(|p| p.code).collect();
        assert!(problems.contains(&"too-many-files") && problems.contains(&"too-large"), "{problems:?}");
        let history = edit(manifest(), |m| m.git.history = Some(HistoryRef { size: 10, hash: sha256_hex(b"b"), chunks: vec![ChunkRef { hash: sha256_hex(b"b"), size: 10 }], refs: vec!["refs/heads/main".into()] }));
        let strict = Limits { max_history_bytes: 5, ..Limits::default() };
        assert!(history.validate(&strict).iter().any(|p| p.code == "history-too-large"));
        assert!(history.validate(&Limits::default()).is_empty());
    }

    #[test]
    fn git_state_is_checked_and_an_unborn_repository_has_no_history() {
        let m = edit(manifest(), |m| m.git.index[0].mode = "100666".into());
        assert!(codes(&m).contains(&"bad-index"));
        let m = edit(manifest(), |m| m.git.unborn = true);
        assert!(codes(&m).contains(&"bad-git"), "a head on an unborn repository");
        let m = edit(manifest(), |m| {
            m.git.unborn = true;
            m.git.head = None;
            m.git.branch = None;
        });
        assert!(m.validate(&Limits::default()).is_empty());
    }

    #[test]
    fn generations_are_a_compare_and_swap_against_the_base() {
        let m = edit(manifest(), |m| m.generation = 9);
        assert!(codes(&m).contains(&"generation"));
    }

    #[test]
    fn totals_count_unique_stored_bytes_once() {
        let m = edit(manifest(), |m| {
            m.files.push(file("copy-of-readme.md", b"# game\n"));
        });
        let readme = b"# game\n".len() as u64;
        assert_eq!(m.totals.files, 5);
        assert_eq!(m.totals.stored_bytes, m.computed_totals().stored_bytes);
        let without = edit(m.clone(), |m| m.files.retain(|f| f.path != "copy-of-readme.md"));
        assert_eq!(m.totals.stored_bytes, without.totals.stored_bytes, "an identical file adds no stored bytes");
        assert_eq!(m.totals.bytes, without.totals.bytes + readme);
    }
}
