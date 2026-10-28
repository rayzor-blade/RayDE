mod support;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use rayde_session::{
    checkpoint::{self, Delta},
    server::{Options, start},
};
use serde_json::json;
use std::fs;
use support::{Client, Peer};

#[tokio::test]
async fn acknowledged_journal_reopens_from_private_state_before_the_file_flush() {
    use rayde_session::{dir_store::DirStore, docs::DocHub};
    use std::{sync::Arc, time::Duration};
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("a.txt"), "base").unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.flush_delay = Duration::from_secs(60);
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    assert_eq!(client.request(json!({"op":"hello"})).await["privateJournals"], 1);
    let peer = Peer::new();
    peer.apply(client.request(json!({"op":"doc.open","path":"a.txt"})).await["update"].as_str().unwrap());
    let reply = client.request(json!({"op":"doc.update","path":"a.txt","journal":true,"vector":"AA==","update":peer.edit(4,0," pending")})).await;
    assert_eq!(reply["ok"], true);
    assert_eq!(fs::read_to_string(root.path().join("a.txt")).unwrap(), "base");
    let replacement = DocHub::new(Arc::new(DirStore::with_state_root(root.path(),state.path()).unwrap()),Arc::new(|_|{}));
    let opened = replacement.attach("a.txt","replacement",None,Arc::new(|_|{})).await.unwrap();
    assert_eq!(opened.text, "base pending");
    assert!(opened.buffered && opened.dirty);
    assert_eq!(B64.encode(opened.vector), reply["journal"]["vector"]);
    assert_eq!(fs::read_to_string(root.path().join("a.txt")).unwrap(), "base");
    replacement.close().await;
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn recovery_deltas_capture_a_baseline_then_only_missing_edits_and_deletions() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.txt"), "x".repeat(200_000)).unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    assert_eq!(client.request(json!({"op":"hello"})).await["journals"], 1);
    let peer = Peer::new();
    peer.apply(
        client
            .request(json!({"op":"doc.open","path":"main.txt"}))
            .await["update"]
            .as_str()
            .unwrap(),
    );
    let first:Delta=serde_json::from_value(client.request(json!({"op":"doc.update","path":"main.txt","journal":true,"vector":"AA==","update":peer.edit(0,0,"A")})).await["journal"].clone()).unwrap();
    let mut updates = vec![checkpoint::unpack_delta(&first).unwrap()];
    assert!(updates[0].len() > 200_000);
    let second:Delta=serde_json::from_value(client.request(json!({"op":"doc.update","path":"main.txt","journal":true,"vector":first.vector,"update":peer.edit(0,0,"B")})).await["journal"].clone()).unwrap();
    let small = checkpoint::unpack_delta(&second).unwrap();
    assert!(
        small.len() < 512,
        "typing must not resend a full document snapshot"
    );
    updates.push(small);
    let removed:Delta=serde_json::from_value(client.request(json!({"op":"doc.update","path":"main.txt","journal":true,"vector":second.vector,"update":peer.edit(0,1,"")})).await["journal"].clone()).unwrap();
    assert_eq!(
        removed.vector, second.vector,
        "deletion durability cannot rely on vector changes alone"
    );
    updates.push(checkpoint::unpack_delta(&removed).unwrap());
    assert_eq!(
        checkpoint::text(&checkpoint::materialize(&updates, &removed.vector).unwrap()).unwrap(),
        peer.string()
    );
    fs::write(root.path().join("main.txt"), "outside 🦊 edit").unwrap();
    running.workspace.changed("main.txt", "modified").await;
    let external:Delta=serde_json::from_value(client.request(json!({"op":"doc.update","path":"main.txt","journal":true,"vector":removed.vector,"update":"AAA="})).await["journal"].clone()).unwrap();
    updates.push(checkpoint::unpack_delta(&external).unwrap());
    assert_eq!(
        checkpoint::text(&checkpoint::materialize(&updates, &external.vector).unwrap()).unwrap(),
        "outside 🦊 edit"
    );
    assert!(
        checkpoint::materialize(&updates[1..], &external.vector).is_err(),
        "a delta tail without its baseline cannot be restored"
    );
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn recovery_vectors_and_incomplete_updates_cannot_claim_a_complete_graph() {
    let root = tempfile::tempdir().unwrap();
    let running = support::server(root.path(), false).await;
    fs::write(root.path().join("a.txt"), "base").unwrap();
    let mut client = Client::hello(&running).await;
    let peer = Peer::new();
    peer.apply(
        client
            .request(json!({"op":"doc.open","path":"a.txt"}))
            .await["update"]
            .as_str()
            .unwrap(),
    );
    let update = peer.edit(4, 0, "!");
    let ahead=client.request(json!({"op":"doc.update","path":"a.txt","journal":true,"vector":peer.vector(),"update":update})).await;
    assert_eq!(ahead["code"], "journal-conflict");
    assert_eq!(running.workspace.docs.text("a.txt").unwrap(), "base");
    assert_eq!(client.request(json!({"op":"doc.update","path":"a.txt","journal":true,"vector":"corrupt","update":update})).await["ok"],false);
    let mut delta:Delta=serde_json::from_value(client.request(json!({"op":"doc.update","path":"a.txt","journal":true,"vector":"AA==","update":update})).await["journal"].clone()).unwrap();
    delta.sha256 = "corrupt".into();
    assert!(checkpoint::unpack_delta(&delta).is_err());
    let later = peer.edit(5, 0, "second");
    let tail = peer.edit(11, 0, "third");
    let missing = client
        .request(
            json!({"op":"doc.update","path":"a.txt","journal":true,"vector":"AA==","update":tail}),
        )
        .await;
    assert_eq!(missing["ok"], false);
    let repaired = client
        .request(
            json!({"op":"doc.update","path":"a.txt","journal":true,"vector":"AA==","update":later}),
        )
        .await;
    let repaired: Delta = serde_json::from_value(repaired["journal"].clone()).unwrap();
    let state =
        checkpoint::materialize(&[B64.decode(repaired.update).unwrap()], &repaired.vector).unwrap();
    assert_eq!(checkpoint::text(&state).unwrap(), peer.string());
    client.close().await;
    running.shutdown().await;
}
