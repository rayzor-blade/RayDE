//! Saves the workspace's tree back into the cloud copy it was restored from, as the holder of the capability the runner gave this session.
use crate::error::{Result, SessionError};
use rayde_sync::client::{Config, run};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};

pub struct Writeback {
    gateway: String,
    workspace: String,
    token: String,
    /// The generation of the cloud copy this tree is based on: where it was restored from, then what the last save published.
    generation: Mutex<u64>,
    saving: tokio::sync::Mutex<()>,
}

impl Writeback {
    pub fn from_env() -> Option<Arc<Self>> {
        let get = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        Some(Arc::new(Writeback {
            gateway: get("RAYDE_SYNC_GATEWAY")?,
            workspace: get("RAYDE_SYNC_WORKSPACE")?,
            token: get("RAYDE_SYNC_TOKEN")?,
            generation: Mutex::new(get("RAYDE_SYNC_GENERATION")?.parse().ok()?),
            saving: tokio::sync::Mutex::new(()),
        }))
    }

    pub fn describe(&self) -> Value {
        json!({"workspace": self.workspace, "generation": *self.generation.lock().unwrap()})
    }

    /// Scans `root` and publishes it as the next generation. One save runs at a time; a cloud copy that has moved on is a `conflict` and nothing is sent.
    pub async fn publish(self: &Arc<Self>, root: PathBuf) -> Result<Value> {
        let _one = self.saving.lock().await;
        let base = *self.generation.lock().unwrap();
        let config = Config {
            root,
            gateway: self.gateway.clone(),
            account: None,
            device: Some("browser session".into()),
            history: false,
            action: "writeback".into(),
            workspace: Some(self.workspace.clone()),
            token: Some(self.token.clone()),
            base_generation: Some(base),
        };
        let outcome = tokio::task::spawn_blocking(move || {
            let (mut scanned, mut published) = (Value::Null, Value::Null);
            run(&config, &mut |event| match event["event"].as_str() {
                Some("scanned") => scanned = event,
                Some("published") => published = event,
                _ => {}
            }, &|| false)
            .map(|()| (scanned, published))
        })
        .await
        .map_err(|_| SessionError::new("sync-failed", "The save stopped before it finished."))?;
        match outcome {
            Ok((scanned, published)) => {
                let generation = published["generation"].as_u64().ok_or_else(|| SessionError::new("sync-failed", "The cloud copy did not report a generation."))?;
                *self.generation.lock().unwrap() = generation;
                Ok(json!({"generation": generation, "files": scanned["files"], "bytes": scanned["bytes"], "stored": published["stored"]}))
            }
            Err(failure) if failure.code == "conflict" => Err(SessionError::new("conflict", failure.message)),
            Err(failure) => Err(SessionError::new("sync-failed", failure.message)),
        }
    }
}
