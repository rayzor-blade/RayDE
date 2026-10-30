mod support;
use rayde_session::{checkpoint, dir_store::DirStore, docs::DocHub, store::FileStore};
use serde_json::json;
use std::{fs, sync::Arc};
use yrs::{ReadTxn, StateVector, Transact};

fn draft(text: &str) -> checkpoint::Checkpoint {
    let peer = support::Peer::new();
    peer.edit(0, 0, text);
    checkpoint::pack(
        &peer
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default()),
    )
    .unwrap()
}

#[tokio::test]
async fn closed_draft_and_saved_baseline_move_together_with_the_same_identity_after_restart() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/main.hx"), "saved 🦊\n").unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    hub.restore_buffer(
        "src/main.hx",
        &draft("unsaved 🦊\n"),
        &checkpoint::digest("saved 🦊\n".as_bytes()),
    )
    .await
    .unwrap();
    let opened = hub
        .attach("src/main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let id = opened.document_id.unwrap();
    hub.detach("src/main.hx", "a");
    hub.release("src/main.hx").await.unwrap();
    let graph = store.read_state("doc:src/main.hx").await.unwrap().unwrap();
    let moved = hub
        .rename_documents("src", "destination/src")
        .await
        .unwrap();
    assert_eq!(moved.documents.len(), 1);
    assert_eq!(moved.documents[0].id, id);
    assert_eq!(moved.documents[0].to, "destination/src/main.hx");
    assert_eq!(
        store
            .read_state("doc:destination/src/main.hx")
            .await
            .unwrap()
            .unwrap(),
        graph
    );
    assert_eq!(
        fs::read_to_string(root.path().join("destination/src/main.hx")).unwrap(),
        "saved 🦊\n"
    );
    drop(hub);
    drop(store);
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    assert_eq!(
        store.document_path(&id).await.unwrap().as_deref(),
        Some("destination/src/main.hx")
    );
    let opened = hub
        .attach("destination/src/main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(opened.document_id.as_deref(), Some(id.as_str()));
    assert!(opened.buffered && opened.dirty);
    assert_eq!(opened.text, "unsaved 🦊\n");
    hub.save("destination/src/main.hx", false).await.unwrap();
    hub.detach("destination/src/main.hx", "a");
    hub.release("destination/src/main.hx").await.unwrap();
    hub.write("src/main.hx", b"another file").await.unwrap();
    let created = hub
        .attach("src/main.hx", "b", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_ne!(created.document_id.as_deref(), Some(id.as_str()));
    assert_eq!(created.text, "another file");
    assert_eq!(
        fs::read_to_string(root.path().join("destination/src/main.hx")).unwrap(),
        "unsaved 🦊\n"
    );
    hub.close().await;
}

#[tokio::test]
async fn directory_moves_preserve_multiple_histories_and_refuse_open_documents_or_collisions() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    let mut ids = Vec::new();
    for (file, text) in [("a.txt", "draft A"), ("b.txt", "draft B")] {
        fs::write(root.path().join("src").join(file), "saved").unwrap();
        let path = format!("src/{file}");
        hub.restore_buffer(&path, &draft(text), &checkpoint::digest(b"saved"))
            .await
            .unwrap();
        ids.push(
            hub.attach(&path, "a", None, Arc::new(|_| {}))
                .await
                .unwrap()
                .document_id
                .unwrap(),
        );
        assert_eq!(
            hub.rename_documents("src", "moved").await.unwrap_err().code,
            "document-open"
        );
        hub.detach(&path, "a");
        hub.release(&path).await.unwrap();
    }
    fs::create_dir(root.path().join("occupied")).unwrap();
    assert_eq!(
        hub.rename_documents("src", "occupied")
            .await
            .unwrap_err()
            .code,
        "exists"
    );
    assert!(root.path().join("src/a.txt").exists());
    let moved = hub.rename_documents("src", "moved").await.unwrap();
    assert_eq!(moved.documents.len(), 2);
    for ((file, text), id) in [("a.txt", "draft A"), ("b.txt", "draft B")]
        .into_iter()
        .zip(ids)
    {
        let opened = hub
            .attach(&format!("moved/{file}"), "a", None, Arc::new(|_| {}))
            .await
            .unwrap();
        assert_eq!(opened.document_id.unwrap(), id);
        assert_eq!(opened.text, text);
    }
    hub.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn aliases_share_an_identity_without_competing_materialized_graphs() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/main.txt"), "saved").unwrap();
    std::os::unix::fs::symlink("src", root.path().join("alias")).unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    let opened = hub
        .attach("src/main.txt", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let id = opened.document_id.unwrap();
    assert_eq!(
        hub.attach("alias/main.txt", "b", None, Arc::new(|_| {}))
            .await
            .err()
            .unwrap()
            .code,
        "document-open"
    );
    hub.detach("src/main.txt", "a");
    hub.release("src/main.txt").await.unwrap();
    assert_eq!(
        hub.attach("alias/main.txt", "b", None, Arc::new(|_| {}))
            .await
            .unwrap()
            .document_id
            .unwrap(),
        id
    );
    hub.detach("alias/main.txt", "b");
    hub.release("alias/main.txt").await.unwrap();
    hub.rename_documents("alias/main.txt", "elsewhere.txt")
        .await
        .unwrap();
    assert_eq!(
        store.document_path(&id).await.unwrap().as_deref(),
        Some("elsewhere.txt")
    );
    hub.close().await;
}

#[tokio::test]
async fn protocol_exposes_moves_and_rejects_stale_identity_replay_into_a_recreated_path() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.txt"), "saved").unwrap();
    let server = support::server(root.path(), false).await;
    let mut client = support::Client::hello(&server).await;
    let capabilities = client.request(json!({"op":"hello","token":"secret"})).await;
    assert_eq!(capabilities["documentIdentities"], 1);
    assert_eq!(capabilities["closedDocumentMoves"], 1);
    let peer = support::Peer::new();
    let opened = client
        .request(json!({"op":"doc.open","path":"main.txt"}))
        .await;
    let id = opened["documentId"].as_str().unwrap().to_owned();
    peer.apply(opened["update"].as_str().unwrap());
    client
        .request(json!({"op":"doc.close","path":"main.txt"}))
        .await;
    let moved = client
        .request(
            json!({"op":"fs.rename","from":"main.txt","to":"moved.txt","preserveDocuments":true}),
        )
        .await;
    assert_eq!(moved["ok"], true, "{moved}");
    assert_eq!(moved["documents"][0]["id"], id);
    assert_eq!(
        client
            .request(json!({"op":"doc.resolve","documentId":id}))
            .await["path"],
        "moved.txt"
    );
    client
        .request(json!({"op":"fs.write","path":"main.txt","data":"new file"}))
        .await;
    assert_eq!(
        client
            .request(
                json!({"op":"doc.open","path":"main.txt","documentId":id,"vector":peer.vector()})
            )
            .await["code"],
        "document-changed"
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"main.txt","vector":peer.vector()}))
            .await["code"],
        "identity-required"
    );
    let fresh = client
        .request(json!({"op":"doc.open","path":"main.txt"}))
        .await;
    assert_eq!(fresh["text"], "new file");
    assert_ne!(fresh["documentId"], id);
    assert_eq!(
        client
            .request(json!({"op":"doc.save","path":"main.txt","documentId":id}))
            .await["code"],
        "document-changed"
    );
    client
        .request(json!({"op":"doc.close","path":"main.txt"}))
        .await;
    assert_eq!(
        client
            .request(json!({"op":"fs.remove","path":"main.txt"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.resolve","documentId":fresh["documentId"]}))
            .await["path"],
        serde_json::Value::Null
    );
    assert_eq!(
        fs::read_to_string(root.path().join("moved.txt")).unwrap(),
        "saved"
    );
    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn case_changes_preserve_document_identity_for_files_and_parent_folders() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/file.txt"), "saved").unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    hub.restore_buffer(
        "src/file.txt",
        &draft("draft"),
        &checkpoint::digest(b"saved"),
    )
    .await
    .unwrap();
    let id = hub
        .attach("src/file.txt", "a", None, Arc::new(|_| {}))
        .await
        .unwrap()
        .document_id
        .unwrap();
    hub.detach("src/file.txt", "a");
    hub.release("src/file.txt").await.unwrap();
    hub.rename_documents("src/file.txt", "src/File.txt")
        .await
        .unwrap();
    hub.rename_documents("src", "SRC").await.unwrap();
    drop(hub);
    drop(store);
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    assert_eq!(
        store.document_path(&id).await.unwrap().as_deref(),
        Some("SRC/File.txt")
    );
    let opened = hub
        .attach_identified("SRC/File.txt", "a", None, Some(&id), Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(opened.document_id.as_deref(), Some(id.as_str()));
    assert_eq!(opened.text, "draft");
    assert!(opened.dirty);
    assert_eq!(
        fs::read_to_string(root.path().join("SRC/File.txt")).unwrap(),
        "saved"
    );
    hub.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn moving_a_symlink_never_moves_or_rebinds_its_target() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("target.txt"), "saved").unwrap();
    std::os::unix::fs::symlink("target.txt", root.path().join("alias")).unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    let id = hub
        .attach("target.txt", "a", None, Arc::new(|_| {}))
        .await
        .unwrap()
        .document_id
        .unwrap();
    hub.detach("target.txt", "a");
    hub.release("target.txt").await.unwrap();
    assert_eq!(
        hub.rename_documents("alias", "moved")
            .await
            .unwrap_err()
            .code,
        "unsupported"
    );
    assert!(
        fs::symlink_metadata(root.path().join("alias"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
    fs::write(root.path().join("occupied"), "other").unwrap();
    assert_eq!(
        hub.rename("alias", "occupied").await.unwrap_err().code,
        "exists"
    );
    assert_eq!(
        fs::read_to_string(root.path().join("occupied")).unwrap(),
        "other"
    );
    hub.rename("alias", "moved").await.unwrap();
    assert!(
        fs::symlink_metadata(root.path().join("moved"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(
        store.document_path(&id).await.unwrap().as_deref(),
        Some("target.txt")
    );
    assert_eq!(
        fs::read_to_string(root.path().join("target.txt")).unwrap(),
        "saved"
    );
    hub.close().await;
}

struct PausedIdentity {
    inner: DirStore,
    pause: std::sync::atomic::AtomicBool,
    entered: tokio::sync::Notify,
    resume: tokio::sync::Notify,
}
impl FileStore for PausedIdentity {
    fn name(&self) -> String {
        self.inner.name()
    }
    fn root(&self) -> String {
        self.inner.root().to_string_lossy().into_owned()
    }
    async fn document_identity(&self, path: &str) -> rayde_session::error::Result<Option<String>> {
        let id = self.inner.document_identity(path).await?;
        if self.pause.swap(false, std::sync::atomic::Ordering::SeqCst) {
            self.entered.notify_one();
            self.resume.notified().await;
        }
        Ok(id)
    }
    async fn recovery_path(&self, p: &str) -> rayde_session::error::Result<String> {
        self.inner.recovery_path(p).await
    }
    async fn rename_documents(
        &self,
        a: &str,
        b: &str,
    ) -> rayde_session::error::Result<rayde_session::store::DocumentMoveReceipt> {
        self.inner.rename_documents(a, b).await
    }
    async fn list(
        &self,
        p: &str,
    ) -> rayde_session::error::Result<Vec<rayde_session::store::Entry>> {
        self.inner.list(p).await
    }
    async fn stat(
        &self,
        p: &str,
    ) -> rayde_session::error::Result<Option<rayde_session::store::Entry>> {
        self.inner.stat(p).await
    }
    async fn read(&self, p: &str) -> rayde_session::error::Result<Vec<u8>> {
        self.inner.read(p).await
    }
    async fn write(&self, p: &str, b: &[u8]) -> rayde_session::error::Result<()> {
        self.inner.write(p, b).await
    }
    async fn mkdir(&self, p: &str) -> rayde_session::error::Result<()> {
        self.inner.mkdir(p).await
    }
    async fn remove(&self, p: &str, recursive: bool) -> rayde_session::error::Result<()> {
        self.inner.remove(p, recursive).await
    }
    async fn rename(&self, a: &str, b: &str) -> rayde_session::error::Result<()> {
        self.inner.rename(a, b).await
    }
    fn watch(&self, _: rayde_session::store::Change) -> Box<dyn FnOnce() + Send> {
        Box::new(|| {})
    }
    async fn read_state(&self, key: &str) -> rayde_session::error::Result<Option<Vec<u8>>> {
        self.inner.read_state(key).await
    }
    async fn write_state(&self, key: &str, bytes: &[u8]) -> rayde_session::error::Result<()> {
        self.inner.write_state(key, bytes).await
    }
}

#[tokio::test]
async fn expected_identity_is_checked_atomically_with_opening_against_other_connections() {
    use std::sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    };
    use std::time::Duration;
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("file.txt"), "original").unwrap();
    let store = Arc::new(PausedIdentity {
        inner: DirStore::with_state_root(root.path(), state.path()).unwrap(),
        pause: AtomicBool::new(false),
        entered: Default::default(),
        resume: Default::default(),
    });
    let workspace =
        rayde_session::session::Workspace::new(store.clone(), None, None, Arc::new(|_| {}));
    let id = workspace
        .docs
        .attach("file.txt", "seed", None, Arc::new(|_| {}))
        .await
        .unwrap()
        .document_id
        .unwrap();
    workspace.docs.detach("file.txt", "seed");
    workspace.docs.release("file.txt").await.unwrap();
    let replies = Arc::new(Mutex::new(Vec::new()));
    let output = replies.clone();
    let mut client = workspace
        .connect(Arc::new(move |text| {
            output
                .lock()
                .unwrap()
                .push(serde_json::from_str::<serde_json::Value>(&text).unwrap())
        }))
        .unwrap();
    client.handle(r#"{"id":1,"op":"hello"}"#).await;
    store.pause.store(true, Ordering::SeqCst);
    let opening = tokio::spawn(async move {
        client
            .handle(&json!({"id":2,"op":"doc.open","path":"file.txt","documentId":id}).to_string())
            .await;
        client
    });
    tokio::time::timeout(Duration::from_secs(2), store.entered.notified())
        .await
        .unwrap();
    assert!(
        tokio::time::timeout(
            Duration::from_millis(20),
            workspace.docs.rename_documents("file.txt", "moved.txt")
        )
        .await
        .is_err(),
        "A move passed the identity check while the subscription was not yet registered"
    );
    assert!(root.path().join("file.txt").exists());
    store.resume.notify_one();
    let mut client = opening.await.unwrap();
    assert_eq!(
        replies
            .lock()
            .unwrap()
            .iter()
            .find(|r| r["id"] == 2)
            .unwrap()["ok"],
        true
    );
    assert_eq!(
        workspace
            .docs
            .rename_documents("file.txt", "moved.txt")
            .await
            .unwrap_err()
            .code,
        "document-open"
    );
    client.close();
    workspace.docs.close().await;
}
