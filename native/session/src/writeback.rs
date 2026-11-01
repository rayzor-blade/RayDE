//! Saves the workspace's tree back into the cloud copy it was restored from, and brings the cloud copy's newer generation into it, as the holder of the
//! capability the runner gave this session. It keeps what the tree was a copy of, so a merge has the version both sides started from.
use crate::error::{Result, SessionError};
use rayde_sync::client::{Base, Config, capture, merge_cloud, save};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};

pub struct Writeback {
    gateway: String,
    workspace: String,
    token: String,
    /// The generation this tree is based on until `base` is captured: where it was restored from.
    restored: u64,
    /// What the tree is a copy of, once captured and again after every save or merge.
    base: Mutex<Option<Base>>,
    working: tokio::sync::Mutex<()>,
}

impl Writeback {
    pub fn from_env() -> Option<Arc<Self>> {
        let get = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        Some(Arc::new(Writeback {
            gateway: get("RAYDE_SYNC_GATEWAY")?,
            workspace: get("RAYDE_SYNC_WORKSPACE")?,
            token: get("RAYDE_SYNC_TOKEN")?,
            restored: get("RAYDE_SYNC_GENERATION")?.parse().ok()?,
            base: Mutex::new(None),
            working: tokio::sync::Mutex::new(()),
        }))
    }

    fn config(&self, root: PathBuf) -> Config {
        Config {
            root,
            gateway: self.gateway.clone(),
            account: None,
            device: Some("browser session".into()),
            history: false,
            action: String::new(),
            workspace: Some(self.workspace.clone()),
            token: Some(self.token.clone()),
            base_generation: Some(self.restored),
            force: false,
        }
    }

    pub fn describe(&self) -> Value {
        let generation = self.base.lock().unwrap().as_ref().map_or(self.restored, Base::generation);
        json!({"workspace": self.workspace, "generation": generation})
    }

    /// Records what the tree is a copy of. Run as soon as the session starts, before anything edits the tree.
    pub fn capture(&self, root: PathBuf) {
        if let Ok(base) = capture(&self.config(root)) {
            *self.base.lock().unwrap() = Some(base);
        }
    }

    fn current(&self, root: PathBuf) -> Result<Base> {
        if let Some(base) = self.base.lock().unwrap().clone() {
            return Ok(base);
        }
        // The capture did not finish; the tree is then taken as a copy of the generation it was restored from, with no text to merge from.
        capture(&self.config(root)).map_err(|failure| SessionError::new(if failure.code == "conflict" { "conflict" } else { "sync-failed" }, failure.message))
    }

    /// Scans `root` and publishes it as the next generation. One save or merge runs at a time; a cloud copy that has moved on is a `conflict` and nothing is sent.
    pub async fn publish(self: &Arc<Self>, root: PathBuf) -> Result<Value> {
        let _one = self.working.lock().await;
        let base = self.current(root.clone())?;
        let config = self.config(root);
        let outcome = tokio::task::spawn_blocking(move || save(&config, &base, &mut |_| {}, &|| false)).await.map_err(|_| SessionError::new("sync-failed", "The save stopped before it finished."))?;
        match outcome {
            Ok(saved) => {
                let answer = json!({"generation": saved.generation(), "files": saved.manifest.files.len(), "bytes": saved.manifest.totals.bytes});
                *self.base.lock().unwrap() = Some(saved);
                Ok(answer)
            }
            Err(failure) if failure.code == "conflict" => Err(SessionError::new("conflict", failure.message)),
            Err(failure) => Err(SessionError::new("sync-failed", failure.message)),
        }
    }

    /// Brings the cloud copy's newer generation into the tree. Files that cannot be decided for the person are listed and nothing is changed.
    pub async fn merge(self: &Arc<Self>, root: PathBuf) -> Result<Value> {
        let _one = self.working.lock().await;
        let base = self.current(root.clone())?;
        let config = self.config(root);
        let outcome = tokio::task::spawn_blocking(move || merge_cloud(&config, &base)).await.map_err(|_| SessionError::new("sync-failed", "The merge stopped before it finished."))?;
        match outcome {
            Ok((next, report)) => {
                if report.conflicts.is_empty() {
                    *self.base.lock().unwrap() = Some(next);
                }
                Ok(json!({
                    "generation": report.generation,
                    "written": report.written,
                    "deleted": report.deleted,
                    "conflicts": report.conflicts.iter().map(|(path, reason)| json!({"path": path, "reason": reason})).collect::<Vec<_>>(),
                }))
            }
            Err(failure) => Err(SessionError::new("sync-failed", failure.message)),
        }
    }
}
