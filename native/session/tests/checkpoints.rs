mod support;
use rayde_session::{
    auth::{Identity, SignedCredentials},
    checkpoint::{self, Checkpoint},
    server::{Options, start},
};
use serde_json::json;
use std::{
    fs,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use support::{Client, Peer};

#[tokio::test]
async fn saved_checkpoint_restores_into_fresh_compute_and_keeps_its_crdt_graph() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.hx"), "hello 🦊\n").unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    assert_eq!(
        client.request(json!({"op":"hello"})).await["checkpoints"],
        1
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.save","path":"main.hx","checkpoint":true}))
            .await["code"],
        "not-open"
    );
    let peer = Peer::new();
    peer.apply(
        client
            .request(json!({"op":"doc.open","path":"main.hx"}))
            .await["update"]
            .as_str()
            .unwrap(),
    );
    let update = peer.edit(0, 0, "saved ");
    client
        .request(json!({"op":"doc.update","path":"main.hx","update":update}))
        .await;
    let saved = client
        .request(json!({"op":"doc.save","path":"main.hx","checkpoint":true}))
        .await;
    let saved: Checkpoint = serde_json::from_value(saved["checkpoint"].clone()).unwrap();
    assert_eq!(
        checkpoint::text(&checkpoint::unpack(&saved).unwrap()).unwrap(),
        fs::read_to_string(root.path().join("main.hx")).unwrap()
    );
    client.close().await;
    running.shutdown().await;
    drop(root);
    drop(state);
    let replacement = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut options = Options::new(replacement.path());
    options.state_root = Some(state.path().into());
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    client.request(json!({"op":"hello"})).await;
    assert_eq!(
        client
            .request(json!({"op":"doc.restore","path":"main.hx","checkpoint":saved}))
            .await["ok"],
        true
    );
    let opened = client
        .request(json!({"op":"doc.open","path":"main.hx"}))
        .await;
    peer.apply(opened["update"].as_str().unwrap());
    assert_eq!(peer.string(), "saved hello 🦊\n");
    assert_eq!(
        client
            .request(json!({"op":"doc.restore","path":"main.hx","checkpoint":saved}))
            .await["code"],
        "document-open"
    );
    let update = peer.edit(0, 0, "continued ");
    assert_eq!(
        client
            .request(json!({"op":"doc.update","path":"main.hx","update":update}))
            .await["ok"],
        true
    );
    client
        .request(json!({"op":"doc.save","path":"main.hx"}))
        .await;
    assert_eq!(
        fs::read_to_string(replacement.path().join("main.hx")).unwrap(),
        "continued saved hello 🦊\n"
    );
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn restore_checks_authorization_paths_and_integrity_before_writing() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("keep.txt"), "keep").unwrap();
    let authority = SignedCredentials::new(b"edge".to_vec(), "login");
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.authority = Some(Arc::new(SignedCredentials::new(b"edge".to_vec(), "login")));
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    client.request(json!({"op":"hello"})).await;
    let mut checkpoint = checkpoint::pack(&[0, 0]).unwrap();
    assert_eq!(
        client
            .request(json!({"op":"doc.restore","path":"keep.txt","checkpoint":checkpoint}))
            .await["code"],
        "auth-required"
    );
    let expires = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 600;
    client.request(json!({"op":"auth.login","credential":authority.issue(&Identity{login:"editor".into(),id:1},expires)})).await;
    assert_eq!(
        client
            .request(json!({"op":"doc.restore","path":"../outside.txt","checkpoint":checkpoint}))
            .await["code"],
        "outside"
    );
    checkpoint.sha256 = "corrupt".into();
    assert_eq!(
        client
            .request(json!({"op":"doc.restore","path":"keep.txt","checkpoint":checkpoint}))
            .await["code"],
        "bad-checkpoint"
    );
    assert_eq!(
        fs::read_to_string(root.path().join("keep.txt")).unwrap(),
        "keep"
    );
    client.close().await;
    running.shutdown().await;
}
