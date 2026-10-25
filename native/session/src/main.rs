use rayde_session::server::{Options, start};
use std::{net::SocketAddr, path::PathBuf};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let option = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    if args.iter().any(|a| a == "--help") {
        println!("rayde-session [--root DIR] [--port N] [--host ADDR] [--token T] [--origin URL]... [--web DIR] [--exec]\n\nServes DIR (default: the current directory) to RayDE over a WebSocket at /session.\nPrograms run only with --exec. Without --token a random one is made and printed.");
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
    options.origins = args.iter().enumerate().filter(|(_, a)| *a == "--origin").filter_map(|(i, _)| args.get(i + 1).cloned()).collect();
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(async move {
        let running = start(options).await.expect("the session starts");
        println!("session for {}\n  {}/\n  token {token}", root.display(), running.url());
        let _ = tokio::signal::ctrl_c().await;
        running.shutdown().await;
    });
}
