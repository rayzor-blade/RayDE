//! The interface a sandbox backend implements for RayDE's runner, and for any other client that needs sandboxes: nan8's executors, a dynASB
//! workspace backend. It is the common denominator of what `rayde-runner` asks of MSB today (create, volumes, exec with a stream, snapshot
//! and restore, label queries, bounded teardown) plus the options a GPU session class needs. A backend states what it supports in
//! `capabilities`; anything else answers `Error::Unsupported`.

use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, future::Future, path::PathBuf, time::Duration};
use tokio::io::{AsyncRead, AsyncWrite};

pub mod conformance;
pub mod fake;

pub type Labels = BTreeMap<String, String>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// No such sandbox, volume or snapshot.
    NotFound,
    /// State exists that this call cannot reconcile: a volume bound to another identity, a name in use with a different spec.
    Conflict(String),
    /// The backend asked for a feature it does not have; see `Capabilities`.
    Unsupported(&'static str),
    /// The request itself is malformed or over a limit.
    Invalid(String),
    /// The backend or the sandbox is not reachable or not ready; the call may be retried.
    Unavailable,
    Timeout,
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    pub persistent_volumes: bool,
    pub snapshots: bool,
    /// Copy-on-write fork of a running sandbox.
    pub fork: bool,
    pub gpu: bool,
    /// Per-sandbox egress allowlist, not only on or off.
    pub network_allowlist: bool,
    pub warm_pool: bool,
    /// Most sandboxes the backend runs at once; 0 when it does not say.
    pub max_sandboxes: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Template {
    /// An OCI image reference.
    Image(String),
    /// A snapshot taken earlier, restored into a new sandbox.
    Snapshot(SnapshotRef),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotRef(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Security {
    Restricted,
    Standard,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Network {
    None,
    /// Reach only these hosts.
    Allow(Vec<String>),
    Open,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GpuApi {
    Vulkan,
    OpenGl,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Gpu {
    pub memory_mib: u32,
    pub api: GpuApi,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Source {
    Volume(String),
    /// A host directory.
    Host(PathBuf),
    /// A host disk image file, mounted as a block device (the runner binds its workspace and state disks this way).
    Disk(PathBuf),
    /// Private to the sandbox, removed with it.
    Owned,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mount {
    pub source: Source,
    pub destination: String,
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VolumeSpec {
    pub name: String,
    pub size_mib: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VolumeInfo {
    pub name: String,
    pub size_mib: u32,
    /// Where the backend keeps the disk on the host, when it is a file the control plane may bind or inspect.
    pub path: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxSpec {
    pub name: String,
    pub template: Template,
    pub cpus: u32,
    pub memory_mib: u32,
    pub security: Security,
    pub network: Network,
    pub gpu: Option<Gpu>,
    pub labels: Labels,
    pub mounts: Vec<Mount>,
    /// The backend stops the sandbox after this long however it is used.
    pub max_duration: Option<Duration>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum State {
    Running,
    Stopped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxInfo {
    pub name: String,
    pub state: State,
    pub labels: Labels,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub program: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
}

/// A command's output, captured within a limit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// A running command with its pipes. Dropping it kills the command.
pub struct Process {
    pub stdin: Box<dyn AsyncWrite + Send + Unpin>,
    pub stdout: Box<dyn AsyncRead + Send + Unpin>,
    pub exit: tokio::sync::oneshot::Receiver<i32>,
}

pub trait SandboxProvider: Send + Sync {
    fn capabilities(&self) -> Capabilities;

    /// Idempotent for the same spec; `Conflict` when the name exists with a different one.
    fn create_volume(&self, spec: VolumeSpec) -> impl Future<Output = Result<VolumeInfo>> + Send;
    fn volume(&self, name: &str) -> impl Future<Output = Result<Option<VolumeInfo>>> + Send;
    /// Idempotent. `Conflict` while a sandbox still mounts it.
    fn remove_volume(&self, name: &str) -> impl Future<Output = Result<()>> + Send;

    /// Idempotent by name for an identical spec.
    fn create(&self, spec: SandboxSpec) -> impl Future<Output = Result<SandboxInfo>> + Send;
    fn get(&self, name: &str) -> impl Future<Output = Result<Option<SandboxInfo>>> + Send;
    /// Sandboxes whose labels include every given pair.
    fn list(&self, selector: &Labels) -> impl Future<Output = Result<Vec<SandboxInfo>>> + Send;
    /// Succeeds only when the sandbox's agent answers.
    fn ping(&self, name: &str) -> impl Future<Output = Result<()>> + Send;
    fn stop(&self, name: &str) -> impl Future<Output = Result<()>> + Send;
    /// Idempotent. Takes the sandbox's owned mounts with it and leaves named volumes.
    fn remove(&self, name: &str) -> impl Future<Output = Result<()>> + Send;

    /// A command with piped stdio, for a long conversation such as the session bridge.
    fn spawn(&self, name: &str, command: Command) -> impl Future<Output = Result<Process>> + Send;
    /// A command run to completion; `Invalid` when its output passes `limit` bytes, `Timeout` when it passes `within`.
    fn run(&self, name: &str, command: Command, limit: usize, within: Duration) -> impl Future<Output = Result<Output>> + Send;
    /// Starts a command that keeps running after the call returns, with no stdio (the runner starts the session this way). Returns once it has started.
    fn detach(&self, name: &str, command: Command) -> impl Future<Output = Result<()>> + Send;
    fn copy_in(&self, name: &str, host: PathBuf, guest: &str) -> impl Future<Output = Result<()>> + Send;

    /// `Unsupported` unless `capabilities().snapshots`.
    fn snapshot(&self, name: &str) -> impl Future<Output = Result<SnapshotRef>> + Send;
    fn verify_snapshot(&self, snapshot: &SnapshotRef) -> impl Future<Output = Result<()>> + Send;
}
