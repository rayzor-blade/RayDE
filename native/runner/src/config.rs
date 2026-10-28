use super::*;
use serde::Deserialize;
use std::net::SocketAddr;

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalRepository {
    pub owner: u64,
    pub repository: u64,
    pub path: PathBuf,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub listen: SocketAddr,
    pub state_root: PathBuf,
    pub msb: PathBuf,
    pub session_binary: PathBuf,
    pub secret_file: PathBuf,
    #[serde(default)]
    pub public_url: Option<String>,
    #[serde(default = "image")]
    pub image: String,
    /// A verified disk-only MSB template containing the complete guest toolchain.
    #[serde(default)]
    pub toolchain: Option<Toolchain>,
    #[serde(default = "persistent")]
    pub persistent_disks: bool,
    #[serde(default = "memory")]
    pub memory_mib: u32,
    #[serde(default = "cpus")]
    pub cpus: u8,
    #[serde(default = "workspaces")]
    pub max_workspaces: usize,
    #[serde(default = "lifetime")]
    pub max_duration_seconds: u64,
    /// Fixed local Git fixtures are allowed only on this loopback development service.
    #[serde(default)]
    pub local_repositories: Vec<LocalRepository>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Toolchain {
    pub snapshot: String,
    pub digest: String,
    #[serde(default)]
    pub app_previews:bool,
}
fn image() -> String {
    "alpine:3.23".into()
}
fn persistent() -> bool { true }
fn memory() -> u32 {
    512
}
fn cpus() -> u8 {
    1
}
fn workspaces() -> usize {
    2
}
fn lifetime() -> u64 {
    3600
}
impl Config {
    pub async fn load(path: &Path) -> Result<Self> {
        let bytes = tokio::fs::read(path).await?;
        if bytes.len() > 64 * 1024 {
            return Err(invalid());
        }
        serde_json::from_slice(&bytes).map_err(|_| invalid())
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if !self.listen.ip().is_loopback()
            || !self.state_root.is_absolute()
            || !self.msb.is_absolute()
            || !self.session_binary.is_absolute()
            || !self.secret_file.is_absolute()
            || !(128..=8192).contains(&self.memory_mib)
            || !(1..=8).contains(&self.cpus)
            || !(1..=16).contains(&self.max_workspaces)
            || !(60..=86400).contains(&self.max_duration_seconds)
            || self.image.is_empty()
            || self.image.len() > 200
            || self.image.starts_with('-')
            || self.image.starts_with(['/', '.'])
            || self.image.chars().any(char::is_whitespace)
            || self.local_repositories.len() > 32
        {
            return Err(invalid());
        }
        if self.toolchain.as_ref().is_some_and(|toolchain| {
            toolchain.snapshot.is_empty()
                || toolchain.snapshot.len() > 256
                || toolchain.snapshot.starts_with(['-', '.'])
                || !toolchain.snapshot.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b':' | b'.'))
                || toolchain.digest.len() != 64
                || !toolchain.digest.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        }) {
            return Err(invalid());
        }
        if self
            .local_repositories
            .iter()
            .any(|repo| repo.owner == 0 || repo.repository == 0 || !repo.path.is_absolute())
        {
            return Err(invalid());
        }
        Ok(())
    }
}
