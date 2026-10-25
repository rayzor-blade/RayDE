//! The session's storage seam. The server keeps a workspace in a directory; a Durable Object keeps it in its own storage.
use crate::error::{Result, SessionError};
use serde::Serialize;
use std::{future::Future, sync::Arc};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub kind: &'static str,
    pub size: u64,
    pub mtime: u64,
}

pub type Change = Arc<dyn Fn(String, &'static str) + Send + Sync>;

pub trait FileStore: Send + Sync + 'static {
    /// The workspace's own name, for display.
    fn name(&self) -> String;
    /// The workspace's absolute path where programs run, so paths a client builds are the ones programs see.
    fn root(&self) -> String;
    fn list(&self, path: &str) -> impl Future<Output = Result<Vec<Entry>>> + Send;
    fn stat(&self, path: &str) -> impl Future<Output = Result<Option<Entry>>> + Send;
    fn read(&self, path: &str) -> impl Future<Output = Result<Vec<u8>>> + Send;
    fn write(&self, path: &str, data: &[u8]) -> impl Future<Output = Result<()>> + Send;
    fn mkdir(&self, path: &str) -> impl Future<Output = Result<()>> + Send;
    fn remove(&self, path: &str, recursive: bool) -> impl Future<Output = Result<()>> + Send;
    fn rename(&self, from: &str, to: &str) -> impl Future<Output = Result<()>> + Send;
    /// Calls `change` with each path changed in the workspace, the session's own writes included; the returned function stops it.
    fn watch(&self, change: Change) -> Box<dyn FnOnce() + Send>;
    /// Session-private bytes (document state), kept apart from the workspace's files.
    fn read_state(&self, key: &str) -> impl Future<Output = Result<Option<Vec<u8>>>> + Send;
    fn write_state(&self, key: &str, data: &[u8]) -> impl Future<Output = Result<()>> + Send;
}

/// The name of the session's own directory inside a workspace.
pub const INTERNAL: &str = ".rayde-session";

/// A virtual path: `/`-separated, relative to the workspace, with no `.` or `..` segments.
pub fn clean(path: &str) -> Result<String> {
    if path.contains('\0') {
        return Err(SessionError::new("bad-path", "The path is not valid."));
    }
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => return Err(SessionError::new("outside", "The path leaves the workspace.")),
            part if part.contains('\\') || (cfg!(windows) && part.contains(':')) => return Err(SessionError::new("bad-path", "The path is not valid.")),
            part => parts.push(part),
        }
    }
    if parts.first() == Some(&INTERNAL) {
        return Err(SessionError::new("outside", "The path is the session's own."));
    }
    Ok(parts.join("/"))
}
