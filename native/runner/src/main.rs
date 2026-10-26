use rayde_runner::{Config, start};
use std::path::Path;

#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 || args[1] != "--config" {
        eprintln!("rayde-runner --config /private/path/config.json");
        std::process::exit(2);
    }
    let result = async {
        let config = Config::load(Path::new(&args[2])).await?;
        let running = start(config).await?;
        println!("RayDE runner listening on {}", running.address);
        let _ = tokio::signal::ctrl_c().await;
        running.shutdown().await;
        Ok::<(), rayde_runner::Failure>(())
    }
    .await;
    if let Err(error) = result {
        eprintln!("{}", error.1);
        std::process::exit(1);
    }
}
