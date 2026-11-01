mod checkout;
mod command;
mod config;
mod msb;
mod registry;
mod restore;
mod service;
#[cfg(test)]
mod tests;
mod tunnel;
mod toolchain;
mod volumes;
pub use config::{Config, LocalRepository, SyncGateway, Toolchain};
pub use msb::Msb;
pub use service::{Backend, Running, start, start_with};

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

type Result<T> = std::result::Result<T, Failure>;
#[derive(Debug)]
pub struct Failure(pub StatusCode, pub &'static str);
impl IntoResponse for Failure {
    fn into_response(self) -> Response {
        (self.0, Json(serde_json::json!({"message":self.1}))).into_response()
    }
}
impl From<std::io::Error> for Failure {
    fn from(_: std::io::Error) -> Self {
        unavailable()
    }
}
impl From<rayde_sandbox::Error> for Failure {
    fn from(error: rayde_sandbox::Error) -> Self {
        use rayde_sandbox::Error;
        match error {
            Error::Conflict(_) => Failure(StatusCode::CONFLICT, "Workspace compute state needs reconciliation."),
            Error::Invalid(_) => invalid(),
            Error::NotFound | Error::Unsupported(_) | Error::Unavailable | Error::Timeout => unavailable(),
        }
    }
}
fn unavailable() -> Failure {
    Failure(
        StatusCode::SERVICE_UNAVAILABLE,
        "Workspace compute is unavailable.",
    )
}
fn invalid() -> Failure {
    Failure(StatusCode::BAD_REQUEST, "The workspace request is invalid.")
}
fn random() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn workspace_id(owner: u64, repository: u64) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(format!("github:{owner}:{repository}")))
}
fn valid_id(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}
fn matches_secret(a: &str, b: &str) -> bool {
    use subtle::ConstantTimeEq;
    bool::from(a.as_bytes().ct_eq(b.as_bytes()))
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Repository {
    id: u64,
    full_name: String,
    #[serde(default)]
    branch: String,
    #[serde(default)]
    clone_url: String,
    /// A Cloud Sync snapshot stands in for the Git repository: the workspace is restored from the gateway, not cloned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sync: Option<SyncRef>,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct SyncRef {
    workspace: String,
}
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Checkout {
    #[serde(default)]
    access_token: Option<String>,
}
impl Checkout {
    fn token(&self) -> &str {
        self.access_token.as_deref().unwrap_or("")
    }
}
#[derive(Deserialize)]
pub(crate) struct Open {
    id: String,
    owner: u64,
    repository: Repository,
    #[serde(default)]
    checkout: Checkout,
}
#[derive(Deserialize)]
pub(crate) struct Delete {
    id: String,
    owner: u64,
}

/// A synced workspace is named by its own id and has no Git repository behind it.
fn valid_sync(repo: &Repository, id: &str) -> bool {
    repo.sync.as_ref().is_some_and(|sync| sync.workspace == id)
        && valid_id(id)
        && repo.id == 0
        && repo.full_name == format!("sync/{id}")
}
/// Whether a workspace id and repository belong together: a GitHub one by the hash of owner and repository, a synced one by its own id.
fn binds(owner: u64, id: &str, repo: &Repository) -> bool {
    if repo.sync.is_some() {
        valid_sync(repo, id)
    } else {
        id == workspace_id(owner, repo.id) && valid_repository(repo)
    }
}
fn valid_repository(repo: &Repository) -> bool {
    let parts: Vec<_> = repo.full_name.split('/').collect();
    repo.id > 0
        && parts.len() == 2
        && parts.iter().all(|part| {
            !part.is_empty()
                && part.len() <= 100
                && *part != "."
                && *part != ".."
                && part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
        })
        && repo.clone_url == format!("https://github.com/{}.git", repo.full_name)
        && !repo.branch.is_empty()
        && repo.branch.len() <= 256
        && !repo.branch.starts_with('-')
        && !repo.branch.contains(['\0', '\n', '\r'])
}
async fn private_dir(path: &Path) -> Result<()> {
    tokio::fs::create_dir_all(path).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).await?;
    }
    Ok(())
}
async fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    use tokio::io::AsyncWriteExt;
    let temporary = path.with_extension(format!("{}.tmp", random()));
    let mut options = tokio::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        options.mode(0o600);
    }
    let mut file = options.open(&temporary).await?;
    if let Err(error) = async {
        file.write_all(bytes).await?;
        file.sync_all().await?;
        tokio::fs::rename(&temporary, path).await?;
        #[cfg(unix)]
        {
            tokio::fs::File::open(
                path.parent()
                    .ok_or_else(|| std::io::Error::other("missing parent"))?,
            )
            .await?
            .sync_all()
            .await?;
        }
        Ok::<(), std::io::Error>(())
    }
    .await
    {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(error.into());
    }
    Ok(())
}
