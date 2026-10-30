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
    pub(crate) root: PathBuf,
    pub(crate) state: PathBuf,
    counter: AtomicU64,
    identity: StoreIdentity,
    buffers: tokio::sync::Mutex<Option<HashSet<PathBuf>>>,
    documents:tokio::sync::Mutex<Option<crate::document_ids::Catalog>>,
}

const MAX_RECOVERY_ENTRIES: usize = 16_384;

pub(crate) fn io_error(error: io::Error) -> SessionError {
    use io::ErrorKind::*;
    match error.kind() {
        NotFound => SessionError::new("not-found", "No such file or directory."),
        AlreadyExists | DirectoryNotEmpty => SessionError::new("exists", "The target exists or is not empty."),
        NotADirectory | IsADirectory => SessionError::new("wrong-kind", "That is not the kind of entry the operation needs."),
        PermissionDenied => SessionError::new("denied", "The session may not do that."),
        _ => SessionError::new("failed", error.to_string()),
    }
}

pub(crate) async fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    tokio::fs::File::open(path).await.map_err(io_error)?.sync_all().await.map_err(io_error)?;
    Ok(())
}

pub(crate) async fn create_directories(path: &Path) -> Result<()> {
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
        Ok(Self { state, root, identity, counter: AtomicU64::new(0), buffers: Default::default(), documents:Default::default() })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The absolute path for `path`, once the nearest existing ancestor is known to stay inside the root.
    pub(crate) async fn inside(&self, path: &str) -> Result<PathBuf> {
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

    pub(crate) async fn replace(&self, target: &Path, data: &[u8]) -> Result<()> {
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

    pub(crate) async fn bounded_read(path: &Path, limit: usize) -> Result<Vec<u8>> {
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
        catalog:&crate::document_ids::Catalog,
        paths: &[&str],
        descendants: bool,
        writing: Option<&[u8]>,
        preserving:Option<&str>,
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
            let document=bound.strip_prefix("document:");
            let bound = if let Some(id)=document {
                let record=catalog.records.get(id).filter(|record|self.state.join(&record.file)==*path).ok_or_else(crate::document_ids::invalid)?;
                let Some(bound)=&record.path else{continue};self.root.join(bound)
            } else {
                let native=if cfg!(windows){bound.replace('/',"\\")}else{bound.to_owned()};
                if Path::new(&native).is_absolute(){PathBuf::from(native)}else{self.root.join(clean(bound)?)}
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
            if preserving.is_some_and(|source|bound==self.root.join(source) || bound.starts_with(self.root.join(source))) {
                if document.is_none(){return Err(SessionError::new("recovery-binding","Reopen this recovered draft once before moving it without saving."));}
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

    async fn catalog(&self)->Result<tokio::sync::MutexGuard<'_,Option<crate::document_ids::Catalog>>> {
        let mut catalog=self.documents.lock().await;
        if catalog.is_none(){*catalog=Some(crate::document_ids::load(self).await?);}
        Ok(catalog)
    }
    async fn document_key(&self,path:&str)->Result<String>{
        let key=self.recovery_path(path).await?;
        let native=if cfg!(windows){key.replace('/',"\\")}else{key};
        let relative=Path::new(&native).strip_prefix(&self.root).map_err(|_|crate::document_ids::invalid())?;
        clean(&relative.to_string_lossy().replace('\\',"/"))
    }
    async fn target_key(&self,path:&str)->Result<String>{
        let path=clean(path)?;let (parent,name)=path.rsplit_once('/').unwrap_or(("",&path));
        let parent=self.document_key(parent).await?;Ok(if parent.is_empty(){name.into()}else{format!("{parent}/{name}")})
    }
    async fn legacy_document(&self,catalog:&crate::document_ids::Catalog,path:&str,key:&str)->Result<Option<String>>{
        let mut legacy=None;
        for candidate in [self.state_file(&format!("doc:{key}")),self.state_file(&format!("doc:{path}"))] {
            let file=candidate.file_name().unwrap().to_string_lossy().into_owned();
            if catalog.file_used(&file)||!tokio::fs::try_exists(&candidate).await.map_err(io_error)?{continue;}
            if let Some(previous)=&legacy {
                if previous!=&file {return Err(SessionError::new("recovery-conflict","Aliased recovery histories need reconciliation."));}
            } else {legacy=Some(file);}
        }
        Ok(legacy)
    }
    async fn admit_document(&self,catalog:&mut crate::document_ids::Catalog,path:&str,key:&str)->Result<String>{
        let mut next=catalog.clone();
        let id=if let Some(id)=catalog.id(key){
            if self.legacy_document(catalog,path,key).await?.is_some(){return Err(SessionError::new("recovery-conflict","Aliased recovery histories need reconciliation."));}
            id.into()
        }else{next.admit(key,self.legacy_document(catalog,path,key).await?.as_deref())?};
        next.alias(&clean(path)?,&id)?;
        if next.revision!=catalog.revision{crate::document_ids::save(self,&next).await?;*catalog=next;}Ok(id)
    }
    async fn move_bound(&self,from:&str,to:&str,preserving:bool)->Result<crate::store::DocumentMoveReceipt>{
        if clean(from)?.is_empty()||clean(to)?.is_empty(){return Err(SessionError::new("outside","The workspace itself cannot be moved or replaced."));}
        let mut catalog=self.catalog().await?;
        let source=self.document_key(from).await?;let target=self.target_key(to).await?;
        let metadata=tokio::fs::symlink_metadata(self.inside(from).await?).await.map_err(io_error)?;
        if metadata.file_type().is_symlink() && preserving {return Err(SessionError::new("unsupported","Move the source file directly when preserving its recovered draft."));}
        self.protect_buffers(catalog.as_ref().unwrap(),&[from,to],true,None,preserving.then_some(source.as_str())).await?;
        if metadata.file_type().is_symlink() && !preserving {
            let a=self.inside(from).await?;let b=self.inside(to).await?;
            if let Some(parent)=b.parent(){create_directories(parent).await?;}
            crate::document_ids::rename(&a,&b,false).await?;
            for parent in [a.parent(),b.parent()].into_iter().flatten(){sync_directory(parent).await?;}
            return Ok(crate::store::DocumentMoveReceipt{revision:catalog.as_ref().unwrap().revision,documents:Vec::new()});
        }
        let result=crate::document_ids::move_file(self,catalog.as_ref().unwrap(),&source,&target).await;
        *catalog=None;
        result
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
        let destination = crate::document_ids::legacy_target(new,&entry.file_name())?;
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
    fn document_identities(&self) -> bool { true }
    async fn document_identity(&self,path:&str)->Result<Option<String>> {let catalog=self.catalog().await?;Ok(catalog.as_ref().unwrap().id(&self.document_key(path).await?).map(str::to_owned))}
    async fn document_path(&self,id:&str)->Result<Option<String>> {let catalog=self.catalog().await?;Ok(catalog.as_ref().unwrap().path(id).map(str::to_owned))}
    async fn path_rebound(&self,path:&str)->Result<bool> {let catalog=self.catalog().await?;let catalog=catalog.as_ref().unwrap();let key=self.document_key(path).await?;Ok(catalog.rebound(&key)||catalog.rebound(&clean(path)?)||catalog.alias_changed(&clean(path)?,&key))}
    async fn matches_recovery_binding(&self,path:&str,binding:&str)->Result<bool>{
        if let Some(id)=binding.strip_prefix("document:"){return Ok(self.document_identity(path).await?.as_deref()==Some(id));}
        Ok(self.recovery_path(path).await?==binding)
    }
    async fn rename_documents(&self,from:&str,to:&str)->Result<crate::store::DocumentMoveReceipt>{self.move_bound(from,to,true).await}
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
        drop(self.catalog().await?);
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
        drop(self.catalog().await?);
        let absolute = self.inside(path).await?;
        match tokio::fs::metadata(&absolute).await {
            Ok(meta) => Ok(Some(entry(absolute.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned()), &meta))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(io_error(error)),
        }
    }

    async fn read(&self, path: &str) -> Result<Vec<u8>> {
        drop(self.catalog().await?);
        tokio::fs::read(self.inside(path).await?).await.map_err(io_error)
    }

    async fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        let catalog=self.catalog().await?;
        let absolute = self.inside(path).await?;
        self.protect_buffers(catalog.as_ref().unwrap(),&[path], false, Some(data),None).await?;
        self.replace(&absolute, data).await
    }

    async fn mkdir(&self, path: &str) -> Result<()> {
        drop(self.catalog().await?);
        create_directories(&self.inside(path).await?).await
    }

    async fn remove(&self, path: &str, recursive: bool) -> Result<()> {
        if clean(path)?.is_empty() {
            return Err(SessionError::new("outside", "The workspace itself cannot be removed."));
        }
        let mut catalog=self.catalog().await?;let key=self.document_key(path).await?;
        let absolute = self.inside(path).await?;
        let meta = tokio::fs::symlink_metadata(&absolute).await.map_err(io_error)?;
        self.protect_buffers(catalog.as_ref().unwrap(),&[path], true, None,None).await?;
        if meta.file_type().is_symlink(){
            tokio::fs::remove_file(&absolute).await.map_err(io_error)?;
            return sync_directory(absolute.parent().unwrap()).await;
        }
        let result=crate::document_ids::remove_file(self,catalog.as_ref().unwrap(),&key,recursive).await;
        *catalog=None;result
    }

    async fn rename(&self, from: &str, to: &str) -> Result<()> {
        self.move_bound(from,to,false).await.map(|_|())
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
        let catalog=self.catalog().await?;
        let file=if let Some(path)=key.strip_prefix("doc:"){
            let canonical=self.document_key(path).await?;
            match catalog.as_ref().unwrap().id(&canonical){Some(id)=>{
                if self.legacy_document(catalog.as_ref().unwrap(),path,&canonical).await?.is_some(){return Err(SessionError::new("recovery-conflict","Aliased recovery histories need reconciliation."));}
                self.state.join(&catalog.as_ref().unwrap().records[id].file)
            },None=>{
                let Some(file)=self.legacy_document(catalog.as_ref().unwrap(),path,&canonical).await? else{return Ok(None)};self.state.join(file)
            }}
        }else{self.state_file(key)};
        match tokio::fs::read(file).await {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(io_error(error)),
        }
    }

    async fn write_state(&self, key: &str, data: &[u8]) -> Result<()> {
        let mut catalog=self.catalog().await?;
        let mut buffers = self.buffers.lock().await;
        if crate::buffer_state::buffered(data) && buffers.as_ref().is_some_and(|entries|entries.len()>=MAX_RECOVERY_ENTRIES){
            let file=if let Some(path)=key.strip_prefix("doc:"){
                let canonical=self.document_key(path).await?;catalog.as_ref().unwrap().id(&canonical).map(|id|self.state.join(&catalog.as_ref().unwrap().records[id].file))
            }else{Some(self.state_file(key))};
            if file.as_ref().is_none_or(|file|!buffers.as_ref().unwrap().contains(file)){return Err(SessionError::new("busy","The session recovery inventory exceeds its limit."));}
        }
        let (path,data)=if let Some(path)=key.strip_prefix("doc:"){
            let canonical=self.document_key(path).await?;
            let id=self.admit_document(catalog.as_mut().unwrap(),path,&canonical).await?;
            let bytes=match crate::buffer_state::unpack(data){Ok(Some((header,_))) if header.path.is_some()=>{
                if header.path.as_deref().and_then(|p|p.strip_prefix("document:")).is_some_and(|old|old!=id){return Err(SessionError::new("recovery-conflict","The draft belongs to another document."));}
                crate::buffer_state::rebind(data,&id)?
            },_=>data.to_vec()};
            (self.state.join(&catalog.as_ref().unwrap().records[&id].file),bytes)
        }else{(self.state_file(key),data.to_vec())};
        if crate::buffer_state::buffered(&data) && buffers.as_ref().is_some_and(|entries|entries.len() >= MAX_RECOVERY_ENTRIES && !entries.contains(&path)) {
            return Err(SessionError::new("busy","The session recovery inventory exceeds its limit."));
        }
        private_directories(&self.state).map_err(io_error)?;
        self.replace(&path, &data).await?;
        if let Some(buffers) = buffers.as_mut() {
            if crate::buffer_state::buffered(&data) {buffers.insert(path);} else {buffers.remove(&path);}
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn legacy_buffer_adoption_preserves_its_graph_file_across_a_move() {
        let root=tempfile::tempdir().unwrap(); let state=tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("file.txt"),b"saved").unwrap();
        let store=std::sync::Arc::new(DirStore::with_state_root(root.path(),state.path()).unwrap());
        let legacy=store.state_file("doc:file.txt");
        let bytes=crate::buffer_state::pack(&[0,0],&crate::checkpoint::digest(b"saved"),None,&store.recovery_path("file.txt").await.unwrap()).unwrap();
        std::fs::write(&legacy,&bytes).unwrap();
        let hub=crate::docs::DocHub::new(store.clone(),std::sync::Arc::new(|_|{}));
        let opened=hub.attach("file.txt","a",None,std::sync::Arc::new(|_|{})).await.unwrap();
        let id=opened.document_id.unwrap(); assert!(opened.buffered && opened.dirty); assert_eq!(opened.text,"");
        hub.detach("file.txt","a"); hub.release("file.txt").await.unwrap();
        assert_eq!(crate::buffer_state::unpack(&std::fs::read(&legacy).unwrap()).unwrap().unwrap().0.path.as_deref(),Some(format!("document:{id}").as_str()));
        hub.rename_documents("file.txt","moved.txt").await.unwrap(); drop(hub); drop(store);
        let store=std::sync::Arc::new(DirStore::with_state_root(root.path(),state.path()).unwrap());
        let hub=crate::docs::DocHub::new(store.clone(),std::sync::Arc::new(|_|{}));
        let opened=hub.attach_identified("moved.txt","a",None,Some(&id),std::sync::Arc::new(|_|{})).await.unwrap();
        assert!(opened.dirty); assert_eq!(opened.text,"");
        assert!(legacy.exists()); assert_eq!(std::fs::read(root.path().join("moved.txt")).unwrap(),b"saved");
        hub.close().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn duplicate_legacy_alias_graphs_are_preserved_for_reconciliation() {
        let root=tempfile::tempdir().unwrap(); let state=tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("file.txt"),b"saved").unwrap();
        std::os::unix::fs::symlink("file.txt",root.path().join("alias.txt")).unwrap();
        let store=std::sync::Arc::new(DirStore::with_state_root(root.path(),state.path()).unwrap());
        let bytes=crate::buffer_state::pack(&[0,0],&crate::checkpoint::digest(b"saved"),None,&store.recovery_path("file.txt").await.unwrap()).unwrap();
        for path in ["file.txt","alias.txt"] {std::fs::write(store.state_file(&format!("doc:{path}")),&bytes).unwrap();}
        let hub=crate::docs::DocHub::new(store.clone(),std::sync::Arc::new(|_|{}));
        assert_eq!(hub.attach("alias.txt","a",None,std::sync::Arc::new(|_|{})).await.err().unwrap().code,"recovery-conflict");
        for path in ["file.txt","alias.txt"] {assert_eq!(std::fs::read(store.state_file(&format!("doc:{path}"))).unwrap(),bytes);}
        assert!(store.document_identity("file.txt").await.unwrap().is_none());
        assert!(!store.state.join("documents.json").exists());
        std::fs::remove_file(store.state_file("doc:alias.txt")).unwrap();
        hub.attach("file.txt","a",None,std::sync::Arc::new(|_|{})).await.unwrap();
        hub.detach("file.txt","a");hub.release("file.txt").await.unwrap();
        let adopted=std::fs::read(store.state_file("doc:file.txt")).unwrap();
        std::fs::write(store.state_file("doc:alias.txt"),&bytes).unwrap();
        assert_eq!(hub.attach("alias.txt","a",None,std::sync::Arc::new(|_|{})).await.err().unwrap().code,"recovery-conflict");
        assert_eq!(std::fs::read(store.state_file("doc:file.txt")).unwrap(),adopted);
        assert_eq!(std::fs::read(store.state_file("doc:alias.txt")).unwrap(),bytes);
        hub.close().await;
    }

    #[tokio::test]
    async fn buffer_index_admission_allows_existing_records_and_releases_capacity() {
        let workspace = tempfile::tempdir().unwrap(); let private = tempfile::tempdir().unwrap();
        let store = DirStore::with_state_root(workspace.path(), private.path()).unwrap();
        store.write_state("doc:existing.txt",&[0,0]).await.unwrap();
        let catalog=store.catalog().await.unwrap();let id=catalog.as_ref().unwrap().id("existing.txt").unwrap().to_owned();
        let existing=store.state.join(&catalog.as_ref().unwrap().records[&id].file);drop(catalog);
        let mut entries:HashSet<_>=(0..MAX_RECOVERY_ENTRIES-1).map(|id|store.state_file(&format!("doc:{id}"))).collect();
        entries.insert(existing.clone()); *store.buffers.lock().await=Some(entries);
        let state = crate::buffer_state::pack(&[0,0],&crate::checkpoint::digest(b""),None,&store.recovery_path("existing.txt").await.unwrap()).unwrap();
        assert_eq!(store.write_state("doc:new.txt",&state).await.unwrap_err().code,"busy");
        assert!(store.read_state("doc:new.txt").await.unwrap().is_none());
        store.write_state("doc:existing.txt",&state).await.unwrap();
        assert_eq!(crate::buffer_state::unpack(&store.read_state("doc:existing.txt").await.unwrap().unwrap()).unwrap().unwrap().1,&[0,0]);
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
