mod support;
use rayde_session::{
    framing::frame,
    server::{Options, start},
};
use serde_json::json;
use std::{fs, process::Stdio, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn command_bridge_is_byte_faithful_and_eof_releases_the_connection() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("file.txt"), "hello 🦊").unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.raw = Some(([127, 0, 0, 1], 0).into());
    options.token = Some("secret".into());
    let server = start(options).await.unwrap();
    let port = server.raw_address.unwrap().port();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_rayde-session"))
        .args(["bridge", "--port", &port.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = child.stdout.take().unwrap();
    for (id, request) in [
        (1, json!({"id":1,"op":"hello","token":"secret"})),
        (2, json!({"id":2,"op":"doc.open","path":"file.txt"})),
    ] {
        let bytes = frame(&request.to_string());
        input.write_all(&bytes[..2]).await.unwrap();
        tokio::task::yield_now().await;
        input.write_all(&bytes[2..]).await.unwrap();
        let length = tokio::time::timeout(Duration::from_secs(5), output.read_u32())
            .await
            .unwrap()
            .unwrap();
        assert!(length < 10000);
        let mut bytes = vec![0; length as usize];
        output.read_exact(&mut bytes).await.unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(reply["id"], id);
        assert_eq!(reply["ok"], true);
        if id == 2 {
            assert_eq!(reply["text"], "hello 🦊");
        }
    }
    drop(input);
    assert!(
        tokio::time::timeout(Duration::from_secs(3), child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
    assert!(
        server
            .workspace
            .docs
            .idle()
            .contains(&"file.txt".to_string())
            || server.workspace.docs.text("file.txt").is_none()
    );
    server.shutdown().await;
}
