use rayde_session::{
    auth::{Identity, SignedCredentials},
    server::{Options, start},
};
use std::{net::SocketAddr, path::PathBuf, sync::Arc};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let option = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    if args.iter().any(|a| a == "--help") {
        println!("rayde-session [--root DIR] [--port N] [--host ADDR] [--token T] [--origin URL]... [--web DIR] [--exec]\n              [--auth-secret S --login-url URL]\nrayde-session issue --auth-secret S --login NAME --id N [--ttl SECONDS]\n\nServes DIR (default: the current directory) to RayDE over a WebSocket at /session.\nPrograms run only with --exec. Without --token a random one is made and printed.\nWith --auth-secret, changes need a credential the sign-in edge signed with that secret; `issue` mints one for development.");
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
    let token = option("--token").unwrap_or_else(|| {
        use rand::Rng;
        rand::thread_rng().sample_iter(rand::distributions::Alphanumeric).take(24).map(char::from).collect()
    });
    let mut options = Options::new(&root);
    options.address = address;
    options.token = Some(token.clone());
    options.exec = args.iter().any(|a| a == "--exec");
    options.web = option("--web").map(PathBuf::from);
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
