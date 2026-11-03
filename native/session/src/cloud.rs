//! A document's cloud binding travels atomically with its private recovery graph.
use crate::{
    checkpoint,
    error::{Result, SessionError},
};
use futures_util::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub version: u32,
    pub gateway: String,
    pub seed: Value,
    pub vector: String,
    pub sequence: u64,
}
impl Binding {
    pub fn lineage(&self) -> Result<&str> {
        self.seed["lineage"]
            .as_str()
            .filter(|v| crate::buffer_state::digest(v))
            .ok_or_else(lineage)
    }
    pub fn validate(&self) -> Result<()> {
        if self.version != 1
            || self.gateway.is_empty()
            || self.gateway.len() > 2048
            || self.sequence == 0
            || serde_json::to_vec(&self.seed).map_err(|_| lineage())?.len() > 8192
        {
            return Err(lineage());
        }
        self.lineage()?;
        checkpoint::decode_vector(&self.vector)?;
        Ok(())
    }
}
pub struct Opened {
    pub binding: Binding,
    pub state: Vec<u8>,
}
pub struct Exchanged {
    pub binding: Binding,
    pub update: Vec<u8>,
    pub sha256: String,
}
pub trait Provider: Send + Sync {
    fn open<'a>(
        &'a self,
        path: &'a str,
        disk: &'a str,
        previous: Option<Binding>,
    ) -> BoxFuture<'a, Result<Option<Opened>>>;
    fn exchange<'a>(
        &'a self,
        binding: Binding,
        update: Vec<u8>,
    ) -> BoxFuture<'a, Result<Exchanged>>;
}
pub fn lineage() -> SessionError {
    SessionError::new(
        "document-lineage",
        "This document belongs to another cloud history. Its previous recovery has been kept; reconcile it before continuing live sync.",
    )
}
pub fn offline(error: &SessionError) -> bool {
    matches!(error.code, "cloud-offline" | "sync-auth")
}
