use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::future::BoxFuture;
use rayde_session::{
    checkpoint,
    cloud::{self, Binding, Exchanged, Opened, Provider},
    dir_store::DirStore,
    docs::DocHub,
    error::{Result, SessionError},
    store::FileStore,
};
use rayde_sync::{ids::WorkspaceId, live};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use yrs::{
    Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, Transact, Update,
    updates::decoder::Decode,
};

struct Remote {
    seed: live::Seed,
    state: Mutex<Vec<u8>>,
    sequence: Mutex<u64>,
    offline: AtomicBool,
    omit_delete: AtomicBool,
    opens: AtomicUsize,
    gate: Mutex<Option<Arc<Gate>>>,
}
struct Gate {
    entered: tokio::sync::Notify,
    release: tokio::sync::Notify,
}
impl Remote {
    fn new() -> Arc<Self> {
        let doc = live::Document::new(
            WorkspaceId::from_random(&[5; 32]).as_str(),
            "a.txt",
            1,
            "one 🦀 two",
        )
        .unwrap();
        Arc::new(Self {
            seed: doc.seed.clone(),
            state: Mutex::new(doc.state()),
            sequence: Mutex::new(1),
            offline: AtomicBool::new(false),
            omit_delete: AtomicBool::new(false),
            opens: AtomicUsize::new(0),
            gate: Mutex::new(None),
        })
    }
    fn doc(&self) -> live::Document {
        live::Document::restore(self.seed.clone(), &[self.state.lock().unwrap().clone()]).unwrap()
    }
    fn binding(&self) -> Binding {
        Binding {
            version: 1,
            gateway: "https://gateway.invalid".into(),
            seed: serde_json::to_value(&self.seed).unwrap(),
            vector: B64.encode(self.doc().vector()),
            sequence: *self.sequence.lock().unwrap(),
        }
    }
    fn failure(&self) -> Result<()> {
        if self.offline.load(Ordering::SeqCst) {
            Err(SessionError::new("cloud-offline", "The cloud is offline."))
        } else {
            Ok(())
        }
    }
    fn remote_edit(&self, added: &str) {
        let base = self.doc();
        let doc = replica(&base.state(), 12);
        let text = doc.get_or_insert_text("text");
        let at = text.get_string(&doc.transact()).encode_utf16().count() as u32;
        text.insert(&mut doc.transact_mut(), at, added);
        let update = doc
            .transact()
            .encode_state_as_update_v1(&StateVector::decode_v1(&base.vector()).unwrap());
        let result = base
            .exchange(&self.seed.lineage, &base.vector(), &update)
            .unwrap();
        *self.state.lock().unwrap() = result.state;
        *self.sequence.lock().unwrap() += 1;
    }
}
impl Provider for Remote {
    fn open<'a>(
        &'a self,
        _path: &'a str,
        _disk: &'a str,
        previous: Option<Binding>,
    ) -> BoxFuture<'a, Result<Option<Opened>>> {
        Box::pin(async move {
            self.failure()?;
            self.opens.fetch_add(1, Ordering::SeqCst);
            if previous.is_some_and(|old| old.seed != serde_json::to_value(&self.seed).unwrap()) {
                return Err(cloud::lineage());
            }
            Ok(Some(Opened {
                binding: self.binding(),
                state: self.state.lock().unwrap().clone(),
            }))
        })
    }
    fn exchange<'a>(
        &'a self,
        previous: Binding,
        update: Vec<u8>,
    ) -> BoxFuture<'a, Result<Exchanged>> {
        Box::pin(async move {
            self.failure()?;
            let gate = self.gate.lock().unwrap().take();
            if let Some(gate) = gate {
                gate.entered.notify_one();
                gate.release.notified().await;
            }
            let current = self.doc();
            let from = B64.decode(previous.vector).unwrap();
            let next = current
                .exchange(&self.seed.lineage, &from, &update)
                .map_err(|_| cloud::lineage())?;
            if next.changed {
                *self.state.lock().unwrap() = next.state;
                *self.sequence.lock().unwrap() += 1;
            }
            Ok(Exchanged {
                binding: self.binding(),
                update: if self.omit_delete.load(Ordering::SeqCst) {
                    vec![0, 0]
                } else {
                    next.update
                },
                sha256: next.text_sha256,
            })
        })
    }
}
fn replica(state: &[u8], id: u64) -> Doc {
    let doc = Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::with_client_id(yrs::ClientID::new(id))
    });
    doc.transact_mut()
        .apply_update(Update::decode_v1(state).unwrap())
        .unwrap();
    doc
}
fn edit(doc: &Doc, value: &str) -> Vec<u8> {
    let before = doc.transact().state_vector();
    doc.get_or_insert_text("text")
        .insert(&mut doc.transact_mut(), 0, value);
    doc.transact().encode_state_as_update_v1(&before)
}
fn make_hub(
    root: &std::path::Path,
    private: &std::path::Path,
    remote: Arc<Remote>,
) -> (Arc<DirStore>, Arc<DocHub<DirStore>>) {
    let store = Arc::new(DirStore::with_state_root(root, private).unwrap());
    let hub = Arc::new(DocHub::new(store.clone(), Arc::new(|_| {})));
    hub.set_cloud(remote);
    (store, hub)
}

#[tokio::test]
async fn canonical_binding_keeps_unsaved_disk_separate_and_survives_reopen() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let remote = Remote::new();
    let (_, hub) = make_hub(root.path(), private.path(), remote.clone());
    let opened = hub
        .attach("a.txt", "one", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert!(opened.buffered);
    assert_eq!(
        opened.cloud_lineage.as_deref(),
        Some(remote.seed.lineage.as_str())
    );
    let client = replica(&opened.update, 11);
    hub.receive("a.txt", "one", &edit(&client, "local "))
        .unwrap();
    remote.remote_edit(" remote");
    hub.sync_cloud("a.txt").await.unwrap();
    assert_eq!(hub.text("a.txt").unwrap(), "local one 🦀 two remote");
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        "one 🦀 two"
    );
    hub.detach("a.txt", "one");
    hub.release("a.txt").await.unwrap();
    drop(hub);
    let (_, again) = make_hub(root.path(), private.path(), remote.clone());
    let reopened = again
        .attach("a.txt", "two", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert!(reopened.dirty);
    assert_eq!(reopened.text, "local one 🦀 two remote");
    again.save("a.txt", true).await.unwrap();
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        reopened.text
    );
}

#[tokio::test]
async fn offline_updates_remain_private_and_a_failed_save_does_not_touch_disk() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let remote = Remote::new();
    let (_, hub) = make_hub(root.path(), private.path(), remote.clone());
    let opened = hub
        .attach("a.txt", "one", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let client = replica(&opened.update, 11);
    hub.receive("a.txt", "one", &edit(&client, "offline "))
        .unwrap();
    remote.offline.store(true, Ordering::SeqCst);
    assert_eq!(
        hub.sync_cloud("a.txt").await.unwrap_err().code,
        "cloud-offline"
    );
    assert!(hub.save("a.txt", false).await.is_err());
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        "one 🦀 two"
    );
    hub.close().await;
    drop(hub);
    let (_, again) = make_hub(root.path(), private.path(), remote.clone());
    let reopened = again
        .attach("a.txt", "two", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(reopened.text, "offline one 🦀 two");
    assert!(reopened.dirty);
    remote.offline.store(false, Ordering::SeqCst);
    again.sync_cloud("a.txt").await.unwrap();
    assert_eq!(remote.doc().text(), reopened.text);
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        "one 🦀 two"
    );
}

#[tokio::test]
async fn legacy_graphs_are_kept_without_network_migration_and_old_replicas_are_fenced() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), private.path()).unwrap());
    let old = DocHub::new(store.clone(), Arc::new(|_| {}));
    let first = old
        .attach("a.txt", "one", None, Arc::new(|_| {}))
        .await
        .unwrap();
    old.detach("a.txt", "one");
    old.release("a.txt").await.unwrap();
    let graph = store.read_state("doc:a.txt").await.unwrap().unwrap();
    drop(old);
    let remote = Remote::new();
    let (_, hub) = make_hub(root.path(), private.path(), remote.clone());
    let reopened = hub
        .attach("a.txt", "two", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert!(reopened.cloud_legacy);
    assert!(reopened.cloud_lineage.is_none());
    assert_eq!(remote.opens.load(Ordering::SeqCst), 0);
    assert_eq!(store.read_state("doc:a.txt").await.unwrap().unwrap(), graph);
    let freshroot = tempfile::tempdir().unwrap();
    let freshstate = tempfile::tempdir().unwrap();
    std::fs::write(freshroot.path().join("a.txt"), "one 🦀 two").unwrap();
    let (_, fresh) = make_hub(freshroot.path(), freshstate.path(), remote.clone());
    assert_eq!(
        fresh
            .attach("a.txt", "old", Some(&first.vector), Arc::new(|_| {}))
            .await
            .err()
            .unwrap()
            .code,
        "document-lineage"
    );
}

#[tokio::test]
async fn edits_arriving_during_save_remain_dirty_and_outside_the_saved_checkpoint() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let remote = Remote::new();
    let (_, hub) = make_hub(root.path(), private.path(), remote.clone());
    let opened = hub
        .attach("a.txt", "one", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let client = replica(&opened.update, 11);
    hub.receive("a.txt", "one", &edit(&client, "first "))
        .unwrap();
    let gate = Arc::new(Gate {
        entered: tokio::sync::Notify::new(),
        release: tokio::sync::Notify::new(),
    });
    *remote.gate.lock().unwrap() = Some(gate.clone());
    let saving = hub.clone();
    let save = tokio::spawn(async move { saving.save("a.txt", true).await });
    gate.entered.notified().await;
    hub.receive("a.txt", "one", &edit(&client, "later "))
        .unwrap();
    gate.release.notify_one();
    let saved = save.await.unwrap().unwrap();
    assert_eq!(
        checkpoint::text(&saved.state.unwrap()).unwrap(),
        "first one 🦀 two"
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        "first one 🦀 two"
    );
    assert_eq!(hub.text("a.txt").unwrap(), "later first one 🦀 two");
    hub.detach("a.txt", "one");
    hub.release("a.txt").await.unwrap();
    let reopened = hub
        .attach("a.txt", "two", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert!(reopened.dirty);
    assert_eq!(reopened.text, "later first one 🦀 two");
}

#[tokio::test]
async fn corrupt_cloud_metadata_cannot_rebind_or_replace_the_private_graph() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let remote = Remote::new();
    let (store, hub) = make_hub(root.path(), private.path(), remote.clone());
    hub.attach("a.txt", "one", None, Arc::new(|_| {}))
        .await
        .unwrap();
    hub.close().await;
    drop(hub);
    let original = store.read_state("doc:a.txt").await.unwrap().unwrap();
    let mut corrupt = original.clone();
    let expected = remote.seed.lineage.as_bytes();
    let offset = corrupt
        .windows(expected.len())
        .position(|window| window == expected)
        .unwrap();
    corrupt[offset] = if corrupt[offset] == b'a' { b'b' } else { b'a' };
    store.write_state("doc:a.txt", &corrupt).await.unwrap();
    let opens = remote.opens.load(Ordering::SeqCst);
    let (_, blocked) = make_hub(root.path(), private.path(), remote.clone());
    assert!(
        blocked
            .attach("a.txt", "two", None, Arc::new(|_| {}))
            .await
            .is_err()
    );
    assert_eq!(remote.opens.load(Ordering::SeqCst), opens);
    assert_eq!(
        store.read_state("doc:a.txt").await.unwrap().unwrap(),
        corrupt
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        "one 🦀 two"
    );
    store.write_state("doc:a.txt", &original).await.unwrap();
    let (_, restored) = make_hub(root.path(), private.path(), remote);
    assert_eq!(
        restored
            .attach("a.txt", "three", None, Arc::new(|_| {}))
            .await
            .unwrap()
            .text,
        "one 🦀 two"
    );
}

#[tokio::test]
async fn a_vector_without_the_clouds_deletions_cannot_advance_the_private_frontier() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let remote = Remote::new();
    let (_, hub) = make_hub(root.path(), private.path(), remote.clone());
    hub.attach("a.txt", "one", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let before = remote.doc();
    let peer = replica(&before.state(), 12);
    peer.get_or_insert_text("text")
        .remove_range(&mut peer.transact_mut(), 0, 3);
    let removed = before
        .exchange(
            &remote.seed.lineage,
            &before.vector(),
            &peer
                .transact()
                .encode_state_as_update_v1(&StateVector::decode_v1(&before.vector()).unwrap()),
        )
        .unwrap();
    assert_eq!(removed.vector, before.vector());
    *remote.state.lock().unwrap() = removed.state;
    *remote.sequence.lock().unwrap() += 1;
    remote.omit_delete.store(true, Ordering::SeqCst);
    assert_eq!(
        hub.sync_cloud("a.txt").await.unwrap_err().code,
        "document-lineage"
    );
    assert_eq!(hub.text("a.txt").unwrap(), "one 🦀 two");
    remote.omit_delete.store(false, Ordering::SeqCst);
    hub.sync_cloud("a.txt").await.unwrap();
    assert_eq!(hub.text("a.txt").unwrap(), " 🦀 two");
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt")).unwrap(),
        "one 🦀 two"
    );
}

#[tokio::test]
async fn old_clients_do_not_create_a_cloud_graph_without_negotiating_its_recovery_format() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one 🦀 two").unwrap();
    let remote = Remote::new();
    let (_, hub) = make_hub(root.path(), private.path(), remote.clone());
    let old = hub
        .attach_mode("a.txt", "old", None, None, None, false, Arc::new(|_| {}))
        .await
        .unwrap();
    assert!(old.cloud_lineage.is_none());
    assert_eq!(remote.opens.load(Ordering::SeqCst), 0);
    hub.detach("a.txt", "old");
    hub.release("a.txt").await.unwrap();
    let modern = hub
        .attach("a.txt", "new", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert!(modern.cloud_legacy);
    assert!(modern.cloud_lineage.is_none());
    let other = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    std::fs::write(other.path().join("a.txt"), "one 🦀 two").unwrap();
    let (_, bound) = make_hub(other.path(), state.path(), remote);
    bound
        .attach("a.txt", "new", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(
        bound
            .attach_mode("a.txt", "old", None, None, None, false, Arc::new(|_| {}))
            .await
            .err()
            .unwrap()
            .code,
        "cloud-client-required"
    );
}
