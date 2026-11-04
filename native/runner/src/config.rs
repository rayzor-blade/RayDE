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
    /// Where Cloud Sync snapshots are restored from. Without it a synced workspace cannot be opened.
    #[serde(default)]
    pub sync_gateway: Option<SyncGateway>,
    /// An operator-owned public source bundle, addressed by its complete SHA-256.
    #[serde(default)]
    pub demo: Option<DemoSource>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DemoSource {
    pub bundle: PathBuf,
    pub release: String,
    pub max_workspaces: usize,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncGateway {
    pub url: String,
    pub secret: String,
    /// The same gateway as reached from the guest, when the runner uses a loopback development endpoint.
    #[serde(default)]
    pub guest_url: Option<String>,
}

impl SyncGateway {
    fn address(value: &str) -> Option<reqwest::Url> {
        let url = reqwest::Url::parse(value).ok()?;
        let host = url.host_str()?.trim_matches(['[', ']']);
        let loopback = host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback());
        (value.len() <= 512 && !value.chars().any(char::is_whitespace)
            && host.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b':'))
            && url.username().is_empty() && url.password().is_none()
            && url.query().is_none() && url.fragment().is_none()
            && (url.scheme() == "https" || url.scheme() == "http" && loopback))
            .then_some(url)
    }

    pub(crate) fn guest_address(&self) -> Result<reqwest::Url> {
        let url = Self::address(self.guest_url.as_deref().unwrap_or(&self.url)).ok_or_else(invalid)?;
        let host = url.host_str().ok_or_else(invalid)?.trim_matches(['[', ']']);
        if host.trim_end_matches('.') == "localhost" || host.trim_end_matches('.').ends_with(".localhost")
            || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback() || ip.is_unspecified()) {
            return Err(Failure(axum::http::StatusCode::BAD_REQUEST, "Cloud Sync needs a gateway URL reachable from the sandbox. Set syncGateway.guestUrl to its HTTPS address."));
        }
        Ok(url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(url: &str, guest: Option<&str>) -> Config {
        serde_json::from_value(serde_json::json!({
            "listen":"127.0.0.1:0", "stateRoot":"/tmp/state", "msb":"/bin/msb", "sessionBinary":"/bin/session", "secretFile":"/tmp/secret",
            "syncGateway":{"url":url, "guestUrl":guest, "secret":"gateway-test-secret"}
        })).unwrap()
    }

    #[test]
    fn only_sync_guests_get_the_exact_configured_gateway_host() {
        for url in ["https://sync.example.test", "https://sync.example.test:9443/api", "https://[2001:db8::1]:9443"] {
            let config = config(url, None);
            config.validate().unwrap();
            assert_eq!(config.workspace_network(false).unwrap(), rayde_sandbox::Network::None);
            let host = if url.contains("2001:db8") { "2001:db8::1" } else { "sync.example.test" };
            assert_eq!(config.workspace_network(true).unwrap(), rayde_sandbox::Network::Allow(vec![host.into()]));
        }
        let config = config("http://127.0.0.1:9792", Some("https://gateway.example.test/sync"));
        config.validate().unwrap();
        assert_eq!(config.workspace_network(true).unwrap(), rayde_sandbox::Network::Allow(vec!["gateway.example.test".into()]));
        assert_eq!(config.sync_gateway.unwrap().guest_address().unwrap().as_str(), "https://gateway.example.test/sync");
    }

    #[test]
    fn invalid_gateway_addresses_cannot_change_the_egress_policy() {
        for url in ["file:///tmp/gateway", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://sync.example.test",
            "https://owner:token@sync.example.test", "https://sync.example.test/?token=secret", "https://sync.example.test/#token",
            "https://sync.example.test\n", "https://*.example.test"] {
            let config = config(url, None);
            assert!(config.validate().is_err(), "{url}");
        }
        for url in ["http://127.0.0.1:9792", "https://localhost:9792", "https://[::1]:9792", "https://0.0.0.0:9792"] {
            let config = config(url, None);
            assert!(config.workspace_network(true).is_err(), "{url} points inside the guest");
            assert_eq!(config.workspace_network(false).unwrap(), rayde_sandbox::Network::None);
        }
        assert!(config("http://127.0.0.1:9792", Some("http://127.0.0.1:9793")).validate().is_err());
    }

    #[test]
    fn secure_ingress_changes_only_the_advertised_session_address() {
        let mut value = config("https://gateway.example.test",None);
        value.public_url = Some("wss://runner.example.test/".into());
        value.validate().unwrap();
        assert_eq!(value.session_base("127.0.0.1:9791".parse().unwrap()).unwrap(),"wss://runner.example.test");
        assert!(value.listen.ip().is_loopback());
        value.listen = "0.0.0.0:9791".parse().unwrap();
        assert!(value.validate().is_err());
    }

    #[test]
    fn advertised_ingress_refuses_plaintext_remote_urls_credentials_and_fixture_bypasses() {
        for url in ["ws://runner.example.test", "https://runner.example.test", "wss://user:secret@runner.example.test",
            "wss://runner.example.test/session", "wss://runner.example.test/?token=secret", "wss://runner.example.test/#fragment", "wss://runner.example.test\n"] {
            let mut value = config("https://gateway.example.test",None);value.public_url=Some(url.into());
            assert!(value.validate().is_err(),"{url}");
        }
        let mut value = config("https://gateway.example.test",None);
        value.public_url=Some("wss://runner.example.test".into());
        value.local_repositories.push(LocalRepository{owner:1,repository:111,path:"/fixture".into()});
        assert!(value.validate().is_err());
        value.public_url=Some("ws://127.0.0.1:9791".into());
        value.validate().unwrap();
    }
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
    /// The advertised transport may use TLS ingress while the service stays on loopback.
    pub(crate) fn session_base(&self, address: SocketAddr) -> Result<String> {
        let base = self.public_url.clone().unwrap_or_else(||format!("ws://{address}"));
        let endpoint = reqwest::Url::parse(&base).map_err(|_|invalid())?;
        let loopback = endpoint.host_str().is_some_and(|host|
            host == "localhost" || host.trim_matches(['[',']']).parse::<std::net::IpAddr>().is_ok_and(|ip|ip.is_loopback()));
        if base.len() > 512 || base.chars().any(char::is_whitespace)
            || !(endpoint.scheme() == "wss" || endpoint.scheme() == "ws" && loopback)
            || endpoint.host_str().is_none() || endpoint.path() != "/"
            || endpoint.query().is_some() || endpoint.fragment().is_some()
            || !endpoint.username().is_empty() || endpoint.password().is_some()
            || endpoint.scheme() == "wss" && !self.local_repositories.is_empty()
        { return Err(invalid()); }
        Ok(endpoint.as_str().trim_end_matches('/').to_owned())
    }

    pub async fn load(path: &Path) -> Result<Self> {
        let bytes = tokio::fs::read(path).await?;
        if bytes.len() > 64 * 1024 {
            return Err(invalid());
        }
        serde_json::from_slice(&bytes).map_err(|_| invalid())
    }
    pub(crate) fn validate(&self) -> Result<()> {
        self.session_base(self.listen)?;
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
        if self.demo.as_ref().is_some_and(|demo| !demo.bundle.is_absolute() || demo.release.len()!=64
            || !demo.release.bytes().all(|byte|byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || demo.max_workspaces==0 || demo.max_workspaces>self.max_workspaces) { return Err(invalid()); }
        if self.sync_gateway.as_ref().is_some_and(|gateway| {
            SyncGateway::address(&gateway.url).is_none()
                || gateway.guest_url.as_ref().is_some_and(|_| gateway.guest_address().is_err())
                || gateway.secret.len() < 16
                || gateway.secret.len() > 4096
                || gateway.secret.contains(['\r', '\n', '\0', ' '])
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

    /// Only synced workspaces need egress, and only to the gateway the operator configured.
    pub(crate) fn workspace_network(&self, synced: bool) -> Result<rayde_sandbox::Network> {
        if !synced { return Ok(rayde_sandbox::Network::None); }
        let address = self.sync_gateway.as_ref().ok_or_else(unavailable)?.guest_address()?;
        let host = address.host_str().ok_or_else(invalid)?.trim_matches(['[', ']']).to_string();
        Ok(rayde_sandbox::Network::Allow(vec![host]))
    }
}
