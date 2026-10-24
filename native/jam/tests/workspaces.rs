use futures_util::{SinkExt, StreamExt};
use rayde_jam::{
    document::{Document, Patch},
    transport::{Config, Session},
    workspace::{Frame, Store, Surface},
};
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

struct Client {
    session: Arc<Session>,
    events: Vec<Value>,
}
impl Client {
    fn new(host: bool, invite: &str, recovery: &str, restore: bool) -> Self {
        let seed = Document::new("").unwrap();
        Self {
            session: Session::start(
                Config {
                    host,
                    invite: invite.into(),
                    name: if host { "Host" } else { "Guest" }.into(),
                    file: "Workspace".into(),
                    state: seed.state(),
                    document_id: if host && !restore {
                        seed.id()
                    } else {
                        String::new()
                    },
                    recovery: recovery.into(),
                    restore,
                    workspace: true,
                },
                None,
            )
            .unwrap(),
            events: vec![],
        }
    }
    fn wait(&mut self, predicate: impl Fn(&Value) -> bool) -> Value {
        let end = Instant::now() + Duration::from_secs(8);
        loop {
            self.events.extend(self.session.poll());
            if let Some(at) = self.events.iter().position(&predicate) {
                return self.events.remove(at);
            }
            assert!(Instant::now() < end, "Jam event timeout: {:?}", self.events);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn workspace(&mut self, kind: &str, document: &str) -> Value {
        self.wait(|e| {
            e["t"] == "workspace"
                && e["message"]["t"] == kind
                && (document.is_empty() || e["message"]["document"] == document)
        })["message"]
            .clone()
    }
    fn send(&self, message: Value) {
        assert!(
            self.session
                .send(json!({"t":"workspace","message":message}))
        );
    }
    fn open(&mut self, doc: &Document, file: &str) {
        self.send(json!({"t":"open","document":doc.id(),"file":file,"state":doc.state()}));
        self.workspace("document", &doc.id());
    }
    fn ready(&mut self, doc: &mut Document, id: &str) {
        let snapshot = self.workspace("document", id);
        doc.apply(snapshot["state"].as_str().unwrap()).unwrap();
        self.send(json!({"t":"sync","document":id,"id":1,"update":doc.diff(snapshot["vector"].as_str().unwrap()).unwrap()}));
        self.workspace("ack", id);
    }
    fn stop(&mut self) {
        self.session.close();
        let end = Instant::now() + Duration::from_secs(3);
        while Arc::strong_count(&self.session) > 1 {
            assert!(
                Instant::now() < end,
                "Workspace worker retained after close"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        self.stop();
    }
}
fn edit(doc: &mut Document, inserted: &str) -> String {
    let before = doc.text();
    doc.edit(
        &before,
        &[Patch {
            from: before.encode_utf16().count() as u32,
            removed: String::new(),
            inserted: inserted.into(),
        }],
    )
    .unwrap()
}
fn frame(id: &str, sequence: u64) -> Frame {
    Frame { view:id.into(), sequence, width:1,height:1,png:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=".into() }
}

#[test]
fn independent_documents_stay_editable_during_host_tab_changes_and_late_join() {
    let mut host = Client::new(true, "", "", false);
    let invite = host.wait(|e| e["t"] == "hosting")["invite"]
        .as_str()
        .unwrap()
        .to_owned();
    host.wait(|e| e["t"] == "welcome");
    host.workspace("active", "");
    let mut a = Document::new("class A 🦀").unwrap();
    let mut b = Document::new("class B").unwrap();
    let aid = a.id();
    let bid = b.id();
    let preview = Document::new("").unwrap().id();
    host.open(&a, "src/A.hx");
    host.open(&b, "src/B.hx");
    host.send(json!({"t":"activate","surface":{"kind":"code","document":aid}}));
    host.workspace("active", "");
    let mut guest = Client::new(false, &invite, "", false);
    guest.wait(|e| e["t"] == "welcome");
    let mut ga = Document::new("").unwrap();
    let mut gb = Document::new("").unwrap();
    guest.ready(&mut ga, &aid);
    assert!(
        !guest.events.iter().any(|e| e["message"]["document"] == bid),
        "Inactive tab was shared before the host selected it"
    );
    host.send(json!({"t":"sync","document":bid,"id":3,"update":edit(&mut b," private")}));
    host.workspace("ack", &bid);
    host.send(json!({"t":"activate","surface":{"kind":"code","document":bid}}));
    guest.ready(&mut gb, &bid);
    host.workspace("update", &aid);
    host.workspace("update", &bid);
    assert_eq!(ga.text(), a.text());
    assert_eq!(gb.text(), b.text());
    assert_eq!(guest.workspace("active", "")["surface"]["document"], aid);
    assert!(!guest.session.send(
        json!({"t":"workspace","message":{"t":"activate","surface":{"kind":"code","document":bid}}})
    ));
    assert!(!guest.session.send(json!({"t":"workspace","message":{"t":"open","document":Document::new("").unwrap().id(),"file":"stolen.hx","state":a.state()}})));
    guest.send(json!({"t":"sync","document":aid,"id":2,"update":edit(&mut ga," guest edit")}));
    host.send(json!({"t":"sync","document":bid,"id":2,"update":edit(&mut b," host edit")}));
    let update = host.workspace("update", &aid);
    a.apply(update["update"].as_str().unwrap()).unwrap();
    let update = guest.workspace("update", &bid);
    gb.apply(update["update"].as_str().unwrap()).unwrap();
    guest.workspace("ack", &aid);
    host.workspace("ack", &bid);
    assert_eq!(ga.text(), a.text());
    assert_eq!(gb.text(), b.text());
    assert_eq!(guest.workspace("active", "")["surface"]["document"], bid);
    guest.send(json!({"t":"presence","document":aid,"caret":ga.position(10).unwrap(),"anchor":ga.position(0).unwrap(),"view":null}));
    assert_eq!(host.workspace("cursor", &aid)["document"], aid);
    host.send(
        json!({"t":"activate","surface":{"kind":"preview","id":preview,"title":"README.md"}}),
    );
    guest.workspace("active", "");
    host.send(json!({"t":"frame","frame":frame(&preview,1)}));
    assert_eq!(guest.workspace("frame", "")["frame"]["view"], preview);
    guest.send(json!({"t":"sync","document":aid,"id":3,"update":ga.undo(false)}));
    let update = host.workspace("update", &aid);
    a.apply(update["update"].as_str().unwrap()).unwrap();
    assert_eq!(a.text(), "class A 🦀");
    assert_eq!(b.text(), "class B private host edit");
    let mut late = Client::new(false, &invite, "", false);
    late.wait(|e| e["t"] == "welcome");
    assert_eq!(
        late.workspace("active", "")["surface"]["title"],
        "README.md"
    );
    assert_eq!(late.workspace("frame", "")["frame"]["sequence"], 1);
    assert!(
        !late.events.iter().any(|e| e["message"]["t"] == "document"),
        "Preview viewer received background code tabs"
    );
    host.send(json!({"t":"activate","surface":{"kind":"code","document":aid}}));
    let mut la = Document::new("").unwrap();
    late.ready(&mut la, &aid);
    assert_eq!(la.text(), a.text());
    assert!(
        !late.events.iter().any(|e| e["message"]["document"] == bid),
        "Switching to A exposed B to a late participant"
    );
    assert_eq!(guest.workspace("active", "")["surface"]["document"], aid);
    host.stop();
    guest.wait(|e| e["t"] == "room_closed");
}

#[test]
fn tab_selection_queued_before_connect_is_retained_without_sharing_other_tabs() {
    let mut host = Client::new(true, "", "", false);
    let active = Document::new("Active code").unwrap();
    let private = Document::new("Private code").unwrap();
    for (doc, file) in [(&active, "Active.hx"), (&private, "Private.hx")] {
        host.send(json!({"t":"open","document":doc.id(),"file":file,"state":doc.state()}));
    }
    host.send(json!({"t":"activate","surface":{"kind":"code","document":active.id()}}));
    let invite = host.wait(|e| e["t"] == "hosting")["invite"]
        .as_str()
        .unwrap()
        .to_owned();
    host.wait(|e| {
        e["message"]["t"] == "active" && e["message"]["surface"]["document"] == active.id()
    });
    let mut guest = Client::new(false, &invite, "", false);
    guest.wait(|e| e["t"] == "welcome");
    let mut code = Document::new("").unwrap();
    guest.ready(&mut code, &active.id());
    assert_eq!(code.text(), "Active code");
    assert!(
        !guest
            .events
            .iter()
            .any(|e| e["message"]["document"] == private.id())
    );
}

#[test]
fn workspace_recovers_each_document_and_rejects_corrupt_manifests_and_unsafe_paths() {
    let root =
        std::env::temp_dir().join(format!("jam-workspace-{}", Document::new("").unwrap().id()));
    let path = root.to_str().unwrap();
    let mut a = Document::new("A").unwrap();
    let b = Document::new("B 🦀").unwrap();
    let mut store = Store::open(path, false).unwrap();
    for file in [
        "/absolute.hx",
        "../escape.hx",
        "a/../../b",
        "C:/escape.hx",
        "a\\b",
        "a//b",
        "./a",
        "a\n.hx",
    ] {
        assert!(
            store
                .adopt(&Document::new("").unwrap().id(), file, &a.state())
                .is_err(),
            "Accepted {file}"
        );
    }
    store.adopt(&a.id(), "src/A.hx", &a.state()).unwrap();
    store.adopt(&b.id(), "src/B.hx", &b.state()).unwrap();
    store.accept(&a.id(), &edit(&mut a, " saved")).unwrap();
    store.activate(Surface::Code { document: a.id() }).unwrap();
    store
        .activate(Surface::Preview {
            id: Document::new("").unwrap().id(),
            title: "Preview".into(),
        })
        .unwrap();
    drop(store);
    let store = Store::open(path, true).unwrap();
    let mut recovered = Document::new("").unwrap();
    if let rayde_jam::workspace::Message::Document { state, .. } = store.snapshot(&a.id()).unwrap()
    {
        recovered.apply(&state).unwrap();
    } else {
        panic!();
    }
    assert_eq!(recovered.text(), "A saved");
    assert_eq!(store.snapshots().len(), 2);
    assert_eq!(store.active, Surface::Idle);
    assert!(store.shared(&a.id()));
    assert!(!store.shared(&b.id()));
    assert!(store.frame.is_none());
    drop(store);
    std::fs::write(root.join("workspace/manifest.json"), b"corrupt").unwrap();
    assert!(Store::open(path, true).is_err());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn restart_and_rejoin_merge_offline_edits_without_reseeding_other_documents() {
    let root = std::env::temp_dir().join(format!(
        "jam-workspace-rejoin-{}",
        Document::new("").unwrap().id()
    ));
    let hpath = root.join("host");
    let gpath = root.join("guest");
    let mut host = Client::new(true, "", hpath.to_str().unwrap(), false);
    let invite = host.wait(|e| e["t"] == "hosting")["invite"]
        .as_str()
        .unwrap()
        .to_owned();
    host.wait(|e| e["t"] == "welcome");
    let a = Document::new("A").unwrap();
    let b = Document::new("B").unwrap();
    host.open(&a, "src/A.hx");
    host.open(&b, "src/B.hx");
    host.send(json!({"t":"activate","surface":{"kind":"code","document":a.id()}}));
    let mut guest = Client::new(false, &invite, gpath.to_str().unwrap(), false);
    guest.wait(|e| e["t"] == "welcome");
    let mut ga = Document::new("").unwrap();
    let mut gb = Document::new("").unwrap();
    guest.ready(&mut ga, &a.id());
    host.send(json!({"t":"activate","surface":{"kind":"code","document":b.id()}}));
    guest.ready(&mut gb, &b.id());
    assert!(guest.session.send(json!({"t":"pause","paused":true})));
    guest.wait(|e| e["t"] == "paused");
    guest.send(json!({"t":"sync","document":a.id(),"id":2,"update":edit(&mut ga," offline 🦀")}));
    guest.workspace("locally_saved", &a.id());
    guest.stop();
    host.stop();
    let mut host = Client::new(true, "", hpath.to_str().unwrap(), true);
    let invite = host.wait(|e| e["t"] == "hosting")["invite"]
        .as_str()
        .unwrap()
        .to_owned();
    host.wait(|e| e["t"] == "welcome");
    let mut ha = Document::new("").unwrap();
    let mut hb = Document::new("").unwrap();
    host.ready(&mut ha, &a.id());
    host.ready(&mut hb, &b.id());
    assert_eq!(ha.text(), "A");
    assert_eq!(hb.text(), "B");
    let mut guest = Client::new(false, &invite, gpath.to_str().unwrap(), true);
    let mut ga = Document::new("").unwrap();
    ga.apply(
        guest.workspace("restored", &a.id())["state"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(ga.text(), "A offline 🦀");
    guest.wait(|e| e["t"] == "welcome");
    guest.ready(&mut ga, &a.id());
    let update = host.workspace("update", &a.id());
    ha.apply(update["update"].as_str().unwrap()).unwrap();
    assert_eq!(ha.text(), "A offline 🦀");
    assert_eq!(hb.text(), "B");
    guest.stop();
    host.stop();
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn preview_frames_validate_dimensions_and_never_enter_recovery() {
    let id = Document::new("").unwrap().id();
    let good = frame(&id, 1);
    assert!(good.valid());
    let mut bad = good.clone();
    bad.width = 1281;
    assert!(!bad.valid());
    let mut bad = good.clone();
    bad.width = 2;
    assert!(!bad.valid());
    let mut bad = good.clone();
    bad.png = "not png".into();
    assert!(!bad.valid());
    let mut store = Store::open("", false).unwrap();
    assert!(store.frame(good.clone()).is_err());
    store
        .activate(Surface::Preview {
            id: id.clone(),
            title: "Logo.svg".into(),
        })
        .unwrap();
    store.frame(good.clone()).unwrap();
    assert!(store.frame(good).is_err());
    assert!(store.snapshots().is_empty());
    store.activate(Surface::Idle).unwrap();
    assert!(store.frame.is_none());
}

#[test]
fn workspace_document_count_and_aggregate_state_are_bounded() {
    let mut store = Store::open("", false).unwrap();
    for i in 0..rayde_jam::workspace::MAX_DOCUMENTS {
        let doc = Document::new("").unwrap();
        store
            .adopt(&doc.id(), &format!("src/File{i}.hx"), &doc.state())
            .unwrap();
    }
    let doc = Document::new("one too many").unwrap();
    assert!(store.adopt(&doc.id(), "Overflow.hx", &doc.state()).is_err());
    assert!(!store.failed);
    let mut store = Store::open("", false).unwrap();
    let big = "x".repeat(1024 * 1024);
    let a = Document::new(&big).unwrap();
    let b = Document::new(&big).unwrap();
    let c = Document::new(&big).unwrap();
    store.adopt(&a.id(), "A.hx", &a.state()).unwrap();
    store.adopt(&b.id(), "B.hx", &b.state()).unwrap();
    assert!(store.adopt(&c.id(), "C.hx", &c.state()).is_err());
    assert!(!store.failed);
    assert_eq!(store.snapshots().len(), 2);
    assert!(store.accept(&a.id(), "invalid!").is_err());
    assert!(!store.failed);
    store.adopt(&a.id(), "A.hx", &a.state()).unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn guest_cannot_impersonate_host_or_take_over_active_tabs() {
    use tokio_tungstenite::{connect_async, tungstenite::Message};
    let mut host = Client::new(true, "", "", false);
    let invite = host.wait(|e| e["t"] == "hosting")["invite"]
        .as_str()
        .unwrap()
        .to_owned();
    let identity = host.wait(|e| e["t"] == "identity")["peer"]
        .as_str()
        .unwrap()
        .to_owned();
    host.wait(|e| e["t"] == "welcome");
    host.workspace("active", "");
    let seed = Document::new("Host code").unwrap();
    host.open(&seed, "src/Main.hx");
    for (peer, owner, expected) in [
        (identity, None, "already connected"),
        (
            Document::new("").unwrap().id(),
            Some("not-the-private-credential"),
            "host credential",
        ),
        (Document::new("").unwrap().id(), None, "Only the host"),
        (Document::new("").unwrap().id(), None, "not been presented"),
    ] {
        let (mut socket, _) = connect_async(&invite).await.unwrap();
        let hello = json!({"t":"hello","v":rayde_jam::transport::VERSION,"token":invite.rsplit('/').next().unwrap(),"peer":peer,"name":"Host","owner":owner,"workspace":true});
        socket
            .send(Message::Text(hello.to_string().into()))
            .await
            .unwrap();
        if expected == "Only the host" || expected == "not been presented" {
            let welcome = socket.next().await.unwrap().unwrap().into_text().unwrap();
            assert_eq!(
                serde_json::from_str::<Value>(&welcome).unwrap()["t"],
                "welcome"
            );
            let operation = if expected == "Only the host" {
                json!({"t":"activate","surface":{"kind":"idle"}})
            } else {
                json!({"t":"request","document":seed.id()})
            };
            socket
                .send(Message::Text(
                    json!({"t":"workspace","message":operation})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
        }
        loop {
            let response = tokio::time::timeout(Duration::from_secs(3), socket.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .into_text()
                .unwrap();
            let response: Value = serde_json::from_str(&response).unwrap();
            if response["t"] == "error" {
                assert!(
                    response["message"].as_str().unwrap().contains(expected),
                    "{response}"
                );
                break;
            }
        }
    }
    host.send(json!({"t":"activate","surface":{"kind":"code","document":seed.id()}}));
    assert_eq!(
        host.workspace("active", "")["surface"]["document"],
        seed.id()
    );
    assert!(!host.session.pending() || !host.session.poll().iter().any(|e| e["t"] == "failed"));
}
