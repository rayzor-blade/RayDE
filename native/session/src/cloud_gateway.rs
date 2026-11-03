//! Bounded cloud I/O uses blocking workers; credentials remain owned by the session.
use crate::{
    cloud::{self, Binding, Exchanged, Opened, Provider},
    error::{Result, SessionError},
    writeback::Writeback,
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::future::BoxFuture;
use rayde_sync::{
    client::{self, documents},
    live::Seed,
    manifest::FileKind,
};
use std::sync::Arc;

pub struct Gateway {
    writeback: Arc<Writeback>,
    permits: tokio::sync::Semaphore,
}
impl Gateway {
    pub fn new(writeback: Arc<Writeback>) -> Self {
        Self {
            writeback,
            permits: tokio::sync::Semaphore::new(8),
        }
    }
}
fn failure(failure: client::Failure) -> SessionError {
    let code = match failure.status {
        Some(401) => "sync-auth",
        Some(403 | 409) => "document-lineage",
        _ => {
            if failure.code == "network" {
                "cloud-offline"
            } else {
                "cloud-failed"
            }
        }
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
fn binding(gateway: &str, reply: &documents::Reply) -> Binding {
    Binding {
        version: 1,
        gateway: gateway.into(),
        seed: serde_json::to_value(&reply.seed).unwrap(),
        vector: B64.encode(&reply.vector),
        sequence: reply.sequence,
    }
}
impl Provider for Gateway {
    fn open<'a>(
        &'a self,
        path: &'a str,
        disk: &'a str,
        previous: Option<Binding>,
    ) -> BoxFuture<'a, Result<Option<Opened>>> {
        Box::pin(async move {
            let _permit = self.permits.acquire().await.map_err(|_| cloud::lineage())?;
            let config = self.writeback.config();
            let (path, disk) = (path.to_string(), disk.to_string());
            tokio::task::spawn_blocking(move||{
   if let Some(old)=&previous{old.validate()?;if old.gateway!=config.gateway||old.seed["path"]!=path||old.seed["workspace"].as_str()!=config.workspace.as_deref(){return Err(cloud::lineage())}}
   let manifest=documents::manifest(&config).map_err(failure)?;
   let supported=manifest.files.iter().any(|file|file.path==path&&matches!(file.kind,FileKind::Regular|FileKind::Executable)&&file.size<=rayde_sync::live::MAX_TEXT as u64);
   if !supported{return if previous.is_some(){Err(cloud::lineage())}else{Ok(None)}}
   let reply=documents::open(&config,&path,manifest.generation).map_err(failure)?;
   if let Some(old)=previous{if old.seed!=serde_json::to_value(&reply.seed).unwrap()||old.sequence>reply.sequence{return Err(cloud::lineage())}}
   else if reply.anchor!=crate::checkpoint::digest(disk.as_bytes()){return Err(SessionError::new("recovery-conflict","The saved file differs from the published cloud file. Reconcile saved-file changes before enabling live sync."))}
   Ok(Some(Opened{binding:binding(&config.gateway,&reply),state:reply.update}))
  }).await.map_err(|_|cloud::lineage())?
        })
    }
    fn exchange<'a>(
        &'a self,
        previous: Binding,
        update: Vec<u8>,
    ) -> BoxFuture<'a, Result<Exchanged>> {
        Box::pin(async move {
            let _permit = self.permits.acquire().await.map_err(|_| cloud::lineage())?;
            let config = self.writeback.config();
            tokio::task::spawn_blocking(move || {
                previous.validate()?;
                let seed: Seed =
                    serde_json::from_value(previous.seed.clone()).map_err(|_| cloud::lineage())?;
                if previous.gateway != config.gateway
                    || Some(seed.workspace.as_str()) != config.workspace.as_deref()
                {
                    return Err(cloud::lineage());
                }
                let from = B64.decode(&previous.vector).map_err(|_| cloud::lineage())?;
                let reply = documents::exchange(&config, &seed, &from, &update).map_err(failure)?;
                if reply.sequence < previous.sequence {
                    return Err(cloud::lineage());
                }
                Ok(Exchanged {
                    binding: binding(&config.gateway, &reply),
                    update: reply.update,
                    sha256: reply.sha256,
                })
            })
            .await
            .map_err(|_| cloud::lineage())?
        })
    }
}
