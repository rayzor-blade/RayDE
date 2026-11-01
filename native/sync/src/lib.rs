//! Cloud Sync's shared core.
//!
//! The pure modules (`ids`, `policy`, `lifecycle`, `manifest`, `exclude`, `chunk`, `gateway`) are data and rules with no I/O, so the gateway can
//! validate exactly what the desktop produced. `scan` (feature `scan`) is the desktop engine that reads a Git working tree.
pub mod chunk;
pub mod exclude;
pub mod gateway;
pub mod ids;
pub mod lifecycle;
pub mod manifest;
pub mod policy;

#[cfg(feature = "client")]
pub mod client;
#[cfg(feature = "merge")]
pub mod merge;
#[cfg(feature = "scan")]
pub mod scan;

/// The version of the manifest and policy formats in this crate. A reader refuses a manifest from a newer one.
pub const FORMAT: u32 = 1;
