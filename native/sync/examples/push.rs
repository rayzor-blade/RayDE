//! A development driver for the upload: `cargo run --example push -- ROOT GATEWAY [DEV_ACCOUNT [ACTION [WORKSPACE TOKEN BASE_GENERATION]]]` prints each event as a
//! JSON line. A DEV_ACCOUNT of `-` means none; ACTION is push, open or writeback, and writeback saves ROOT into WORKSPACE as the holder of TOKEN.
use rayde_sync::client::{Config, run};

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(root), Some(gateway)) = (args.next(), args.next()) else {
        eprintln!("usage: push ROOT GATEWAY [DEV_ACCOUNT [push|open|writeback [WORKSPACE TOKEN BASE_GENERATION]]]");
        std::process::exit(2);
    };
    let account = args.next().filter(|account| account != "-");
    let action = args.next().unwrap_or_default();
    let config = Config {
        root: root.into(),
        gateway,
        account,
        device: None,
        history: false,
        action,
        workspace: args.next(),
        token: args.next(),
        base_generation: args.next().and_then(|base| base.parse().ok()),
        force: std::env::var("RAYDE_SYNC_FORCE").is_ok_and(|value| value == "1"),
    };
    if let Err(failure) = run(&config, &mut |event| println!("{event}"), &|| false) {
        println!("{}", serde_json::json!({"event": "error", "code": failure.code, "message": failure.message}));
        std::process::exit(1);
    }
}
