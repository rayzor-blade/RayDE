//! A workspace in a directory. Paths that resolve outside it, through `..` or a symlink, are refused.
use crate::{
    error::{Result, SessionError},
    store::{Change, Entry, FileStore, StoreIdentity, INTERNAL, clean},
};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    io,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::UNIX_EPOCH,
};

pub struct DirStore {
    root: PathBuf,
    state: PathBuf,
    counter: AtomicU64,
    identity: StoreIdentity,
    buffers: tokio::sync::Mutex<Option<HashSet<PathBuf>>>,
}

const MAX_RECOVERY_ENTRIES: usize = 16_384;

fn io_error(error: io::Error) -> SessionError {
    use io::ErrorKind::*;
    match error.kind() {
        NotFound => SessionError::new("not-found", "No such file or directory."),
        AlreadyExists | DirectoryNotEmpty => SessionError::new("exists", "The target exists or is not empty."),
        NotADirectory | IsADirectory => SessionError::new("wrong-kind", "That is not the kind of entry the operation needs."),
        PermissionDenied => SessionError::new("denied", "The session may not do that."),
        _ => SessionError::new("failed", error.to_string()),
    }
}

async fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    tokio::fs::File::open(path).await.map_err(io_error)?.sync_all().await.map_err(io_error)?;
    Ok(())
}

async fn create_directories(path: &Path) -> Result<()> {
    let mut missing = Vec::new();
    let mut probe = path;
    while !tokio::fs::try_exists(probe).await.map_err(io_error)? {
        missing.push(probe.to_path_buf());
        probe = probe.parent().ok_or_else(||SessionError::new("failed","The directory has no parent."))?;
    }
    tokio::fs::create_dir_all(path).await.map_err(io_error)?;
    for directory in missing {
        sync_directory(&directory).await?;
        if let Some(parent) = directory.parent() {sync_directory(parent).await?;}
    }
    Ok(())
}

fn entry(name: String, meta: &std::fs::Metadata) -> Entry {
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as u64);
    Entry { name, kind: if meta.is_file() { "file" } else if meta.is_dir() { "dir" } else { "other" }, size: meta.len(), mtime }
}

impl DirStore {
    pub fn new(root: impl AsRef<Path>) -> io::Result<Self> {
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .filter(|path| !path.is_empty()).ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Set --state-root when the user's home directory is unavailable."))?;
        Self::with_state_root(root, PathBuf::from(home).join(INTERNAL))
    }

    /// Each canonical workspace has its own state namespace under the user's private session directory.
    pub fn with_state_root(root: impl AsRef<Path>, state_root: impl AsRef<Path>) -> io::Result<Self> {
        let root = std::fs::canonicalize(root)?;
        let digest = Sha256::digest(root.as_os_str().as_encoded_bytes());
        let key = digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let namespace = state_root.as_ref().join(key);
        let state = namespace.join("state");
        migrate_state(&root.join(INTERNAL).join("state"), &state)?;
        let identity = StoreIdentity {
            authority: crate::cache_identity::persistent_id(&state_root.as_ref().join("authority.id"))?,
            workspace: crate::cache_identity::persistent_id(&state.join("workspace.id"))?,
        };
        Ok(Self { state, root, identity, counter: AtomicU64::new(0), buffers: Default::default() })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The absolute path for `path`, once the nearest existing ancestor is known to stay inside the root.
    async fn inside(&self, path: &str) -> Result<PathBuf> {
        let absolute = self.root.join(clean(path)?);
        let mut probe = absolute.as_path();
        loop {
            match tokio::fs::canonicalize(probe).await {
                Ok(real) => {
                    return if real.starts_with(&self.root) { Ok(absolute) } else { Err(SessionError::new("outside", "The path leaves the workspace.")) };
                }
                Err(_) => match probe.parent() {
                    Some(parent) => probe = parent,
                    None => return Err(SessionError::new("outside", "The path leaves the workspace.")),
                },
            }
        }
    }

    fn state_file(&self, key: &str) -> PathBuf {
        let digest = Sha256::digest(key.as_bytes());
        self.state.join(digest.iter().map(|b| format!("{b:02x}")).collect::<String>() + ".ydoc")
    }

    fn temporary(&self, target: &Path) -> PathBuf {
        let mut name = target.file_name().map(|n| n.to_os_string()).unwrap_or_default();
        name.push(format!(".{}.{}.tmp", std::process::id(), self.counter.fetch_add(1, Ordering::Relaxed)));
        target.with_file_name(name)
    }

    async fn replace(&self, target: &Path, data: &[u8]) -> Result<()> {
        if let Some(parent) = target.parent() {
            create_directories(parent).await?;
        }
        // A temporary file renamed over the target, so a reader never sees half a file.
        let temporary = self.temporary(target);
        let written = async {
            use tokio::io::AsyncWriteExt;
            let mut file = tokio::fs::File::create(&temporary).await?;
            file.write_all(data).await?;
            file.sync_all().await
        }.await;
        if let Err(error) = written {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(io_error(error));
        }
        if let Err(error) = tokio::fs::rename(&temporary, target).await {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(io_error(error));
        }
        sync_directory(target.parent().ok_or_else(|| SessionError::new("failed", "The file has no parent."))?).await?;
        Ok(())
    }

    async fn buffer_header(path: &Path) -> Result<Option<crate::buffer_state::Baseline>> {
        use tokio::io::AsyncReadExt;
        let mut file = tokio::fs::File::open(path).await.map_err(io_error)?;
        let mut bytes = Vec::new();
        (&mut file)
            .take(crate::buffer_state::PREFIX as u64)
            .read_to_end(&mut bytes)
            .await
            .map_err(io_error)?;
        if !crate::buffer_state::buffered(&bytes) {
            return Ok(None);
        }
        file.take(crate::buffer_state::MAX_HEADER as u64)
            .read_to_end(&mut bytes)
            .await
            .map_err(io_error)?;
        Ok(crate::buffer_state::header(&bytes)?.map(|(header, _)| header))
    }

    async fn bounded_read(path: &Path, limit: usize) -> Result<Vec<u8>> {
        use tokio::io::AsyncReadExt;
        let mut bytes = Vec::new();
        tokio::fs::File::open(path)
            .await
            .map_err(io_error)?
            .take(limit as u64 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(io_error)?;
        if bytes.len() > limit {
            return Err(SessionError::new(
                "too-large",
                "The recovery file exceeds its size limit.",
            ));
        }
        Ok(bytes)
    }

    /// Released buffers remain protected; clean graphs can return to ordinary file-backed recovery.
    async fn protect_buffers(
        &self,
        paths: &[&str],
        descendants: bool,
        writing: Option<&[u8]>,
    ) -> Result<()> {
        let mut roots = Vec::new();
        for path in paths {
            roots.push(PathBuf::from(self.recovery_path(path).await?));
        }
        let mut buffers = self.buffers.lock().await;
        // Private writes maintain this index; inactive graphs need no polling or retained payloads.
        if buffers.is_none() {
            let mut found = HashSet::new();
            match tokio::fs::read_dir(&self.state).await {
                Ok(mut reader) => {
                    let mut count = 0;
                    while let Some(entry) = reader.next_entry().await.map_err(io_error)? {
                        count += 1;
                        if count > MAX_RECOVERY_ENTRIES {
                            return Err(SessionError::new(
                                "busy",
                                "The session recovery inventory exceeds its limit.",
                            ));
                        }
                        if entry
                            .path()
                            .extension()
                            .is_none_or(|extension| extension != "ydoc")
                        {
                            continue;
                        }
                        if !entry.file_type().await.map_err(io_error)?.is_file() {
                            return Err(SessionError::new(
                                "bad-buffer-state",
                                "The session recovery entry is not a regular file.",
                            ));
                        }
                        if Self::buffer_header(&entry.path()).await?.is_some() {
                            found.insert(entry.path());
                        }
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(error) => return Err(io_error(error)),
            }
            *buffers = Some(found);
        }
        let writing = writing.map(crate::checkpoint::digest);
        // Validate every affected record before changing any clean sibling's storage format.
        let mut normalizing = Vec::new();
        for path in buffers.as_ref().unwrap() {
            let Some(header) = Self::buffer_header(path).await? else {
                continue;
            };
            let bound = header.path.as_deref().ok_or_else(|| {
                SessionError::new(
                    "recovery-binding",
                    "Reopen recovered drafts before moving, deleting or replacing files.",
                )
            })?;
            let native = if cfg!(windows) { bound.replace('/', "\\") } else { bound.to_owned() };
            let bound = if Path::new(&native).is_absolute() {
                PathBuf::from(native)
            } else {
                self.root.join(clean(bound)?)
            };
            if !bound.starts_with(&self.root) {
                return Err(SessionError::new(
                    "recovery-binding",
                    "The recovered draft belongs to a different workspace path. Reopen it before changing files.",
                ));
            }
            if !roots
                .iter()
                .any(|root| bound == *root || descendants && bound.starts_with(root))
            {
                continue;
            }
            let bytes = Self::bounded_read(
                path,
                crate::checkpoint::MAX_BYTES
                    + crate::buffer_state::MAX_HEADER
                    + crate::buffer_state::PREFIX,
            )
            .await?;
            let (header, graph) = crate::buffer_state::unpack(&bytes)?.ok_or_else(|| {
                SessionError::new("bad-buffer-state", "The recovered draft is invalid.")
            })?;
            let disk = Self::bounded_read(&bound, crate::session::MAX_READ as usize).await?;
            if !header.accepts(&crate::checkpoint::digest(&disk)) {
                return Err(SessionError::new(
                    "recovery-conflict",
                    "The saved file changed. Reconcile its recovered draft before changing the file.",
                ));
            }
            if writing.as_deref().is_some_and(|hash| header.saving(hash)) {
                continue;
            }
            if crate::checkpoint::text(graph)?.as_bytes() != disk {
                return Err(SessionError::new(
                    "buffer-dirty",
                    "Save or reconcile the recovered draft before moving, deleting or replacing its file.",
                ));
            }
            normalizing.push(path.clone());
        }
        for path in normalizing {
            let bytes = Self::bounded_read(
                &path,
                crate::checkpoint::MAX_BYTES
                    + crate::buffer_state::MAX_HEADER
                    + crate::buffer_state::PREFIX,
            )
            .await?;
            let (_, graph) = crate::buffer_state::unpack(&bytes)?.ok_or_else(|| {
                SessionError::new("bad-buffer-state", "The recovered draft is invalid.")
            })?;
            self.replace(&path, graph).await?;
            buffers.as_mut().unwrap().remove(&path);
        }
        Ok(())
    }
}

/// Copy before removing the old file; interrupted moves can be resumed without overwriting newer state.
fn migrate_state(old: &Path, new: &Path) -> io::Result<()> {
    use std::io::Write;
    if old == new || !old.try_exists()? { return Ok(()); }
    for directory in [old.parent().unwrap(), old] {
        if std::fs::symlink_metadata(directory)?.file_type().is_symlink() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "The legacy session directory must not be a symlink."));
        }
    }
    for entry in std::fs::read_dir(old)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() || entry.path().extension().is_none_or(|extension| extension != "ydoc") { continue; }
        let data = std::fs::read(entry.path())?;
        private_directories(new)?;
        let destination = new.join(entry.file_name());
        let mut options = std::fs::OpenOptions::new(); options.write(true).create_new(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
        match options.open(&destination) {
            Ok(mut file) => {
                if let Err(error) = file.write_all(&data).and_then(|_| file.sync_all()) { let _ = std::fs::remove_file(&destination); return Err(error); }
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                if std::fs::read(&destination)? != data { return Err(io::Error::new(io::ErrorKind::AlreadyExists, "Session state differs in the home and workspace directories; both copies have been preserved.")); }
            }
            Err(error) => return Err(error),
        }
        std::fs::remove_file(entry.path())?;
    }
    for directory in [old, old.parent().unwrap()] {
        match std::fs::remove_dir(directory) {
            Ok(()) => {}
            Err(error) if matches!(error.kind(), io::ErrorKind::DirectoryNotEmpty | io::ErrorKind::NotFound) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn private_directories(path: &Path) -> io::Result<()> {
    let mut builder = std::fs::DirBuilder::new(); builder.recursive(true);
    #[cfg(unix)] { use std::os::unix::fs::DirBuilderExt; builder.mode(0o700); }
    builder.create(path)
}

impl FileStore for DirStore {
    fn cache_identity(&self) -> Option<StoreIdentity> { Some(self.identity.clone()) }
    async fn recovery_path(&self, path: &str) -> Result<String> {
        let mut probe=self.inside(path).await?;
        let mut suffix=Vec::new();
        loop {
            match tokio::fs::canonicalize(&probe).await {
                Ok(mut key)=>{
                    for part in suffix.into_iter().rev() {key.push(part);}
                    return Ok(key.to_string_lossy().replace('\\',"/"));
                }
                Err(_)=>{
                    let name=probe.file_name().ok_or_else(||SessionError::new("outside","The path leaves the workspace."))?.to_os_string();
                    suffix.push(name);
                    if !probe.pop() {return Err(SessionError::new("outside","The path leaves the workspace."));}
                }
            }
        }
    }
    fn name(&self) -> String {
        self.root.file_name().map_or_else(|| "workspace".into(), |n| n.to_string_lossy().into_owned())
    }

    fn root(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }

    async fn list(&self, path: &str) -> Result<Vec<Entry>> {
        let at_root = clean(path)?.is_empty();
        let mut reader = tokio::fs::read_dir(self.inside(path).await?).await.map_err(io_error)?;
        let mut out = Vec::new();
        while let Some(item) = reader.next_entry().await.map_err(io_error)? {
            let name = item.file_name().to_string_lossy().into_owned();
            if at_root && name == INTERNAL {
                continue;
            }
            out.push(match tokio::fs::metadata(item.path()).await {
                Ok(meta) => entry(name, &meta),
                Err(_) => Entry { name, kind: "other", size: 0, mtime: 0 },
            });
        }
        out.sort_by(|a, b| (a.kind != "dir", a.name.to_lowercase()).cmp(&(b.kind != "dir", b.name.to_lowercase())));
        Ok(out)
    }

    async fn stat(&self, path: &str) -> Result<Option<Entry>> {
        let absolute = self.inside(path).await?;
        match tokio::fs::metadata(&absolute).await {
            Ok(meta) => Ok(Some(entry(absolute.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned()), &meta))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(io_error(error)),
        }
    }

    async fn read(&self, path: &str) -> Result<Vec<u8>> {
        tokio::fs::read(self.inside(path).await?).await.map_err(io_error)
    }

    async fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        let absolute = self.inside(path).await?;
        self.protect_buffers(&[path], false, Some(data)).await?;
        self.replace(&absolute, data).await
    }

    async fn mkdir(&self, path: &str) -> Result<()> {
        create_directories(&self.inside(path).await?).await
    }

    async fn remove(&self, path: &str, recursive: bool) -> Result<()> {
        if clean(path)?.is_empty() {
            return Err(SessionError::new("outside", "The workspace itself cannot be removed."));
        }
        let absolute = self.inside(path).await?;
        let meta = tokio::fs::symlink_metadata(&absolute).await.map_err(io_error)?;
        self.protect_buffers(&[path], true, None).await?;
        if meta.is_dir() {
            if recursive { tokio::fs::remove_dir_all(&absolute).await } else { tokio::fs::remove_dir(&absolute).await }
        } else {
            tokio::fs::remove_file(&absolute).await
        }
        .map_err(io_error)?;
        sync_directory(absolute.parent().ok_or_else(||SessionError::new("outside","The workspace itself cannot be removed."))?).await
    }

    async fn rename(&self, from: &str, to: &str) -> Result<()> {
        if clean(from)?.is_empty() || clean(to)?.is_empty() {return Err(SessionError::new("outside","The workspace itself cannot be moved or replaced."));}
        self.protect_buffers(&[from, to], true, None).await?;
        let (from, to) = (self.inside(from).await?, self.inside(to).await?);
        if let Some(parent) = to.parent() {
            create_directories(parent).await?;
        }
        tokio::fs::rename(&from, &to).await.map_err(io_error)?;
        for parent in [from.parent(),to.parent()].into_iter().flatten() {sync_directory(parent).await?;}
        Ok(())
    }

    fn watch(&self, change: Change) -> Box<dyn FnOnce() + Send> {
        use notify::{EventKind, RecursiveMode, Watcher};
        let root = self.root.clone();
        let base = root.clone();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            let kind = match event.kind {
                EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(notify::event::ModifyKind::Name(_)) => "rename",
                EventKind::Modify(_) => "change",
                _ => return,
            };
            for path in event.paths {
                let Ok(relative) = path.strip_prefix(&base) else { continue };
                let virtual_path = relative.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/");
                if virtual_path == INTERNAL || virtual_path.starts_with(&format!("{INTERNAL}/")) || virtual_path.ends_with(".tmp") {
                    continue;
                }
                change(virtual_path, kind);
            }
        });
        match watcher {
            Ok(mut watcher) => {
                let _ = watcher.watch(&root, RecursiveMode::Recursive);
                Box::new(move || drop(watcher))
            }
            Err(_) => Box::new(|| {}),
        }
    }

    async fn read_state(&self, key: &str) -> Result<Option<Vec<u8>>> {
        match tokio::fs::read(self.state_file(key)).await {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(io_error(error)),
        }
    }

    async fn write_state(&self, key: &str, data: &[u8]) -> Result<()> {
        let mut buffers = self.buffers.lock().await;
        let path = self.state_file(key);
        if crate::buffer_state::buffered(data) && buffers.as_ref().is_some_and(|entries|entries.len() >= MAX_RECOVERY_ENTRIES && !entries.contains(&path)) {
            return Err(SessionError::new("busy","The session recovery inventory exceeds its limit."));
        }
        private_directories(&self.state).map_err(io_error)?;
        self.replace(&path, data).await?;
        if let Some(buffers) = buffers.as_mut() {
            if crate::buffer_state::buffered(data) {buffers.insert(path);} else {buffers.remove(&path);}
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn buffer_index_admission_allows_existing_records_and_releases_capacity() {
        let workspace = tempfile::tempdir().unwrap(); let private = tempfile::tempdir().unwrap();
        let store = DirStore::with_state_root(workspace.path(), private.path()).unwrap();
        let existing = store.state_file("doc:existing.txt");
        let mut entries:HashSet<_>=(0..MAX_RECOVERY_ENTRIES-1).map(|id|store.state_file(&format!("doc:{id}"))).collect();
        entries.insert(existing.clone()); *store.buffers.lock().await=Some(entries);
        let state = crate::buffer_state::pack(&[0,0],&crate::checkpoint::digest(b""),None,&store.recovery_path("existing.txt").await.unwrap()).unwrap();
        assert_eq!(store.write_state("doc:new.txt",&state).await.unwrap_err().code,"busy");
        assert!(store.read_state("doc:new.txt").await.unwrap().is_none());
        store.write_state("doc:existing.txt",&state).await.unwrap();
        assert_eq!(store.read_state("doc:existing.txt").await.unwrap().unwrap(),state);
        store.write_state("doc:existing.txt",&[0,0]).await.unwrap();
        store.write_state("doc:new.txt",&state).await.unwrap();
        assert_eq!(store.buffers.lock().await.as_ref().unwrap().len(),MAX_RECOVERY_ENTRIES);
    }

    #[tokio::test]
    async fn state_is_private_namespaced_and_survives_reopening() {
        let workspace = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let state = home.path().join(INTERNAL);
        let first = DirStore::with_state_root(workspace.path(), &state).unwrap();
        first.write_state("doc:main.hx", b"kept").await.unwrap();
        let again = DirStore::with_state_root(workspace.path().join("."), &state).unwrap();
        assert_eq!(again.read_state("doc:main.hx").await.unwrap(), Some(b"kept".to_vec()));
        let second = DirStore::with_state_root(other.path(), &state).unwrap();
        assert!(second.read_state("doc:main.hx").await.unwrap().is_none());
        assert!(!workspace.path().join(INTERNAL).exists());
        assert!(!other.path().join(INTERNAL).exists());
        #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; assert_eq!(std::fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o700); }
        assert!(DirStore::new(workspace.path()).unwrap().state.starts_with(PathBuf::from(std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap()).join(INTERNAL)));
    }

    #[tokio::test]
    async fn legacy_state_moves_without_losing_document_identity() {
        let workspace = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let old = workspace.path().join(INTERNAL).join("state");
        std::fs::create_dir_all(&old).unwrap();
        let digest = Sha256::digest(b"doc:main.hx");
        let file = digest.iter().map(|b| format!("{b:02x}")).collect::<String>() + ".ydoc";
        std::fs::write(old.join(file), b"history").unwrap();
        let store = DirStore::with_state_root(workspace.path(), home.path()).unwrap();
        assert_eq!(store.read_state("doc:main.hx").await.unwrap(), Some(b"history".to_vec()));
        assert!(!workspace.path().join(INTERNAL).exists());
    }

    #[tokio::test]
    async fn migration_preserves_both_copies_on_conflict() {
        let workspace = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let store = DirStore::with_state_root(workspace.path(), home.path()).unwrap();
        store.write_state("doc:main.hx", b"new").await.unwrap();
        let old = workspace.path().join(INTERNAL).join("state");
        std::fs::create_dir_all(&old).unwrap();
        let original = old.join(store.state_file("doc:main.hx").file_name().unwrap());
        std::fs::write(&original, b"old").unwrap();
        assert!(DirStore::with_state_root(workspace.path(), home.path()).is_err());
        assert_eq!(std::fs::read(original).unwrap(), b"old");
        assert_eq!(store.read_state("doc:main.hx").await.unwrap(), Some(b"new".to_vec()));
    }
}
