use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Storage {
    workspace: String,
    state: String,
    identity: String,
}
pub(crate) struct Mounts {
    pub workspace: PathBuf,
    pub state: PathBuf,
}
impl Storage {
    pub fn new(instance: &str, id: &str) -> Self {
        let prefix = format!("rayde-{}-{id}", &instance[..16]);
        Self { workspace: format!("{prefix}-work"), state: format!("{prefix}-state"), identity: random() }
    }
    pub fn valid(&self, instance: &str, id: &str) -> bool {
        let prefix = format!("rayde-{}-{id}", &instance[..16]);
        self.workspace == format!("{prefix}-work") && self.state == format!("{prefix}-state")
            && self.identity.len() == 64 && self.identity.bytes().all(|byte| byte.is_ascii_hexdigit())
    }
    pub fn create_args(&self) -> Vec<String> {
        vec!["--mount-named".into(), format!("{}:/workspace:kind=disk,size=1G", self.workspace),
             "--mount-named".into(), format!("{}:/state:kind=disk,size=512M", self.state)]
    }
    async fn path(config: &Config, name: &str) -> Result<PathBuf> {
        let bytes = command::call(config, ["volume", "inspect", name], 5).await?;
        let value = String::from_utf8_lossy(&bytes);
        let field = |key: &str| value.lines().find_map(|line| line.strip_prefix(key).map(str::trim));
        if field("Name:") != Some(name) || field("Kind:") != Some("disk") || field("Filesystem:") != Some("ext4") {
            return Err(unavailable());
        }
        let path = PathBuf::from(field("Path:").ok_or_else(unavailable)?);
        if !path.is_absolute() || path.file_name().and_then(|value| value.to_str()) != Some("disk.raw")
            || path.parent().and_then(|parent| parent.file_name()).and_then(|value|value.to_str()) != Some(name)
            || !tokio::fs::symlink_metadata(&path).await?.file_type().is_file() {
            return Err(Failure(StatusCode::CONFLICT, "The workspace disk binding needs reconciliation."));
        }
        Ok(path)
    }
    pub async fn prepare(&self, config: &Config) -> Result<Mounts> {
        for (name, size) in [(&self.workspace, "1G"), (&self.state, "512M")] {
            if Self::path(config, name).await.is_err() {
                command::call(config, ["volume", "create", name, "--kind", "disk", "--size", size], 15).await?;
            }
        }
        self.mounts(config).await
    }
    pub async fn mounts(&self, config: &Config) -> Result<Mounts> {
        Ok(Mounts { workspace: Self::path(config, &self.workspace).await?, state: Self::path(config, &self.state).await? })
    }
    pub async fn bind(&self, config: &Config, sandbox: &str, initialize: bool) -> Result<()> {
        command::call(config, ["exec", sandbox, "--quiet", "--no-stdin", "--", "/bin/sh", "-ec",
            "for dir in /workspace /state; do if test -f \"$dir/.rayde-volume\"; then test \"$(cat \"$dir/.rayde-volume\")\" = \"$1\"; else test \"$2\" = initialize; printf '%s\\n' \"$1\" > \"$dir/.rayde-volume\"; fi; done; sync",
            "--", &self.identity, if initialize {"initialize"} else {"verify"}], 10).await?;
        Ok(())
    }
    pub async fn remove(&self, config: &Config) -> Result<()> {
        for name in [&self.workspace, &self.state] {
            let bytes = command::call(config, ["volume", "list"], 5).await?;
            let exists = String::from_utf8_lossy(&bytes).lines().any(|line|line.split_whitespace().next() == Some(name));
            if exists {
                Self::path(config, name).await?;
                command::call(config, ["volume", "remove", name], 15).await?;
                let remaining = command::call(config, ["volume", "list"], 5).await?;
                if String::from_utf8_lossy(&remaining).lines().any(|line| line.split_whitespace().next() == Some(name)) {
                    return Err(Failure(StatusCode::CONFLICT, "Workspace disk removal needs reconciliation."));
                }
            }
        }
        Ok(())
    }
}
