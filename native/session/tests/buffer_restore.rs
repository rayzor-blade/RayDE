mod support;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use rayde_session::{
    checkpoint::{self, Checkpoint},
    dir_store::DirStore,
    docs::DocHub,
    error::{Result, SessionError},
    server::{Options, start},
    store::{Change, Entry, FileStore},
};
use serde_json::json;
use std::{
    fs,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::{Client, Peer};
use yrs::{ReadTxn, StateVector, Transact};

fn checkpoint(peer: &Peer) -> Checkpoint {
    checkpoint::pack(
        &peer
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default()),
    )
    .unwrap()
}
async fn running(
    root: &std::path::Path,
    state: &std::path::Path,
) -> rayde_session::server::Running {
    let mut options = Options::new(root);
    options.state_root = Some(state.into());
    options.flush_delay = Duration::from_millis(10);
    start(options).await.unwrap()
}

#[tokio::test]
async fn buffered_restore_keeps_saved_disk_across_flush_release_restart_and_later_edits() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let path = root.path().join("main.hx");
    fs::write(&path, "saved 🦊\n").unwrap();
    let peer = Peer::new();
    peer.edit(0, 0, "unsaved 🦊\n");
    let snapshot = checkpoint(&peer);
    let server = running(root.path(), state.path()).await;
    let mut client = Client::connect(&server).await;
    assert_eq!(
        client.request(json!({"op":"hello"})).await["bufferedRestore"],
        1
    );
    let restored = client.request(json!({"op":"doc.restore","mode":"buffer","path":"main.hx","checkpoint":snapshot,"diskSha256":checkpoint::digest(b"saved \xf0\x9f\xa6\x8a\n")})).await;
    assert_eq!(restored["ok"], true, "{restored}");
    assert_eq!(restored["dirty"], true);
    let opened = client
        .request(json!({"op":"doc.open","path":"main.hx"}))
        .await;
    assert_eq!(opened["text"], "unsaved 🦊\n");
    assert_eq!(opened["buffered"], true);
    assert_eq!(opened["dirty"], true);
    peer.apply(opened["update"].as_str().unwrap());
    assert_eq!(peer.string(), "unsaved 🦊\n");
    let update = peer.edit(0, 0, "continued ");
    assert_eq!(
        client
            .request(json!({"op":"doc.update","path":"main.hx","update":update}))
            .await["ok"],
        true
    );
    server.workspace.docs.flush("main.hx").await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(fs::read_to_string(&path).unwrap(), "saved 🦊\n");
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"main.hx","data":"replacement"}))
            .await["code"],
        "buffer-dirty"
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.close","path":"main.hx"}))
            .await["ok"],
        true
    );
    assert!(server.workspace.docs.text("main.hx").is_none());
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"main.hx","data":"replacement"}))
            .await["code"],
        "buffer-dirty"
    );
    client.close().await;
    server.shutdown().await;
    let server = running(root.path(), state.path()).await;
    let mut client = Client::connect(&server).await;
    client.request(json!({"op":"hello"})).await;
    let opened = client
        .request(json!({"op":"doc.open","path":"main.hx"}))
        .await;
    assert_eq!(opened["text"], "continued unsaved 🦊\n");
    assert_eq!(opened["dirty"], true);
    peer.apply(opened["update"].as_str().unwrap());
    assert_eq!(peer.string(), "continued unsaved 🦊\n");
    assert_eq!(fs::read_to_string(&path).unwrap(), "saved 🦊\n");
    assert_eq!(
        client
            .request(json!({"op":"doc.save","path":"main.hx","checkpoint":true}))
            .await["ok"],
        true
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), peer.string());
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"main.hx"}))
            .await["dirty"],
        false
    );
    let update = peer.edit(0, 0, "later ");
    client
        .request(json!({"op":"doc.update","path":"main.hx","update":update}))
        .await;
    server.workspace.docs.flush("main.hx").await.unwrap();
    assert!(!fs::read_to_string(&path).unwrap().starts_with("later"));
    client.close().await;
    server.shutdown().await;
    let server = running(root.path(), state.path()).await;
    let mut client = Client::connect(&server).await;
    client.request(json!({"op":"hello"})).await;
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"main.hx"}))
            .await["text"],
        peer.string()
    );
    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn changed_or_invalid_baselines_do_not_replace_disk_or_recovered_state() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let path = root.path().join("file.txt");
    fs::write(&path, "disk").unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    let peer = Peer::new();
    peer.edit(0, 0, "buffer");
    let snapshot = checkpoint(&peer);
    assert_eq!(
        hub.restore_buffer("file.txt", &snapshot, &checkpoint::digest(b"wrong"))
            .await
            .err()
            .unwrap()
            .code,
        "recovery-conflict"
    );
    assert!(store.read_state("doc:file.txt").await.unwrap().is_none());
    hub.restore_buffer("file.txt", &snapshot, &checkpoint::digest(b"disk"))
        .await
        .unwrap();
    hub.attach("file.txt", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let saved = store.read_state("doc:file.txt").await.unwrap().unwrap();
    fs::write(&path, "outside").unwrap();
    hub.changed("file.txt").await;
    assert_eq!(hub.text("file.txt").unwrap(), "buffer");
    assert_eq!(
        hub.save("file.txt", false).await.err().unwrap().code,
        "recovery-conflict"
    );
    hub.detach("file.txt", "a");
    hub.release("file.txt").await.unwrap();
    assert_eq!(
        hub.attach("file.txt", "a", None, Arc::new(|_| {}))
            .await
            .err()
            .unwrap()
            .code,
        "recovery-conflict"
    );
    assert_eq!(
        store.read_state("doc:file.txt").await.unwrap().unwrap(),
        saved
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), "outside");
    fs::write(&path, "disk").unwrap();
    for bad in [vec![255], saved[..saved.len() - 1].to_vec(), {
        let mut bad = saved.clone();
        *bad.last_mut().unwrap() ^= 1;
        bad
    }] {
        store.write_state("doc:file.txt", &bad).await.unwrap();
        assert!(
            hub.attach("file.txt", "a", None, Arc::new(|_| {}))
                .await
                .is_err()
        );
        assert_eq!(
            store.read_state("doc:file.txt").await.unwrap().unwrap(),
            bad
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "disk");
    }
}

#[tokio::test]
async fn buffer_restore_checks_modes_types_active_aliases_and_clean_binary_replacement() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("file.txt"), "disk").unwrap();
    fs::write(root.path().join("binary"), [255]).unwrap();
    let server = running(root.path(), state.path()).await;
    let mut client = Client::connect(&server).await;
    client.request(json!({"op":"hello"})).await;
    let snapshot = checkpoint::pack(&[0, 0]).unwrap();
    let sha = checkpoint::digest(b"disk");
    for mode in [json!(null), json!(1), json!("unknown")] {
        assert_eq!(
            client
                .request(
                    json!({"op":"doc.restore","path":"file.txt","checkpoint":snapshot,"mode":mode})
                )
                .await["code"],
            "bad-request"
        );
    }
    assert_eq!(
        client
            .request(
                json!({"op":"doc.restore","path":"file.txt","checkpoint":snapshot,"diskSha256":sha})
            )
            .await["code"],
        "bad-request"
    );
    for (path, hash, code) in [
        ("file.txt", "bad", "bad-request"),
        ("missing", sha.as_str(), "recovery-conflict"),
        ("binary", sha.as_str(), "recovery-conflict"),
    ] {
        assert_eq!(client.request(json!({"op":"doc.restore","mode":"buffer","path":path,"checkpoint":snapshot,"diskSha256":hash})).await["code"],code);
    }
    client
        .request(json!({"op":"doc.open","path":"file.txt"}))
        .await;
    assert_eq!(client.request(json!({"op":"doc.restore","mode":"buffer","path":"file.txt","checkpoint":snapshot,"diskSha256":sha})).await["code"],"document-open");
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("file.txt", root.path().join("alias.txt")).unwrap();
        assert_eq!(client.request(json!({"op":"doc.restore","mode":"buffer","path":"alias.txt","checkpoint":snapshot,"diskSha256":sha})).await["code"],"document-open");
    }
    client
        .request(json!({"op":"doc.close","path":"file.txt"}))
        .await;
    let peer = Peer::new();
    peer.edit(0, 0, "disk");
    let snapshot = checkpoint(&peer);
    assert_eq!(client.request(json!({"op":"doc.restore","mode":"buffer","path":"file.txt","checkpoint":snapshot,"diskSha256":sha})).await["dirty"],false);
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"file.txt","data":"new"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"file.txt"}))
            .await["dirty"],
        false
    );
    client
        .request(json!({"op":"doc.close","path":"file.txt"}))
        .await;
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"file.txt","data":"/w==","encoding":"base64"}))
            .await["ok"],
        true
    );
    assert_eq!(fs::read(root.path().join("file.txt")).unwrap(), vec![255]);
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"file.txt","data":"text again"}))
            .await["ok"],
        true
    );
    let opened = client
        .request(json!({"op":"doc.open","path":"file.txt"}))
        .await;
    peer.apply(opened["update"].as_str().unwrap());
    assert_eq!(
        peer.string(),
        "text again",
        "clean file type changes preserve the earlier graph rather than reseeding it"
    );
    client.close().await;
    server.shutdown().await;
}

struct FaultStore {
    inner: DirStore,
    writes: AtomicUsize,
    fail_at: AtomicUsize,
    fail_disk: AtomicBool,
}
impl FileStore for FaultStore {
    async fn matches_recovery_binding(&self,p:&str,b:&str)->Result<bool>{self.inner.matches_recovery_binding(p,b).await}
    fn name(&self) -> String {
        self.inner.name()
    }
    fn root(&self) -> String {
        self.inner.root().to_string_lossy().into_owned()
    }
    async fn list(&self, p: &str) -> Result<Vec<Entry>> {
        self.inner.list(p).await
    }
    async fn stat(&self, p: &str) -> Result<Option<Entry>> {
        self.inner.stat(p).await
    }
    async fn read(&self, p: &str) -> Result<Vec<u8>> {
        self.inner.read(p).await
    }
    async fn write(&self, p: &str, b: &[u8]) -> Result<()> {
        if self.fail_disk.swap(false, Ordering::SeqCst) {
            return Err(SessionError::new("failed", "write refused"));
        }
        self.inner.write(p, b).await
    }
    async fn mkdir(&self, p: &str) -> Result<()> {
        self.inner.mkdir(p).await
    }
    async fn remove(&self, p: &str, r: bool) -> Result<()> {
        self.inner.remove(p, r).await
    }
    async fn rename(&self, a: &str, b: &str) -> Result<()> {
        self.inner.rename(a, b).await
    }
    fn watch(&self, _: Change) -> Box<dyn FnOnce() + Send> {
        Box::new(|| {})
    }
    async fn read_state(&self, k: &str) -> Result<Option<Vec<u8>>> {
        self.inner.read_state(k).await
    }
    async fn write_state(&self, k: &str, b: &[u8]) -> Result<()> {
        let n = self.writes.fetch_add(1, Ordering::SeqCst) + 1;
        if n == self.fail_at.load(Ordering::SeqCst) {
            return Err(SessionError::new("failed", "state refused"));
        }
        self.inner.write_state(k, b).await
    }
}

#[tokio::test]
async fn interrupted_saves_recover_on_either_side_of_the_disk_write() {
    for phase in 0..3 {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let path = root.path().join("file.txt");
        fs::write(&path, "saved").unwrap();
        let store = Arc::new(FaultStore {
            inner: DirStore::with_state_root(root.path(), state.path()).unwrap(),
            writes: AtomicUsize::new(0),
            fail_at: AtomicUsize::new(0),
            fail_disk: AtomicBool::new(false),
        });
        let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
        let peer = Peer::new();
        peer.edit(0, 0, "buffer");
        hub.restore_buffer(
            "file.txt",
            &checkpoint(&peer),
            &checkpoint::digest(b"saved"),
        )
        .await
        .unwrap();
        hub.attach("file.txt", "a", None, Arc::new(|_| {}))
            .await
            .unwrap();
        if phase == 1 {
            store.fail_disk.store(true, Ordering::SeqCst);
        } else {
            store.fail_at.store(
                store.writes.load(Ordering::SeqCst) + if phase == 0 { 1 } else { 2 },
                Ordering::SeqCst,
            );
        }
        assert!(hub.save("file.txt", false).await.is_err());
        drop(hub);
        let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
        let opened = hub
            .attach("file.txt", "a", None, Arc::new(|_| {}))
            .await
            .unwrap();
        assert_eq!(opened.text, "buffer");
        assert_eq!(opened.dirty, phase != 2);
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            if phase == 2 { "buffer" } else { "saved" }
        );
        peer.apply(&B64.encode(opened.update));
        assert_eq!(peer.string(), "buffer");
        hub.save("file.txt", true).await.unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "buffer");
    }
}
