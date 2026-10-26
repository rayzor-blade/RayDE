mod support;
use rayde_session::{checkpoint, dir_store::DirStore, docs::DocHub};
use serde_json::json;
use std::{fs, sync::Arc};

#[cfg(unix)]
#[tokio::test]
async fn file_and_directory_aliases_cannot_bypass_shared_document_guards() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/main.hx"), "keep").unwrap();
    std::os::unix::fs::symlink("src", root.path().join("alias")).unwrap();
    let hub = DocHub::new(
        Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap()),
        Arc::new(|_| {}),
    );
    hub.attach("src/main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(
        hub.remove("alias", true).await.unwrap_err().code,
        "document-open"
    );
    assert_eq!(
        hub.rename("alias/main.hx", "moved.hx")
            .await
            .unwrap_err()
            .code,
        "document-open"
    );
    assert_eq!(
        hub.write("alias/main.hx", b"changed")
            .await
            .unwrap_err()
            .code,
        "document-open"
    );
    if root.path().join("SRC/MAIN.HX").exists() {
        assert_eq!(
            hub.remove("SRC/MAIN.HX", false).await.unwrap_err().code,
            "document-open"
        );
    }
    assert_eq!(
        fs::read_to_string(root.path().join("src/main.hx")).unwrap(),
        "keep"
    );
    hub.close().await;
}

#[tokio::test]
async fn direct_writes_update_shared_graphs_without_a_file_watcher() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.hx"), "old").unwrap();
    let hub = DocHub::new(
        Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap()),
        Arc::new(|_| {}),
    );
    hub.attach("main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    hub.write("main.hx", b"new content").await.unwrap();
    assert_eq!(hub.text("main.hx").unwrap(), "new content");
    let delta = hub
        .receive_journal("main.hx", "a", &[0, 0], "AA==")
        .unwrap();
    let state =
        checkpoint::materialize(&[checkpoint::unpack_delta(&delta).unwrap()], &delta.vector)
            .unwrap();
    assert_eq!(checkpoint::text(&state).unwrap(), "new content");
    assert_eq!(
        hub.write("main.hx", &[255]).await.unwrap_err().code,
        "not-text"
    );
    assert_eq!(
        fs::read(root.path().join("main.hx")).unwrap(),
        b"new content"
    );
    assert_eq!(hub.text("main.hx").unwrap(), "new content");
    hub.close().await;
}

#[tokio::test]
async fn deleting_a_shared_file_or_parent_is_refused_until_the_document_is_released() {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::create_dir(root.path().join("src-other")).unwrap();
    fs::write(root.path().join("src/main.hx"), "base").unwrap();
    let running = support::server(root.path(), false).await;
    let mut client = support::Client::hello(&running).await;
    assert_eq!(
        client.request(json!({"op":"hello"})).await["fileMutations"],
        1
    );
    client
        .request(json!({"op":"doc.open","path":"src/main.hx"}))
        .await;
    for path in ["src/main.hx", "src"] {
        assert_eq!(
            client
                .request(json!({"op":"fs.remove","path":path,"recursive":true}))
                .await["code"],
            "document-open"
        );
        assert!(root.path().join("src/main.hx").exists());
    }
    assert_eq!(
        client
            .request(json!({"op":"fs.remove","path":"src-other"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"src/main.hx","data":"acknowledged"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"src/main.hx"}))
            .await["text"],
        "acknowledged"
    );
    client
        .request(json!({"op":"doc.close","path":"src/main.hx"}))
        .await;
    assert_eq!(
        client
            .request(json!({"op":"fs.remove","path":"src","recursive":true}))
            .await["ok"],
        true
    );
    assert!(!root.path().join("src").exists());
    client.close().await;
    running.shutdown().await;
}
