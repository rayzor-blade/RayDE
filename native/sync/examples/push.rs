//! A development driver for the upload: `cargo run --example push -- ROOT GATEWAY [DEV_ACCOUNT]` prints each event as a JSON line.
use rayde_sync::client::{Config, run};

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(root), Some(gateway)) = (args.next(), args.next()) else {
        eprintln!("usage: push ROOT GATEWAY [DEV_ACCOUNT]");
        std::process::exit(2);
    };
    let config = Config { root: root.into(), gateway, account: args.next(), device: None, history: false };
    if let Err(failure) = run(&config, &mut |event| println!("{event}"), &|| false) {
        println!("{}", serde_json::json!({"event": "error", "code": failure.code, "message": failure.message}));
        std::process::exit(1);
    }
}
