mod checkout;
mod command;
mod config;
mod registry;
mod service;
#[cfg(test)]
mod tests;
mod tunnel;
mod toolchain;
mod volumes;
pub use config::{Config, LocalRepository, Toolchain};
pub use service::{Running, start};

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
    branch: String,
    clone_url: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Checkout {
    access_token: String,
}
#[derive(Deserialize)]
pub(crate) struct Open {
    id: String,
    owner: u64,
    repository: Repository,
    checkout: Checkout,
}
#[derive(Deserialize)]
pub(crate) struct Delete {
    id: String,
    owner: u64,
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
