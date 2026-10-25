//! A workspace in a directory. Paths that resolve outside it, through `..` or a symlink, are refused.
use crate::{
    error::{Result, SessionError},
    store::{Change, Entry, FileStore, INTERNAL, clean},
};
use sha2::{Digest, Sha256};
use std::{
    io,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::UNIX_EPOCH,
};

pub struct DirStore {
    root: PathBuf,
    state: PathBuf,
    counter: AtomicU64,
}

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

fn entry(name: String, meta: &std::fs::Metadata) -> Entry {
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as u64);
    Entry { name, kind: if meta.is_file() { "file" } else if meta.is_dir() { "dir" } else { "other" }, size: meta.len(), mtime }
}

impl DirStore {
    pub fn new(root: impl AsRef<Path>) -> io::Result<Self> {
        let root = std::fs::canonicalize(root)?;
        Ok(Self { state: root.join(INTERNAL).join("state"), root, counter: AtomicU64::new(0) })
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
            tokio::fs::create_dir_all(parent).await.map_err(io_error)?;
        }
        // A temporary file renamed over the target, so a reader never sees half a file.
        let temporary = self.temporary(target);
        tokio::fs::write(&temporary, data).await.map_err(io_error)?;
        if let Err(error) = tokio::fs::rename(&temporary, target).await {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(io_error(error));
        }
        Ok(())
    }
}

impl FileStore for DirStore {
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
        self.replace(&absolute, data).await
    }

    async fn mkdir(&self, path: &str) -> Result<()> {
        tokio::fs::create_dir_all(self.inside(path).await?).await.map_err(io_error)
    }

    async fn remove(&self, path: &str, recursive: bool) -> Result<()> {
        if clean(path)?.is_empty() {
            return Err(SessionError::new("outside", "The workspace itself cannot be removed."));
        }
        let absolute = self.inside(path).await?;
        let meta = tokio::fs::symlink_metadata(&absolute).await.map_err(io_error)?;
        if meta.is_dir() {
            if recursive { tokio::fs::remove_dir_all(&absolute).await } else { tokio::fs::remove_dir(&absolute).await }
        } else {
            tokio::fs::remove_file(&absolute).await
        }
        .map_err(io_error)
    }

    async fn rename(&self, from: &str, to: &str) -> Result<()> {
        let (from, to) = (self.inside(from).await?, self.inside(to).await?);
        if let Some(parent) = to.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(io_error)?;
        }
        tokio::fs::rename(from, to).await.map_err(io_error)
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
        self.replace(&self.state_file(key), data).await
    }
}
