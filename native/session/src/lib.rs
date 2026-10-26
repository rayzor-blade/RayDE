//! RayDE's workspace session. The core is platform-neutral: a store, documents and a protocol. `server` adds a directory store, programs and a socket.
pub mod auth;
pub mod docs;
pub mod error;
pub mod session;
pub mod store;
pub mod syntax;

#[cfg(feature = "server")]
pub mod dir_store;
#[cfg(feature = "server")]
pub mod processes;
#[cfg(feature = "server")]
pub mod server;
