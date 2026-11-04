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
use serde_json::{json,Value};

async fn eventually(mut check:impl FnMut()->bool){
    tokio::time::timeout(std::time::Duration::from_secs(5),async {while !check(){tokio::time::sleep(std::time::Duration::from_millis(1)).await;}}).await.unwrap();
}
fn editors(hub:Arc<DocHub<DirStore>>)->(Arc<rayde_session::editor::Editors<DirStore>>,Arc<Mutex<Vec<Value>>>){
    let events=Arc::new(Mutex::new(Vec::new()));let out=events.clone();
    (rayde_session::editor::Editors::new(hub,Arc::new(move|text|out.lock().unwrap().push(serde_json::from_str(&text).unwrap()))),events)
}
async fn project(editor:&Arc<rayde_session::editor::Editors<DirStore>>,events:&Arc<Mutex<Vec<Value>>>,expected:&str,serial:u64)->Value{
    let mut found=None;eventually(||{let mut queue=events.lock().unwrap();if let Some(i)=queue.iter().position(|v|v["ev"]=="view.remote"&&v["text"]==expected&&v["serial"]==serial){found=Some(queue.remove(i));true}else{false}}).await;
    let offer=found.unwrap();editor.request("view.ack",&json!({"handle":"a","epoch":offer["epoch"],"accept":true})).await.unwrap();offer
}

struct Remote {
    seed: live::Seed,
    state: Mutex<Vec<u8>>,
    sequence: Mutex<u64>,
    offline: AtomicBool,
    omit_delete: AtomicBool,
    opens: AtomicUsize,
    gate: Mutex<Option<Arc<Gate>>>,
    watchers: Arc<Mutex<Vec<(u64,cloud::Notify)>>>,
    next_watch: AtomicUsize,
    accepted: Mutex<Vec<Binding>>,
    lose_reply: AtomicBool,
}
struct WatchGuard{watchers:Arc<Mutex<Vec<(u64,cloud::Notify)>>>,id:u64}
impl Drop for WatchGuard{fn drop(&mut self){self.watchers.lock().unwrap().retain(|(id,_)|*id!=self.id);}}
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
            watchers: Default::default(),next_watch:AtomicUsize::new(1),accepted:Default::default(),
            lose_reply:AtomicBool::new(false),
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
    fn notify(&self){let callbacks:Vec<_>=self.watchers.lock().unwrap().iter().map(|(_,notify)|notify.clone()).collect();for notify in callbacks{notify(cloud::Notice::Refresh);}}
}
impl Provider for Remote {
    fn watch(&self,_:Binding,notify:cloud::Notify)->Option<Box<dyn cloud::Subscription>>{let id=self.next_watch.fetch_add(1,Ordering::SeqCst) as u64;self.watchers.lock().unwrap().push((id,notify));Some(Box::new(WatchGuard{watchers:self.watchers.clone(),id}))}
    fn accepted(&self,binding:Binding){self.accepted.lock().unwrap().push(binding);}
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
            if self.lose_reply.swap(false,Ordering::SeqCst){return Err(SessionError::new("cloud-offline","The exchange reply was lost."))}
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

#[tokio::test]
async fn native_editor_preserves_author_undo_when_remote_projection_races_with_typing(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();let (_,hub)=make_hub(root.path(),private.path(),remote.clone());let (editor,events)=editors(hub.clone());
    let opened=editor.request("view.open",&json!({"handle":"a","path":"a.txt"})).await.unwrap();assert_eq!(opened["text"],"one 🦀 two");
    editor.request("view.ready",&json!({"handle":"a"})).await.unwrap();
    editor.request("view.edit",&json!({"handle":"a","epoch":0,"serial":1,"parts":[{"from":0,"removed":"","inserted":"local "}]})).await.unwrap();
    eventually(||remote.doc().text()=="local one 🦀 two").await;
    remote.remote_edit(" peer");editor.request("view.sync",&json!({"handle":"a"})).await.unwrap();
    eventually(||events.lock().unwrap().iter().any(|v|v["ev"]=="view.remote"&&v["text"]=="local one 🦀 two peer")).await;
    editor.request("view.edit",&json!({"handle":"a","epoch":0,"serial":2,"parts":[{"from":6,"removed":"one","inserted":"1"}]})).await.unwrap();
    editor.request("view.ack",&json!({"handle":"a","epoch":1,"accept":false})).await.unwrap();
    let offer=project(&editor,&events,"local 1 🦀 two peer",2).await;
    assert_eq!(offer["parts"][0]["from"],14);
    let undone=editor.request("view.undo",&json!({"handle":"a","epoch":1,"serial":3})).await.unwrap();assert_eq!(undone["text"],"local one 🦀 two peer");
    let undone=editor.request("view.undo",&json!({"handle":"a","epoch":1,"serial":4})).await.unwrap();assert_eq!(undone["text"],"one 🦀 two peer");
    assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two");
    let saved=editor.request("view.save",&json!({"handle":"a"})).await.unwrap();assert_eq!(saved["text"],"one 🦀 two peer");
    assert!(saved["savedRevision"].as_u64().unwrap()>opened["savedRevision"].as_u64().unwrap(),"Save must advance the projection's saved baseline revision");
    assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two peer");
    editor.request("view.close",&json!({"handle":"a"})).await.unwrap();assert!(hub.snapshot("a.txt").is_err());editor.close().await;
}

#[tokio::test]
async fn native_save_keeps_later_editor_transactions_dirty_and_private(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();let (_,hub)=make_hub(root.path(),private.path(),remote.clone());let (editor,_)=editors(hub.clone());
    editor.request("view.open",&json!({"handle":"a","path":"a.txt"})).await.unwrap();editor.request("view.ready",&json!({"handle":"a"})).await.unwrap();
    hub.sync_cloud("a.txt").await.unwrap();
    eventually(||!editor.pending()).await;
    let gate=Arc::new(Gate{entered:Default::default(),release:Default::default()});*remote.gate.lock().unwrap()=Some(gate.clone());
    let saving=editor.clone();let save=tokio::spawn(async move{saving.request("view.save",&json!({"handle":"a"})).await.unwrap()});
    tokio::time::timeout(std::time::Duration::from_secs(5),gate.entered.notified()).await.unwrap();
    editor.request("view.edit",&json!({"handle":"a","epoch":0,"serial":1,"parts":[{"from":0,"removed":"","inserted":"later "}]})).await.unwrap();
    gate.release.notify_one();let saved=save.await.unwrap();assert_eq!(saved["text"],"one 🦀 two");
    assert_eq!(hub.text("a.txt").unwrap(),"later one 🦀 two");assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two");
    editor.close().await;let opened=hub.attach("a.txt","again",None,Arc::new(|_|{})).await.unwrap();assert!(opened.dirty);assert_eq!(opened.text,"later one 🦀 two");
}

#[tokio::test]
async fn independent_native_windows_share_history_but_not_author_undo(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();let (_,hub)=make_hub(root.path(),private.path(),remote.clone());let (one,_)=editors(hub.clone());let (two,events)=editors(hub.clone());
    for editor in [&one,&two]{editor.request("view.open",&json!({"handle":"a","path":"a.txt"})).await.unwrap();editor.request("view.ready",&json!({"handle":"a"})).await.unwrap();}
    one.request("view.edit",&json!({"handle":"a","epoch":0,"serial":1,"parts":[{"from":0,"removed":"","inserted":"first "}]})).await.unwrap();
    project(&two,&events,"first one 🦀 two",0).await;
    two.request("view.edit",&json!({"handle":"a","epoch":1,"serial":1,"parts":[{"from":16,"removed":"","inserted":" second"}]})).await.unwrap();
    let undo=two.request("view.undo",&json!({"handle":"a","epoch":1,"serial":2})).await.unwrap();assert_eq!(undo["text"],"first one 🦀 two");
    one.close().await;assert!(hub.snapshot("a.txt").is_ok());two.close().await;assert!(hub.snapshot("a.txt").is_err());
}

#[tokio::test]
async fn native_editor_rejects_surrogates_without_mutation_and_passes_legacy_history_through(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();let (_,hub)=make_hub(root.path(),private.path(),remote.clone());let (editor,_)=editors(hub.clone());
    editor.request("view.open",&json!({"handle":"a","path":"a.txt"})).await.unwrap();editor.request("view.ready",&json!({"handle":"a"})).await.unwrap();
    assert!(editor.request("view.edit",&json!({"handle":"a","epoch":0,"serial":1,"parts":[{"from":5,"removed":"","inserted":"split"}]})).await.is_err());
    assert_eq!(hub.text("a.txt").unwrap(),"one 🦀 two");editor.close().await;
    let other=tempfile::tempdir().unwrap();let state=tempfile::tempdir().unwrap();std::fs::write(other.path().join("a.txt"),"one 🦀 two").unwrap();
    let store=Arc::new(DirStore::with_state_root(other.path(),state.path()).unwrap());let legacy=Arc::new(DocHub::new(store,Arc::new(|_|{})));
    legacy.attach("a.txt","old",None,Arc::new(|_|{})).await.unwrap();legacy.detach("a.txt","old");legacy.release("a.txt").await.unwrap();legacy.set_cloud(remote.clone());
    let (editor,_)=editors(legacy);let result=editor.request("view.open",&json!({"handle":"a","path":"a.txt"})).await.unwrap();assert_eq!(result["passthrough"],true);assert!(result["syncMessage"].as_str().unwrap().contains("reconciliation"));editor.close().await;
}

#[tokio::test]
async fn fresh_native_files_stay_editable_when_the_cloud_cannot_provide_a_history(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();remote.offline.store(true,Ordering::SeqCst);let (store,hub)=make_hub(root.path(),private.path(),remote);
    let (editor,_)=editors(hub.clone());let opened=editor.request("view.open",&json!({"handle":"a","path":"a.txt"})).await.unwrap();
    assert_eq!(opened["passthrough"],true);assert!(hub.snapshot("a.txt").is_err());assert!(store.read_state("doc:a.txt").await.unwrap().is_none());
    editor.close().await;assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two");
}

struct RefusingStore{inner:DirStore,writes:AtomicUsize,fail_at:AtomicUsize}
impl FileStore for RefusingStore{
    fn name(&self)->String{self.inner.name()}
    fn root(&self)->String{self.inner.root().to_string_lossy().into_owned()}
    async fn recovery_path(&self,p:&str)->Result<String>{self.inner.recovery_path(p).await}
    async fn matches_recovery_binding(&self,p:&str,b:&str)->Result<bool>{self.inner.matches_recovery_binding(p,b).await}
    async fn list(&self,p:&str)->Result<Vec<rayde_session::store::Entry>>{self.inner.list(p).await}
    async fn stat(&self,p:&str)->Result<Option<rayde_session::store::Entry>>{self.inner.stat(p).await}
    async fn read(&self,p:&str)->Result<Vec<u8>>{self.inner.read(p).await}
    async fn write(&self,p:&str,b:&[u8])->Result<()>{self.inner.write(p,b).await}
    async fn mkdir(&self,p:&str)->Result<()>{self.inner.mkdir(p).await}
    async fn remove(&self,p:&str,r:bool)->Result<()>{self.inner.remove(p,r).await}
    async fn rename(&self,a:&str,b:&str)->Result<()>{self.inner.rename(a,b).await}
    fn watch(&self,_:rayde_session::store::Change)->Box<dyn FnOnce()+Send>{Box::new(||{})}
    async fn read_state(&self,k:&str)->Result<Option<Vec<u8>>>{self.inner.read_state(k).await}
    async fn write_state(&self,k:&str,b:&[u8])->Result<()>{
        let n=self.writes.fetch_add(1,Ordering::SeqCst)+1;
        if n==self.fail_at.load(Ordering::SeqCst){return Err(SessionError::new("failed","Private journal write refused."))}
        self.inner.write_state(k,b).await
    }
}

#[tokio::test]
async fn pushed_updates_ack_only_after_private_persistence_and_release_their_subscription(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();let store=Arc::new(RefusingStore{inner:DirStore::with_state_root(root.path(),private.path()).unwrap(),writes:AtomicUsize::new(0),fail_at:AtomicUsize::new(usize::MAX)});
    let hub=Arc::new(DocHub::new(store.clone(),Arc::new(|_|{})));hub.enable_push();hub.set_cloud(remote.clone());
    let statuses=Arc::new(Mutex::new(Vec::new()));let observed=statuses.clone();hub.on_cloud_status("test".into(),Arc::new(move|_,error|observed.lock().unwrap().push(error)));
    let opened=hub.attach("a.txt","one",None,Arc::new(|_|{})).await.unwrap();assert_eq!(remote.watchers.lock().unwrap().len(),1);
    let client=replica(&opened.update,11);hub.receive("a.txt","one",&edit(&client,"private ")).unwrap();remote.remote_edit(" remote");
    store.fail_at.store(store.writes.load(Ordering::SeqCst)+2,Ordering::SeqCst);remote.notify();
    eventually(||statuses.lock().unwrap().iter().any(Option::is_some)).await;
    assert!(remote.accepted.lock().unwrap().is_empty(),"a refused private write cannot acknowledge a pushed frontier");
    assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two");
    remote.notify();eventually(||!remote.accepted.lock().unwrap().is_empty()).await;
    assert_eq!(remote.accepted.lock().unwrap().last().unwrap().sequence,*remote.sequence.lock().unwrap());
    assert_eq!(hub.text("a.txt").unwrap(),"private one 🦀 two remote");
    hub.detach("a.txt","one");hub.release("a.txt").await.unwrap();eventually(||remote.watchers.lock().unwrap().is_empty()).await;
    remote.offline.store(true,Ordering::SeqCst);let (_,reopened)=make_hub(root.path(),private.path(),remote.clone());
    let saved=reopened.attach("a.txt","two",None,Arc::new(|_|{})).await.unwrap();assert_eq!(saved.text,"private one 🦀 two remote");assert!(saved.dirty);
    assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two");
}

#[tokio::test]
async fn a_lost_pushed_exchange_reply_retries_the_private_graph_without_duplicate_journal_entries(){
    let root=tempfile::tempdir().unwrap();let private=tempfile::tempdir().unwrap();std::fs::write(root.path().join("a.txt"),"one 🦀 two").unwrap();
    let remote=Remote::new();let (_,hub)=make_hub(root.path(),private.path(),remote.clone());hub.enable_push();
    let statuses=Arc::new(Mutex::new(Vec::new()));let observed=statuses.clone();hub.on_cloud_status("test".into(),Arc::new(move|_,error|observed.lock().unwrap().push(error)));
    let opened=hub.attach("a.txt","one",None,Arc::new(|_|{})).await.unwrap();let client=replica(&opened.update,11);hub.receive("a.txt","one",&edit(&client,"once ")).unwrap();
    remote.lose_reply.store(true,Ordering::SeqCst);remote.notify();eventually(||statuses.lock().unwrap().iter().any(Option::is_some)).await;
    let committed=*remote.sequence.lock().unwrap();assert!(remote.accepted.lock().unwrap().is_empty());assert_eq!(remote.doc().text(),"once one 🦀 two");
    remote.notify();eventually(||!remote.accepted.lock().unwrap().is_empty()).await;assert_eq!(*remote.sequence.lock().unwrap(),committed);assert_eq!(hub.text("a.txt").unwrap(),"once one 🦀 two");
    assert_eq!(std::fs::read_to_string(root.path().join("a.txt")).unwrap(),"one 🦀 two");hub.detach("a.txt","one");hub.release("a.txt").await.unwrap();assert!(remote.watchers.lock().unwrap().is_empty());
}
