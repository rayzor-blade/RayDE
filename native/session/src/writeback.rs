//! Cloud write-back keeps its common base and operation intents in the session's private state.
use crate::{
    dir_store::DirStore,
    error::{Result, SessionError},
    store::FileStore,
    sync_state::{self as state, Binding, Expected},
};
use rayde_sync::client::{self, Base, Config};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use subtle::ConstantTimeEq;

struct Status {
    generation: u64,
    ready: bool,
    message: String,
    error: Option<String>,
}
pub struct Writeback {
    store: Arc<DirStore>,
    gateway: String,
    workspace: String,
    token: Mutex<String>,
    control: Option<String>,
    restored: u64,
    fresh: bool,
    status: Mutex<Status>,
    working: tokio::sync::Mutex<()>,
}

impl Writeback {
    pub fn from_env(store: Arc<DirStore>) -> Option<Arc<Self>> {
        let get = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        let restored = get("RAYDE_SYNC_GENERATION")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        Some(Arc::new(Self {
            store,
            gateway: get("RAYDE_SYNC_GATEWAY")?.trim_end_matches('/').into(),
            workspace: get("RAYDE_SYNC_WORKSPACE")?,
            token: Mutex::new(get("RAYDE_SYNC_TOKEN")?),
            control: get("RAYDE_SYNC_CONTROL"),
            restored,
            fresh: get("RAYDE_SYNC_FRESH").as_deref() == Some("1"),
            status: Mutex::new(Status {
                generation: restored,
                ready: false,
                message: "Connecting Cloud Sync…".into(),
                error: None,
            }),
            working: tokio::sync::Mutex::new(()),
        }))
    }
    fn config(&self) -> Config {
        Config {
            root: self.store.root().into(),
            gateway: self.gateway.clone(),
            account: None,
            device: Some("browser session".into()),
            history: false,
            action: String::new(),
            workspace: Some(self.workspace.clone()),
            token: Some(self.token.lock().unwrap().clone()),
            base_generation: None,
            force: false,
            choices: BTreeMap::new(),
            path: None,
        }
    }
    pub fn describe(&self) -> Value {
        let status = self.status.lock().unwrap();
        json!({"workspace":self.workspace,"generation":status.generation,"ready":status.ready,"message":status.message,"error":status.error})
    }
    fn ready(&self, base: &Base) {
        *self.status.lock().unwrap() = Status {
            generation: base.generation(),
            ready: true,
            message: String::new(),
            error: None,
        };
    }
    fn failure(&self, error: &SessionError) {
        let mut status = self.status.lock().unwrap();
        status.ready = false;
        status.message = error.message.clone();
        status.error = Some(error.code.into());
    }
    /// The control credential belongs only to the runner; ordinary session connections never receive it.
    pub fn authorize(
        &self,
        control: &str,
        gateway: &str,
        workspace: &str,
        token: &str,
    ) -> Result<Value> {
        if !self
            .control
            .as_ref()
            .is_some_and(|key| bool::from(key.as_bytes().ct_eq(control.as_bytes())))
            || gateway.trim_end_matches('/') != self.gateway
            || workspace != self.workspace
            || token.is_empty()
            || token.len() > 4096
            || !token.bytes().all(|b| b.is_ascii_graphic())
        {
            return Err(SessionError::new(
                "forbidden",
                "The Cloud Sync credential could not be verified.",
            ));
        }
        *self.token.lock().unwrap() = token.into();
        Ok(json!({"syncWriteback":self.describe()}))
    }
    async fn record(
        &self,
        key: &str,
        base: &Base,
        operation: Option<&str>,
        expected: Vec<Expected>,
    ) -> Result<()> {
        let bytes = state::pack(&self.gateway, base, operation, expected)?;
        self.store.write_state(key, &bytes).await
    }
    async fn clear_pending(&self) -> Result<()> {
        self.store.write_state(state::PENDING, b"").await
    }
    async fn current(&self) -> Result<Base> {
        let binding = self.store.read_sync_state(state::BINDING, 4096).await?;
        let mut binding: Binding = match binding {
            Some(bytes) if bytes.len() <= 4096 => {
                serde_json::from_slice(&bytes).map_err(|_| state::invalid())?
            }
            None if self.fresh && self.restored > 0 => {
                if self
                    .store
                    .read_sync_state(state::BASE, state::MAX_RECORD)
                    .await?
                    .is_some()
                {
                    return Err(state::invalid());
                }
                let value = Binding {
                    version: 1,
                    workspace: self.workspace.clone(),
                    gateway: self.gateway.clone(),
                    restored: self.restored,
                    initialized: false,
                };
                self.store
                    .write_state(
                        state::BINDING,
                        &serde_json::to_vec(&value).map_err(|_| state::invalid())?,
                    )
                    .await?;
                value
            }
            _ => return Err(state::invalid()),
        };
        if binding.version != 1
            || binding.workspace != self.workspace
            || binding.gateway != self.gateway
            || binding.restored == 0
        {
            return Err(state::invalid());
        }
        let mut base = match self
            .store
            .read_sync_state(state::BASE, state::MAX_RECORD)
            .await?
        {
            Some(bytes) => {
                let record = state::unpack(&bytes, &self.gateway, &self.workspace)?;
                if record.operation.is_some() {
                    return Err(state::invalid());
                }
                record.base
            }
            None if !binding.initialized => {
                let mut config = self.config();
                config.base_generation = Some(binding.restored);
                let base = tokio::task::spawn_blocking(move || client::capture_cloud(&config))
                    .await
                    .map_err(|_| state::invalid())?
                    .map_err(|failure| {
                        if failure.code == "conflict" {
                            state::invalid()
                        } else {
                            map_failure(failure)
                        }
                    })?;
                self.record(state::BASE, &base, None, vec![]).await?;
                base
            }
            _ => return Err(state::invalid()),
        };
        if base.generation() < binding.restored {
            return Err(state::invalid());
        }
        if !binding.initialized {
            binding.initialized = true;
            self.store
                .write_state(
                    state::BINDING,
                    &serde_json::to_vec(&binding).map_err(|_| state::invalid())?,
                )
                .await?;
        }
        if let Some(bytes) = self
            .store
            .read_sync_state(state::PENDING, state::MAX_RECORD)
            .await?
            .filter(|bytes| !bytes.is_empty())
        {
            let pending = state::unpack(&bytes, &self.gateway, &self.workspace)?;
            if pending.operation.is_none() {
                return Err(state::invalid());
            }
            if pending.base.manifest == base.manifest {
                self.clear_pending().await?;
            } else {
                if pending.base.generation() <= base.generation()
                    || pending.operation.as_deref() == Some("publish")
                        && pending.base.manifest.base_generation != base.generation()
                {
                    return Err(state::invalid());
                }
                let complete = match pending.operation.as_deref() {
                    Some("publish") => {
                        let config = self.config();
                        let remote =
                            tokio::task::spawn_blocking(move || client::current_manifest(&config))
                                .await
                                .map_err(|_| state::invalid())?
                                .map_err(map_failure)?;
                        if remote == base.manifest {
                            self.clear_pending().await?;
                            return Ok(base);
                        }
                        remote == pending.base.manifest
                    }
                    Some("merge") => {
                        let root = self.store.root().to_path_buf();
                        let expected = pending.expected.clone();
                        tokio::task::spawn_blocking(move || {
                            expected.iter().all(|change| change.matches(&root))
                        })
                        .await
                        .map_err(|_| state::invalid())?
                    }
                    _ => false,
                };
                if !complete {
                    return Err(state::invalid());
                }
                if pending.operation.as_deref() == Some("merge") {
                    let root = self.store.root().to_path_buf();
                    let expected = pending.expected.clone();
                    tokio::task::spawn_blocking(move || state::flush(&root, &expected))
                        .await
                        .map_err(|_| state::invalid())??;
                }
                self.record(state::BASE, &pending.base, None, vec![])
                    .await?;
                self.clear_pending().await?;
                base = pending.base;
            }
        }
        Ok(base)
    }
    pub async fn initialize(self: Arc<Self>) {
        let _one = self.working.lock().await;
        match self.current().await {
            Ok(base) => self.ready(&base),
            Err(error) => self.failure(&error),
        }
    }
    pub async fn publish(self: &Arc<Self>, _root: PathBuf) -> Result<Value> {
        let this = self.clone();
        tokio::spawn(async move { this.publish_inner().await })
            .await
            .map_err(|_| state::invalid())?
    }
    async fn publish_inner(&self) -> Result<Value> {
        let _one = self.working.lock().await;
        let result=async{
            let base=self.current().await?;let config=self.config();let store=self.store.clone();let gateway=self.gateway.clone();let runtime=tokio::runtime::Handle::current();
            let saved=tokio::task::spawn_blocking(move||client::save_before(&config,&base,&mut |_|{},&||false,&mut |next|{
                let bytes=state::pack(&gateway,next,Some("publish"),vec![]).map_err(local_failure)?;
                runtime.block_on(store.write_state(state::PENDING,&bytes)).map_err(local_failure)
            })).await.map_err(|_|state::invalid())?;
            match saved {
                Ok(next)=>{
                    self.record(state::BASE,&next,None,vec![]).await?;self.clear_pending().await?;self.ready(&next);
                    Ok(json!({"generation":next.generation(),"files":next.manifest.files.len(),"bytes":next.manifest.totals.bytes}))
                }
                Err(failure)=>{
                    if matches!(failure.status,Some(401|403|409|422)){self.clear_pending().await?;}
                    Err(map_failure(failure))
                }
            }
        }.await;
        if let Err(error) = &result {
            self.failure(error);
        }
        result
    }
    pub async fn remote(self: &Arc<Self>, _root: PathBuf, path: String) -> Result<Value> {
        let mut config = self.config();
        config.path = Some(path);
        let text = tokio::task::spawn_blocking(move || client::remote_text(&config))
            .await
            .map_err(|_| state::invalid())?
            .map_err(map_failure)?;
        Ok(json!({"text":text}))
    }
    pub async fn merge(
        self: &Arc<Self>,
        _root: PathBuf,
        choices: BTreeMap<String, String>,
    ) -> Result<Value> {
        let this = self.clone();
        tokio::spawn(async move { this.merge_inner(choices).await })
            .await
            .map_err(|_| state::invalid())?
    }
    async fn merge_inner(&self, choices: BTreeMap<String, String>) -> Result<Value> {
        let _one = self.working.lock().await;
        let result=async{
            let base=self.current().await?;let config=self.config();let store=self.store.clone();let gateway=self.gateway.clone();let runtime=tokio::runtime::Handle::current();
            let (merged,expected)=tokio::task::spawn_blocking(move||{
                let mut expected=vec![];
                let result=client::merge_before(&config,&base,&choices,&mut |next,actions|{
                    expected=actions.iter().map(Expected::from_action).collect();
                    let bytes=state::pack(&gateway,next,Some("merge"),expected.clone()).map_err(local_failure)?;
                    runtime.block_on(store.write_state(state::PENDING,&bytes)).map_err(local_failure)
                });(result,expected)
            }).await.map_err(|_|state::invalid())?;
            let (next,report)=merged.map_err(map_failure)?;
            if report.conflicts.is_empty(){
                let root=self.store.root().to_path_buf();tokio::task::spawn_blocking(move||state::flush(&root,&expected)).await.map_err(|_|state::invalid())??;
                self.record(state::BASE,&next,None,vec![]).await?;self.clear_pending().await?;self.ready(&next);
            }
            Ok(json!({"generation":report.generation,"written":report.written,"deleted":report.deleted,
                "conflicts":report.conflicts.iter().map(|(path,reason)|json!({"path":path,"reason":reason})).collect::<Vec<_>>()}))
        }.await;
        if let Err(error) = &result {
            self.failure(error);
        }
        result
    }
}
fn local_failure(error: SessionError) -> client::Failure {
    client::Failure {
        code: "sync-recovery".into(),
        message: error.message,
        status: None,
    }
}
fn map_failure(failure: client::Failure) -> SessionError {
    let code = match failure.code.as_str() {
        "conflict" => "conflict",
        "auth-required" => "sync-auth",
        "sync-recovery" => "sync-recovery",
        _ => "sync-failed",
    };
    SessionError::new(
        code,
        if code == "sync-auth" {
            "Your Cloud Sync session expired. Reopen this workspace to continue.".into()
        } else {
            failure.message
        },
    )
}

#[cfg(test)]
#[path = "writeback_tests.rs"]
mod tests;
