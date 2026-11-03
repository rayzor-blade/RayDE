//! RayDE's workspace session. The core is platform-neutral: a store, documents and a protocol. `server` adds a directory store, programs and a socket.
pub mod auth;
pub mod checkpoint;
pub mod cloud;
pub mod framing;
mod buffer_state;
pub mod docs;
#[cfg(feature = "server")]
pub mod editor;
#[cfg(feature = "server")]
pub mod desktop;
pub mod error;
pub mod session;
pub mod store;
pub mod syntax;
pub mod terminal;

#[cfg(feature = "server")]
pub mod dir_store;
#[cfg(feature = "server")]
mod document_ids;
#[cfg(feature = "server")]
mod read_roots;
#[cfg(feature = "server")]
mod previews;
#[cfg(feature = "server")]
mod writeback;
#[cfg(feature = "server")]
mod cloud_gateway;
#[cfg(feature = "server")]
mod cloud_watch;
#[cfg(feature = "server")]
mod sync_state;
#[cfg(feature = "server")]
mod preview_cache;
#[cfg(feature = "server")]
mod cache_identity;
#[cfg(feature = "server")]
pub mod environment;
#[cfg(feature = "server")]
pub mod processes;
#[cfg(feature = "server")]
pub mod server;
