use rayde_session::{
    auth::{Identity, SignedCredentials},
    server::{Options, start},
};
use std::{net::SocketAddr, path::PathBuf, sync::Arc};

fn token_file(path: &std::path::Path) -> std::io::Result<String> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() > 4096 {
        return Err(std::io::Error::other("The token file must be a private regular file."));
    }
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(std::io::Error::other("The token file must have mode 0600."));
        }
    }
    let token = std::fs::read_to_string(path)?.trim().to_owned();
    if !(32..=512).contains(&token.len()) || token.chars().any(char::is_whitespace) || token.contains('\0') {
        return Err(std::io::Error::other("The token file must contain one token of 32 to 512 characters."));
    }
    Ok(token)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let option = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    if args.first().map(String::as_str) == Some("bridge") {
        let port = option("--port").and_then(|value|value.parse::<u16>().ok()).expect("bridge needs --port N");
        let address = ([127,0,0,1],port).into();
        let result = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap()
            .block_on(rayde_session::server::bridge(address));
        if result.is_err() {eprintln!("Session bridge disconnected.");std::process::exit(1);}
        return;
    }
    if args.iter().any(|a| a == "--help") {
        println!("rayde-session bridge --port N: relay stdin/stdout to a private framed loopback session; EOF closes the connection.");
        println!("rayde-session [--root DIR] [--port N] [--host ADDR] [--token T] [--origin URL]... [--web DIR] [--exec]\n              [--raw-port N] [--extension-host BIN --extensions DIR] [--auth-secret S --login-url URL]\nrayde-session issue --auth-secret S --login NAME --id N [--ttl SECONDS]\n\nServes DIR (default: the current directory) to RayDE over a WebSocket at /session.\nPrograms run only with --exec. --extension-host enables a supervised RayScript host per extension; --extensions locates the built-in installation. Without --token a random one is made and printed.\nWith --auth-secret, changes need a credential the sign-in edge signed with that secret; `issue` mints one for development.");
        println!("Environment defaults load from ~/.rayde-session/environment.json; --env-file PATH selects another JSON string map.\n--read-root DIR exposes an installed source directory read-only; may be repeated.\nState is stored under ~/.rayde-session, separated by workspace. --state-root DIR selects another private state directory.");
        println!("--token-file PATH reads a persistent token from a private file instead of putting it in process arguments.\n--preview-project FILE enables same-origin bootstrap for a trusted loopback preview with --web and an explicit token; never use it for a public deployment.");
        return;
    }
    if args.first().map(String::as_str) == Some("issue") {
        let secret = option("--auth-secret").expect("--auth-secret is needed");
        let identity = Identity { login: option("--login").expect("--login is needed"), id: option("--id").and_then(|i| i.parse().ok()).expect("--id is a number") };
        let ttl: u64 = option("--ttl").and_then(|t| t.parse().ok()).unwrap_or(3600);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        println!("{}", SignedCredentials::new(secret.into_bytes(), "").issue(&identity, now + ttl));
        return;
    }
    let root = PathBuf::from(option("--root").unwrap_or_else(|| ".".into()));
    let host = option("--host").unwrap_or_else(|| "127.0.0.1".into());
    let port: u16 = option("--port").and_then(|p| p.parse().ok()).unwrap_or(7070);
    let address: SocketAddr = format!("{host}:{port}").parse().expect("--host and --port make an address");
    let token = option("--token").or_else(|| option("--token-file").map(|path| token_file(std::path::Path::new(&path)).expect("valid private token file"))).unwrap_or_else(|| {
        use rand::Rng;
        rand::thread_rng().sample_iter(rand::distributions::Alphanumeric).take(24).map(char::from).collect()
    });
    let mut options = Options::new(&root);
    let environment_file=option("--env-file").map(PathBuf::from);
    let default_environment=std::env::var_os(if cfg!(windows){"USERPROFILE"}else{"HOME"}).map(PathBuf::from).map(|home|home.join(".rayde-session/environment.json"));
    if let Some(path)=environment_file.as_ref().or(default_environment.as_ref()) {
        options.environment=rayde_session::environment::load(path,environment_file.is_some()).expect("valid session environment configuration");
    }
    options.state_root = option("--state-root").map(PathBuf::from);
    options.address = address;
    options.token = Some(token.clone());
    options.exec = args.iter().any(|a| a == "--exec");
    options.extension_host = option("--extension-host").map(PathBuf::from);
    options.extensions = option("--extensions").map(PathBuf::from);
    options.read_roots = args.iter().enumerate().filter(|(_,a)| *a == "--read-root").filter_map(|(i,_)| args.get(i+1).map(PathBuf::from)).collect();
    options.web = option("--web").map(PathBuf::from);
    options.preview_project = option("--preview-project");
    options.raw = option("--raw-port").and_then(|p| p.parse::<u16>().ok()).map(|p| SocketAddr::new(address.ip(), p));
    if let Some(secret) = option("--auth-secret") {
        options.authority = Some(Arc::new(SignedCredentials::new(secret.into_bytes(), option("--login-url").unwrap_or_default())));
    }
    options.origins = args.iter().enumerate().filter(|(_, a)| *a == "--origin").filter_map(|(i, _)| args.get(i + 1).cloned()).collect();
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(async move {
        let running = start(options).await.expect("the session starts");
        println!("session for {}\n  {}/\n  token {token}", root.display(), running.url());
        let _ = tokio::signal::ctrl_c().await;
        running.shutdown().await;
    });
}

#[cfg(test)]
mod token_tests {
    #[test]
    fn persistent_token_files_are_private_and_validated() {
        use super::token_file;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("token");
        std::fs::write(&path, "a".repeat(40)).unwrap();
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            assert_eq!(token_file(&path).unwrap(), "a".repeat(40));
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(token_file(&path).is_err());
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            let link = directory.path().join("link");
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(token_file(&link).is_err());
        }
        std::fs::write(&path, "short").unwrap();
        assert!(token_file(&path).is_err());
    }
}
