use super::*;
use std::{
    collections::BTreeMap,
    fs::File,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, watch};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    pub version: u32,
    pub id: String,
    pub owner: u64,
    pub repository: Repository,
    pub sandbox: String,
    pub token: String,
    pub phase: String,
    pub generation: u64,
    pub project: Option<String>,
    #[serde(default)]
    pub identity: Option<serde_json::Value>,
    #[serde(default)]
    pub toolchain: Option<String>,
    #[serde(default)]
    pub storage: Option<crate::volumes::Storage>,
    #[serde(default)]
    pub recovery_attempts: Vec<u64>,
}
pub(crate) struct Cell {
    pub record: Mutex<Record>,
    pub connections: Arc<Semaphore>,
    pub closed: watch::Sender<u64>,
    pub active: AtomicBool,
    work: Arc<Semaphore>,
}
// Blocking extraction can outlive a cancelled request. Keep its workspace lease
// and the registry's process lock until that work has actually stopped.
pub(crate) struct Work {
    _permit: OwnedSemaphorePermit,
    _lock: Arc<File>,
}
pub(crate) struct Registry {
    pub records: Mutex<BTreeMap<String, Arc<Cell>>>,
    pub instance: String,
    root: PathBuf,
    _lock: Arc<File>,
}
impl Registry {
    pub async fn load(root: &Path) -> Result<Self> {
        private_dir(root).await?;
        private_dir(&root.join("records")).await?;
        private_dir(&root.join("checkout")).await?;
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(root.join("runner.lock"))?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                return Err(unavailable());
            }
        }
        let instance = match tokio::fs::read_to_string(root.join("instance")).await {
            Ok(value) if value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit()) => value,
            Ok(_) => return Err(unavailable()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let value = random();
                private_write(&root.join("instance"), value.as_bytes()).await?;
                value
            }
            Err(_) => return Err(unavailable()),
        };
        let mut records = BTreeMap::new();
        let mut entries = tokio::fs::read_dir(root.join("records")).await?;
        while let Some(entry) = entries.next_entry().await? {
            if entry.path().extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            if !entry.file_type().await?.is_file()
                || entry.metadata().await?.len() > 8192
                || records.len() >= 256
            {
                return Err(unavailable());
            }
            let record: Record = serde_json::from_slice(&tokio::fs::read(entry.path()).await?)
                .map_err(|_| unavailable())?;
            if record.version != 1
                || record.owner == 0
                || workspace_id(record.owner, record.repository.id) != record.id
                || !valid_repository(&record.repository)
                || record.token.len() != 64
                || record.generation == 0
                || record.sandbox
                    != format!(
                        "rayde-{}-{}-{}",
                        &instance[..16],
                        record.id,
                        record.generation
                    )
                || entry.path().file_stem().and_then(|value| value.to_str())
                    != Some(record.id.as_str())
                || !matches!(
                    record.phase.as_str(),
                    "preparing" | "recovering" | "ready" | "failed" | "deleting" | "deleted" | "recovery-required"
                )
            {
                return Err(unavailable());
            }
            if record.phase == "ready" && record.identity.is_none() {
                return Err(unavailable());
            }
            if record.toolchain.as_ref().is_some_and(|value| value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit())) {
                return Err(unavailable());
            }
            if record.recovery_attempts.len() > 3 {return Err(unavailable());}
            if record.storage.as_ref().is_some_and(|storage| !storage.valid(&instance, &record.id)) {
                return Err(unavailable());
            }
            records.insert(record.id.clone(), Arc::new(Cell::new(record)));
        }
        Ok(Self {
            records: Mutex::new(records),
            instance,
            root: root.into(),
            _lock: Arc::new(lock),
        })
    }
    pub async fn save(&self, record: &Record) -> Result<()> {
        private_write(
            &self
                .root
                .join("records")
                .join(format!("{}.json", record.id)),
            &serde_json::to_vec(record).map_err(|_| unavailable())?,
        )
        .await
    }
    pub fn work(&self, cell: &Cell) -> Result<Arc<Work>> {
        let permit = cell.work.clone().try_acquire_owned().map_err(|_| {
            Failure(
                StatusCode::CONFLICT,
                "The previous workspace operation is still settling.",
            )
        })?;
        Ok(Arc::new(Work {
            _permit: permit,
            _lock: self._lock.clone(),
        }))
    }
}
impl Cell {
    pub fn new(record: Record) -> Self {
        let (closed, _) = watch::channel(0);
        let active = AtomicBool::new(!matches!(record.phase.as_str(), "failed" | "deleted"));
        Self {
            record: Mutex::new(record),
            connections: Arc::new(Semaphore::new(8)),
            closed,
            active,
            work: Arc::new(Semaphore::new(1)),
        }
    }
    pub fn deactivate(&self) {
        self.active.store(false, Ordering::Release);
    }
}
