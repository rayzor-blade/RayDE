//! Private document bindings and recoverable filesystem transitions.
use crate::{
    dir_store::DirStore,
    error::{Result, SessionError},
    store::clean,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

const MAX_ENTRIES: usize = 16_384;
const MAX_BYTES: usize = 8 * 1024 * 1024;
const CATALOG: &str = "documents.json";
const INTENT: &str = "document-mutation.json";

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Record {
    pub path: Option<String>,
    pub file: String,
}

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Catalog {
    version: u32,
    pub revision: u64,
    pub records: BTreeMap<String, Record>,
    retired: BTreeSet<String>,
    #[serde(default)]
    aliases: BTreeMap<String, String>,
    #[serde(skip)]
    paths: BTreeMap<String, String>,
}
impl Default for Catalog {
    fn default() -> Self {
        Self {
            version: 1,
            revision: 0,
            records: BTreeMap::new(),
            retired: BTreeSet::new(),
            aliases: BTreeMap::new(),
            paths: BTreeMap::new(),
        }
    }
}
#[derive(Serialize, Deserialize)]
struct Envelope<T> {
    value: T,
    sha256: String,
}

pub(crate) fn invalid() -> SessionError {
    SessionError::new(
        "recovery-required",
        "The document bindings need recovery. Existing files and recovery state have been preserved.",
    )
}
fn encoded<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    serde_json::to_vec(value).map_err(|_| invalid())
}
fn hash<T: Serialize>(value: &T) -> Result<String> {
    Ok(crate::checkpoint::digest(&encoded(value)?))
}
fn sealed<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let bytes = encoded(&Envelope {
        value,
        sha256: hash(value)?,
    })?;
    if bytes.len() > MAX_BYTES {
        return Err(invalid());
    }
    Ok(bytes)
}
fn unseal<T: serde::de::DeserializeOwned + Serialize>(bytes: &[u8]) -> Result<T> {
    let envelope: Envelope<T> = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    if hash(&envelope.value)? != envelope.sha256 {
        return Err(invalid());
    }
    Ok(envelope.value)
}
fn id_valid(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn path_valid(path: &str) -> bool {
    !path.is_empty() && path.len() <= 4096 && clean(path).ok().as_deref() == Some(path)
}

impl Catalog {
    fn validate(&mut self) -> Result<()> {
        if self.version != 1
            || self.records.len() > MAX_ENTRIES
            || self.retired.len() > MAX_ENTRIES
            || self.aliases.len() > MAX_ENTRIES
            || self.revision > 9_007_199_254_740_991
        {
            return Err(invalid());
        }
        self.paths.clear();
        let mut files = BTreeSet::new();
        for (id, record) in &self.records {
            if !id_valid(id) || !file_valid(&record.file) || !files.insert(&record.file) {
                return Err(invalid());
            }
            if let Some(path) = &record.path {
                if !path_valid(path) || self.paths.insert(path.clone(), id.clone()).is_some() {
                    return Err(invalid());
                }
            }
        }
        if self.retired.iter().any(|path| !path_valid(path)) {
            return Err(invalid());
        }
        if self
            .aliases
            .iter()
            .any(|(path, id)| !path_valid(path) || !self.records.contains_key(id))
        {
            return Err(invalid());
        }
        Ok(())
    }
    fn changed(&mut self) -> Result<()> {
        if self.records.len() > MAX_ENTRIES
            || self.aliases.len() > MAX_ENTRIES
            || self.retired.len() > MAX_ENTRIES
        {
            return Err(SessionError::new(
                "busy",
                "The document binding limit has been reached.",
            ));
        }
        self.revision = self
            .revision
            .checked_add(1)
            .filter(|n| *n <= 9_007_199_254_740_991)
            .ok_or_else(invalid)?;
        self.validate()
    }
    pub fn id(&self, path: &str) -> Option<&str> {
        self.paths.get(path).map(String::as_str)
    }
    pub fn path(&self, id: &str) -> Option<&str> {
        self.records.get(id)?.path.as_deref()
    }
    pub fn rebound(&self, path: &str) -> bool {
        self.retired.contains(path)
    }
    pub fn alias_changed(&self, path: &str, key: &str) -> bool {
        self.aliases
            .get(path)
            .is_some_and(|id| self.id(key) != Some(id))
    }
    pub fn alias(&mut self, path: &str, id: &str) -> Result<()> {
        if self.aliases.get(path).map(String::as_str) == Some(id) {
            return Ok(());
        }
        if self.aliases.insert(path.into(), id.into()).is_some() {
            self.retired.insert(path.into());
        }
        self.changed()
    }
    pub fn file_used(&self, file: &str) -> bool {
        self.records.values().any(|record| record.file == file)
    }
    pub fn admit(&mut self, path: &str, file: Option<&str>) -> Result<String> {
        if let Some(id) = self.id(path) {
            return Ok(id.into());
        }
        if !path_valid(path) || self.records.len() >= MAX_ENTRIES {
            return Err(SessionError::new(
                "busy",
                "The document binding limit has been reached.",
            ));
        }
        let id = loop {
            let mut bytes = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            let id = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
            if !self.records.contains_key(&id) {
                break id;
            }
        };
        let file = file
            .filter(|file| !self.file_used(file))
            .map(str::to_owned)
            .unwrap_or_else(|| format!("document-{id}.ydoc"));
        self.records.insert(
            id.clone(),
            Record {
                path: Some(path.into()),
                file,
            },
        );
        self.changed()?;
        Ok(id)
    }
    fn moved(&self, from: &str, to: &str) -> Result<(Self, Vec<crate::store::DocumentMove>)> {
        let mut next = self.clone();
        let mut moves = Vec::new();
        for (id, record) in &self.records {
            let Some(path) = &record.path else { continue };
            if path != from && !path.starts_with(&format!("{from}/")) {
                continue;
            }
            let target = format!("{to}{}", &path[from.len()..]);
            if self.id(&target).is_some_and(|other| other != id) {
                return Err(SessionError::new(
                    "exists",
                    "The destination already owns another document.",
                ));
            }
            next.records.get_mut(id).unwrap().path = Some(target.clone());
            next.retired.insert(path.clone());
            moves.push(crate::store::DocumentMove {
                id: id.clone(),
                from: path.clone(),
                to: target,
            });
        }
        next.changed()?;
        Ok((next, moves))
    }
    fn removed(&self, path: &str) -> Result<Self> {
        let mut next = self.clone();
        for record in next.records.values_mut() {
            if record
                .path
                .as_deref()
                .is_some_and(|p| p == path || p.starts_with(&format!("{path}/")))
            {
                next.retired.insert(record.path.take().unwrap());
            }
        }
        next.changed()?;
        Ok(next)
    }
}
fn file_valid(file: &str) -> bool {
    let name = file.strip_suffix(".ydoc").unwrap_or("");
    id_valid(name) || name.strip_prefix("document-").is_some_and(id_valid)
}

pub(crate) async fn save(store: &DirStore, catalog: &Catalog) -> Result<()> {
    store
        .replace(&store.state.join(CATALOG), &sealed(catalog)?)
        .await
}
pub(crate) fn legacy_target(
    state: &Path,
    name: &std::ffi::OsStr,
) -> std::io::Result<std::path::PathBuf> {
    use std::io::Read;
    let file = match std::fs::File::open(state.join(CATALOG)) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(state.join(name)),
        Err(error) => return Err(error),
    };
    if state.join(INTENT).exists() {
        return Err(std::io::Error::other(
            "Recover the pending document move before importing legacy state.",
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    let fail =
        |error: SessionError| std::io::Error::new(std::io::ErrorKind::InvalidData, error.message);
    if bytes.len() > MAX_BYTES {
        return Err(fail(invalid()));
    }
    let mut catalog: Catalog = unseal(&bytes).map_err(fail)?;
    catalog.validate().map_err(fail)?;
    use sha2::{Digest, Sha256};
    for (path, id) in catalog.aliases.iter().chain(catalog.paths.iter()) {
        let key = Sha256::digest(format!("doc:{path}").as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
            + ".ydoc";
        if std::ffi::OsStr::new(&key) == name {
            return Ok(state.join(&catalog.records[id].file));
        }
    }
    Ok(state.join(name))
}
pub(crate) async fn load(store: &DirStore) -> Result<Catalog> {
    let mut catalog = match read_optional(&store.state.join(CATALOG)).await? {
        Some(bytes) => unseal::<Catalog>(&bytes)?,
        None => Catalog::default(),
    };
    catalog.validate()?;
    if let Some(bytes) = read_optional(&store.state.join(INTENT)).await? {
        let mut transaction: Transaction = unseal(&bytes)?;
        transaction.after.validate()?;
        let current = hash(&catalog)?;
        if transaction.version != 1
            || current != transaction.before && current != hash(&transaction.after)?
        {
            return Err(invalid());
        }
        let applied = transaction.action.applied(store).await?;
        if applied {
            save(store, &transaction.after).await?;
            catalog = transaction.after;
        } else if current != transaction.before {
            return Err(invalid());
        }
        clear(store).await?;
    }
    Ok(catalog)
}
async fn read_optional(path: &Path) -> Result<Option<Vec<u8>>> {
    match DirStore::bounded_read(path, MAX_BYTES).await {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.code == "not-found" => Ok(None),
        Err(error) => Err(error),
    }
}
async fn clear(store: &DirStore) -> Result<()> {
    tokio::fs::remove_file(store.state.join(INTENT))
        .await
        .map_err(super::dir_store::io_error)?;
    super::dir_store::sync_directory(&store.state).await
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct Marker {
    volume: u64,
    file: u128,
    kind: u8,
}
impl Marker {
    async fn at(path: &Path) -> Result<Option<Self>> {
        let path = path.to_path_buf();
        tokio::task::spawn_blocking(move || Self::read(&path))
            .await
            .map_err(|_| invalid())?
    }
    fn read(path: &Path) -> Result<Option<Self>> {
        let metadata = match std::fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(super::dir_store::io_error(error)),
        };
        let kind = if metadata.is_file() {
            1
        } else if metadata.is_dir() {
            2
        } else {
            return Err(SessionError::new(
                "unsupported",
                "Document-preserving moves require a regular file or folder.",
            ));
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            Ok(Some(Self {
                volume: metadata.dev(),
                file: metadata.ino() as u128,
                kind,
            }))
        }
        #[cfg(windows)]
        {
            use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
            use windows_sys::Win32::Storage::FileSystem::*;
            let file = std::fs::OpenOptions::new()
                .access_mode(FILE_READ_ATTRIBUTES)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                .open(path)
                .map_err(super::dir_store::io_error)?;
            let mut info: FILE_ID_INFO = unsafe { std::mem::zeroed() };
            if unsafe {
                GetFileInformationByHandleEx(
                    file.as_raw_handle(),
                    FileIdInfo,
                    (&mut info as *mut FILE_ID_INFO).cast(),
                    std::mem::size_of::<FILE_ID_INFO>() as u32,
                )
            } == 0
            {
                return Err(super::dir_store::io_error(std::io::Error::last_os_error()));
            }
            Ok(Some(Self {
                volume: info.VolumeSerialNumber,
                file: u128::from_le_bytes(info.FileId.Identifier),
                kind,
            }))
        }
        #[cfg(not(any(unix, windows)))]
        {
            Err(SessionError::new(
                "unsupported",
                "This platform does not provide verified filesystem moves.",
            ))
        }
    }
}

#[derive(Serialize, Deserialize)]
struct Transaction {
    version: u32,
    before: String,
    after: Catalog,
    action: Action,
}
#[derive(Serialize, Deserialize)]
enum Action {
    Move {
        from: String,
        to: String,
        marker: Marker,
        case_only: bool,
    },
    Remove {
        path: String,
        marker: Marker,
        recursive: bool,
    },
}
impl Action {
    async fn applied(&self, store: &DirStore) -> Result<bool> {
        match self {
            Self::Move {
                from,
                to,
                marker,
                case_only,
            } => {
                if !path_valid(from) || !path_valid(to) {
                    return Err(invalid());
                }
                let a = store.inside(from).await?;
                let b = store.inside(to).await?;
                if *case_only {
                    let parent = b.parent().ok_or_else(invalid)?;
                    let old = a.file_name().ok_or_else(invalid)?;
                    let new = b.file_name().ok_or_else(invalid)?;
                    let mut reader = tokio::fs::read_dir(parent)
                        .await
                        .map_err(super::dir_store::io_error)?;
                    let (mut before, mut after) = (false, false);
                    while let Some(entry) = reader
                        .next_entry()
                        .await
                        .map_err(super::dir_store::io_error)?
                    {
                        before |= entry.file_name() == old;
                        after |= entry.file_name() == new;
                    }
                    if before == after || Marker::at(&b).await?.as_ref() != Some(marker) {
                        return Err(invalid());
                    }
                    return Ok(after);
                }
                match (Marker::at(&a).await?, Marker::at(&b).await?) {
                    (Some(current), None) if current == *marker => Ok(false),
                    (None, Some(current)) if current == *marker => Ok(true),
                    _ => Err(invalid()),
                }
            }
            Self::Remove {
                path,
                marker,
                recursive,
            } => {
                if !path_valid(path) {
                    return Err(invalid());
                }
                match Marker::at(&store.inside(path).await?).await? {
                    None => Ok(true),
                    Some(current) if current == *marker && !recursive => Ok(false),
                    _ => Err(invalid()),
                }
            }
        }
    }
}

async fn intent(
    store: &DirStore,
    before: &Catalog,
    after: Catalog,
    action: Action,
) -> Result<Transaction> {
    let transaction = Transaction {
        version: 1,
        before: hash(before)?,
        after,
        action,
    };
    store
        .replace(&store.state.join(INTENT), &sealed(&transaction)?)
        .await?;
    Ok(transaction)
}

pub(crate) async fn move_file(
    store: &DirStore,
    catalog: &Catalog,
    from: &str,
    to: &str,
) -> Result<crate::store::DocumentMoveReceipt> {
    if !path_valid(from) || !path_valid(to) || to.starts_with(&format!("{from}/")) {
        return Err(SessionError::new(
            "bad-path",
            "Choose a different destination outside this folder.",
        ));
    }
    let a = store.inside(from).await?;
    let b = store.inside(to).await?;
    let marker = Marker::at(&a)
        .await?
        .ok_or_else(|| SessionError::new("not-found", "No such file or folder."))?;
    let existing = Marker::at(&b).await?;
    if from == to {
        return Ok(crate::store::DocumentMoveReceipt {
            revision: catalog.revision,
            documents: Vec::new(),
        });
    }
    let case_only = existing.as_ref() == Some(&marker)
        && tokio::fs::canonicalize(&a).await.ok() == tokio::fs::canonicalize(&b).await.ok();
    if existing.is_some() && !case_only {
        return Err(SessionError::new(
            "exists",
            "The destination already exists.",
        ));
    }
    let (after, documents) = catalog.moved(from, to)?;
    if encoded(&documents)?.len() > 1024 * 1024 {
        return Err(SessionError::new(
            "too-large",
            "The move contains too many document bindings.",
        ));
    }
    if let Some(parent) = b.parent() {
        super::dir_store::create_directories(parent).await?;
    }
    let transaction = intent(
        store,
        catalog,
        after,
        Action::Move {
            from: from.into(),
            to: to.into(),
            marker,
            case_only,
        },
    )
    .await?;
    rename(&a, &b, case_only).await?;
    for parent in [a.parent(), b.parent()].into_iter().flatten() {
        super::dir_store::sync_directory(parent).await?;
    }
    save(store, &transaction.after).await?;
    clear(store).await?;
    Ok(crate::store::DocumentMoveReceipt {
        revision: transaction.after.revision,
        documents,
    })
}
pub(crate) async fn remove_file(
    store: &DirStore,
    catalog: &Catalog,
    path: &str,
    recursive: bool,
) -> Result<()> {
    if !path_valid(path) {
        return Err(SessionError::new(
            "outside",
            "The workspace itself cannot be removed.",
        ));
    }
    let file = store.inside(path).await?;
    let marker = Marker::at(&file)
        .await?
        .ok_or_else(|| SessionError::new("not-found", "No such file or folder."))?;
    let after = catalog.removed(path)?;
    let transaction = intent(
        store,
        catalog,
        after,
        Action::Remove {
            path: path.into(),
            marker: marker.clone(),
            recursive: recursive && marker.kind == 2,
        },
    )
    .await?;
    if marker.kind == 2 {
        if recursive {
            tokio::fs::remove_dir_all(&file).await
        } else {
            tokio::fs::remove_dir(&file).await
        }
    } else {
        tokio::fs::remove_file(&file).await
    }
    .map_err(super::dir_store::io_error)?;
    super::dir_store::sync_directory(file.parent().ok_or_else(invalid)?).await?;
    save(store, &transaction.after).await?;
    clear(store).await
}

pub(crate) async fn rename(from: &Path, to: &Path, case_only: bool) -> Result<()> {
    let from = from.to_path_buf();
    let to = to.to_path_buf();
    tokio::task::spawn_blocking(move || {
        if case_only {
            return std::fs::rename(from, to).map_err(super::dir_store::io_error);
        }
        #[cfg(unix)]
        {
            use std::{ffi::CString, os::unix::ffi::OsStrExt};
            let a = CString::new(from.as_os_str().as_bytes()).map_err(|_| invalid())?;
            let b = CString::new(to.as_os_str().as_bytes()).map_err(|_| invalid())?;
            #[cfg(target_os = "macos")]
            let result = unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_EXCL) };
            #[cfg(target_os = "linux")]
            let result = unsafe {
                libc::syscall(
                    libc::SYS_renameat2,
                    libc::AT_FDCWD,
                    a.as_ptr(),
                    libc::AT_FDCWD,
                    b.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            return Err(SessionError::new(
                "unsupported",
                "This platform does not provide exclusive document moves.",
            ));
            #[cfg(any(target_os = "linux", target_os = "macos"))]
            if result != 0 {
                return Err(super::dir_store::io_error(std::io::Error::last_os_error()));
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::Storage::FileSystem::{MOVEFILE_WRITE_THROUGH, MoveFileExW};
            let a: Vec<_> = from.as_os_str().encode_wide().chain(Some(0)).collect();
            let b: Vec<_> = to.as_os_str().encode_wide().chain(Some(0)).collect();
            if unsafe { MoveFileExW(a.as_ptr(), b.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
                return Err(super::dir_store::io_error(std::io::Error::last_os_error()));
            }
        }
        Ok(())
    })
    .await
    .map_err(|_| invalid())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::FileStore;

    #[tokio::test]
    async fn move_intent_recovers_before_disk_after_disk_and_after_catalog_publication() {
        for phase in 0..3 {
            let root = tempfile::tempdir().unwrap();
            let state = tempfile::tempdir().unwrap();
            std::fs::write(root.path().join("old.txt"), "saved").unwrap();
            let store = DirStore::with_state_root(root.path(), state.path()).unwrap();
            store.write_state("doc:old.txt", &[0, 0]).await.unwrap();
            let before = load(&store).await.unwrap();
            let id = before.id("old.txt").unwrap().to_owned();
            let (after, _) = before.moved("old.txt", "new.txt").unwrap();
            intent(
                &store,
                &before,
                after.clone(),
                Action::Move {
                    from: "old.txt".into(),
                    to: "new.txt".into(),
                    marker: Marker::at(&root.path().join("old.txt"))
                        .await
                        .unwrap()
                        .unwrap(),
                    case_only: false,
                },
            )
            .await
            .unwrap();
            if phase >= 1 {
                rename(
                    &root.path().join("old.txt"),
                    &root.path().join("new.txt"),
                    false,
                )
                .await
                .unwrap();
            }
            if phase == 2 {
                save(&store, &after).await.unwrap();
            }
            drop(store);
            let store = DirStore::with_state_root(root.path(), state.path()).unwrap();
            let path = if phase == 0 { "old.txt" } else { "new.txt" };
            assert_eq!(
                store.document_path(&id).await.unwrap().as_deref(),
                Some(path)
            );
            assert_eq!(
                std::fs::read_to_string(root.path().join(path)).unwrap(),
                "saved"
            );
            assert!(!store.state.join(INTENT).exists());
            assert_eq!(
                store.read_state(&format!("doc:{path}")).await.unwrap(),
                Some(vec![0, 0])
            );
        }
    }

    #[tokio::test]
    async fn conflicting_disk_outcomes_remain_fenced_without_overwriting_either_file() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("old.txt"), "original").unwrap();
        let store = DirStore::with_state_root(root.path(), state.path()).unwrap();
        store.write_state("doc:old.txt", &[0, 0]).await.unwrap();
        let before = load(&store).await.unwrap();
        let (after, _) = before.moved("old.txt", "new.txt").unwrap();
        intent(
            &store,
            &before,
            after,
            Action::Move {
                from: "old.txt".into(),
                to: "new.txt".into(),
                marker: Marker::at(&root.path().join("old.txt"))
                    .await
                    .unwrap()
                    .unwrap(),
                case_only: false,
            },
        )
        .await
        .unwrap();
        std::fs::write(root.path().join("new.txt"), "external").unwrap();
        drop(store);
        let store = DirStore::with_state_root(root.path(), state.path()).unwrap();
        assert_eq!(store.list("").await.unwrap_err().code, "recovery-required");
        assert_eq!(
            std::fs::read_to_string(root.path().join("old.txt")).unwrap(),
            "original"
        );
        assert_eq!(
            std::fs::read_to_string(root.path().join("new.txt")).unwrap(),
            "external"
        );
        assert!(store.state.join(INTENT).exists());
    }

    #[tokio::test]
    async fn deletion_intents_retire_ids_only_after_the_disk_entry_is_removed() {
        for applied in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let state = tempfile::tempdir().unwrap();
            std::fs::write(root.path().join("file.txt"), "saved").unwrap();
            let store = DirStore::with_state_root(root.path(), state.path()).unwrap();
            store.write_state("doc:file.txt", &[0, 0]).await.unwrap();
            let before = load(&store).await.unwrap();
            let id = before.id("file.txt").unwrap().to_owned();
            let after = before.removed("file.txt").unwrap();
            intent(
                &store,
                &before,
                after,
                Action::Remove {
                    path: "file.txt".into(),
                    marker: Marker::at(&root.path().join("file.txt"))
                        .await
                        .unwrap()
                        .unwrap(),
                    recursive: false,
                },
            )
            .await
            .unwrap();
            if applied {
                std::fs::remove_file(root.path().join("file.txt")).unwrap();
            }
            drop(store);
            let store = DirStore::with_state_root(root.path(), state.path()).unwrap();
            assert_eq!(
                store.document_path(&id).await.unwrap(),
                (!applied).then(|| "file.txt".into())
            );
            assert!(!store.state.join(INTENT).exists());
        }
    }

    #[test]
    fn full_width_filesystem_identifiers_round_trip_without_precision_loss() {
        let marker = Marker {
            volume: 42,
            file: (1u128 << 110) + 123,
            kind: 2,
        };
        let bytes = sealed(&marker).unwrap();
        let decoded: Marker = unseal(&bytes).unwrap();
        assert!(decoded == marker);
    }
}
