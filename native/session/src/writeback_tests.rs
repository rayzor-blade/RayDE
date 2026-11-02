use super::*;
use axum::{
    Router,
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::any,
};
use rayde_sync::{
    chunk::sha256_hex,
    manifest::{ChunkRef, FileEntry, FileKind, Origin},
};
use std::fs;

fn base(generation: u64, text: &str) -> Base {
    let mut manifest = rayde_sync::manifest::Manifest::from_bytes(include_bytes!(
        "../../sync/tests/fixtures/manifest-v1.json"
    ))
    .unwrap();
    let hash = sha256_hex(text.as_bytes());
    manifest.generation = generation;
    manifest.base_generation = generation - 1;
    manifest.buffers.clear();
    manifest.git.index.clear();
    manifest.git.deleted.clear();
    manifest.files = vec![FileEntry {
        path: "notes.txt".into(),
        kind: FileKind::Regular,
        origin: Origin::Tracked,
        size: text.len() as u64,
        hash: hash.clone(),
        chunks: if text.is_empty() {
            vec![]
        } else {
            vec![ChunkRef {
                hash,
                size: text.len() as u32,
            }]
        },
        link: None,
    }];
    manifest.finalize();
    Base {
        manifest,
        texts: BTreeMap::from([("notes.txt".into(), text.as_bytes().to_vec())]),
    }
}
struct Gate {
    entered: tokio::sync::Notify,
    release: tokio::sync::Notify,
}
struct Remote {
    base: Base,
    token: String,
    chunks: BTreeMap<String, Vec<u8>>,
    lost_reply: bool,
    publishes: usize,
    gate: Option<Arc<Gate>>,
    fail_intent: Option<std::path::PathBuf>,
}
struct Gateway {
    url: String,
    state: Arc<Mutex<Remote>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Gateway {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Gateway {
    async fn new(initial: Base) -> Self {
        let chunks = initial
            .texts
            .values()
            .map(|bytes| (sha256_hex(bytes), bytes.clone()))
            .collect();
        let state = Arc::new(Mutex::new(Remote {
            base: initial,
            token: "first-token".into(),
            chunks,
            lost_reply: false,
            publishes: 0,
            gate: None,
            fail_intent: None,
        }));
        async fn handle(
            State(state): State<Arc<Mutex<Remote>>>,
            Path(path): Path<String>,
            method: Method,
            headers: HeaderMap,
            body: Bytes,
        ) -> Response {
            let gate = if method == Method::POST && path.ends_with("/publish") {
                state.lock().unwrap().gate.take()
            } else {
                None
            };
            if let Some(gate) = gate {
                gate.entered.notify_one();
                gate.release.notified().await;
            }
            let mut remote = state.lock().unwrap();
            if headers.get("Authorization").and_then(|v| v.to_str().ok())
                != Some(format!("Bearer {}", remote.token).as_str())
            {
                return (
                    StatusCode::UNAUTHORIZED,
                    axum::Json(json!({"message":"Expired"})),
                )
                    .into_response();
            }
            let parts = path.split('/').collect::<Vec<_>>();
            if parts.get(1) != Some(&remote.base.manifest.workspace.as_str()) {
                return StatusCode::NOT_FOUND.into_response();
            }
            match (method, parts.as_slice()) {
                (Method::GET, ["workspaces", _]) => axum::Json(
                    json!({"generation":remote.base.generation(),"allocation":1024*1024*1024}),
                )
                .into_response(),
                (Method::GET, ["workspaces", _, "export", "manifest"]) => {
                    remote.base.manifest.to_bytes().into_response()
                }
                (Method::GET, ["workspaces", _, "export", "chunks", hash]) => remote
                    .chunks
                    .get(*hash)
                    .cloned()
                    .map(IntoResponse::into_response)
                    .unwrap_or(StatusCode::NOT_FOUND.into_response()),
                (Method::POST, ["workspaces", _, "uploads"]) => {
                    if let Some(path) = remote.fail_intent.take() {
                        fs::create_dir(path).unwrap();
                    }
                    let declared: Value = serde_json::from_slice(&body).unwrap();
                    let missing: Vec<_> = declared["chunks"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .filter(|c| !remote.chunks.contains_key(c["hash"].as_str().unwrap()))
                        .map(|c| c["hash"].clone())
                        .collect();
                    axum::Json(json!({"lease":"lease","missing":missing})).into_response()
                }
                (Method::PUT, ["workspaces", _, "uploads", _, "chunks", hash]) => {
                    assert_eq!(sha256_hex(&body), *hash);
                    remote.chunks.insert(hash.to_string(), body.to_vec());
                    axum::Json(json!({})).into_response()
                }
                (Method::POST, ["workspaces", _, "uploads", _, "publish"]) => {
                    let manifest = rayde_sync::manifest::Manifest::from_bytes(&body).unwrap();
                    if manifest.base_generation != remote.base.generation() {
                        return (
                            StatusCode::CONFLICT,
                            axum::Json(json!({"code":"conflict","message":"Remote moved"})),
                        )
                            .into_response();
                    }
                    let texts = manifest
                        .files
                        .iter()
                        .map(|f| {
                            (
                                f.path.clone(),
                                f.chunks
                                    .iter()
                                    .flat_map(|c| remote.chunks[&c.hash].clone())
                                    .collect(),
                            )
                        })
                        .collect();
                    remote.base = Base { manifest, texts };
                    remote.publishes += 1;
                    if remote.lost_reply {
                        remote.lost_reply = false;
                        return (StatusCode::BAD_GATEWAY, "reply lost").into_response();
                    }
                    axum::Json(json!({"generation":remote.base.generation()})).into_response()
                }
                (Method::DELETE, ["workspaces", _, "uploads", _]) => {
                    axum::Json(json!({})).into_response()
                }
                _ => StatusCode::NOT_FOUND.into_response(),
            }
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = Router::new()
            .route("/api/sync/*path", any(handle))
            .with_state(state.clone());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self { url, state, task }
    }
    fn advance(&self, text: &str) {
        let mut remote = self.state.lock().unwrap();
        remote.base = base(remote.base.generation() + 1, text);
        for bytes in remote.base.texts.values().cloned().collect::<Vec<_>>() {
            remote.chunks.insert(sha256_hex(&bytes), bytes);
        }
    }
}
fn session(
    store: Arc<DirStore>,
    gateway: &Gateway,
    token: &str,
    fresh: bool,
    restored: u64,
) -> Arc<Writeback> {
    Arc::new(Writeback {
        store,
        gateway: gateway.url.clone(),
        workspace: gateway
            .state
            .lock()
            .unwrap()
            .base
            .manifest
            .workspace
            .to_string(),
        token: Mutex::new(token.into()),
        control: Some("private-control-key".into()),
        restored,
        fresh,
        status: Mutex::new(Status {
            generation: restored,
            ready: false,
            message: String::new(),
            error: None,
        }),
        working: tokio::sync::Mutex::new(()),
    })
}
fn store(root: &PathBuf, private: &PathBuf) -> Arc<DirStore> {
    Arc::new(DirStore::with_state_root(root, private).unwrap())
}

#[test]
fn records_are_bounded_checked_and_bound_to_the_gateway_and_workspace() {
    let original = base(1, "one\n");
    let gateway = "https://sync.example.test";
    let id = original.manifest.workspace.as_str();
    let packed = state::pack(gateway, &original, None, vec![]).unwrap();
    assert_eq!(
        state::unpack(&packed, gateway, id).unwrap().base.manifest,
        original.manifest
    );
    for offset in [0, 8, 40, packed.len() - 1] {
        let mut bad = packed.clone();
        bad[offset] ^= 1;
        assert!(state::unpack(&bad, gateway, id).is_err());
    }
    assert!(state::unpack(&packed[..packed.len() - 1], gateway, id).is_err());
    assert!(state::unpack(&packed, "https://elsewhere.test", id).is_err());
    assert!(state::unpack(&packed, gateway, "other-workspace").is_err());
    let mut forged = original.clone();
    forged
        .texts
        .insert("notes.txt".into(), b"different".to_vec());
    assert!(
        state::unpack(
            &state::pack(gateway, &forged, None, vec![]).unwrap(),
            gateway,
            id
        )
        .is_err()
    );
    let mut huge = original.clone();
    huge.texts
        .insert("notes.txt".into(), vec![0; 32 * 1024 * 1024 + 1]);
    assert!(state::pack(gateway, &huge, None, vec![]).is_err());
}

#[tokio::test]
async fn saved_base_survives_replacement_and_merges_newer_cloud_edits() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let root = root.path().to_path_buf();
    let private = private.path().to_path_buf();
    let original = "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\n";
    fs::write(root.join("notes.txt"), original).unwrap();
    let gateway = Gateway::new(base(1, original)).await;
    let first = session(store(&root, &private), &gateway, "first-token", true, 1);
    first.clone().initialize().await;
    assert_eq!(first.describe()["ready"], true);
    fs::write(
        root.join("notes.txt"),
        original.replace("zero", "published"),
    )
    .unwrap();
    assert_eq!(first.publish(root.clone()).await.unwrap()["generation"], 2);
    fs::write(
        root.join("notes.txt"),
        original
            .replace("zero", "published")
            .replace("two", "local"),
    )
    .unwrap();
    gateway.advance(
        &original
            .replace("zero", "published")
            .replace("seven", "remote"),
    );
    gateway.state.lock().unwrap().token = "renewed-token".into();
    drop(first);
    let replacement = session(store(&root, &private), &gateway, "renewed-token", false, 0);
    replacement.clone().initialize().await;
    assert_eq!(replacement.describe()["generation"], 2);
    assert_eq!(replacement.describe()["ready"], true);
    let merged = replacement
        .merge(root.clone(), BTreeMap::new())
        .await
        .unwrap();
    assert!(merged["conflicts"].as_array().unwrap().is_empty());
    let text = fs::read_to_string(root.join("notes.txt")).unwrap();
    assert!(text.contains("local") && text.contains("remote") && text.contains("published"));
    drop(replacement);
    let last = session(store(&root, &private), &gateway, "renewed-token", false, 1);
    last.clone().initialize().await;
    assert_eq!(last.describe()["generation"], 3);
    assert_eq!(last.publish(root.clone()).await.unwrap()["generation"], 4);
    for key in [state::BASE, state::PENDING, state::BINDING] {
        let bytes = last.store.read_state(key).await.unwrap().unwrap();
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("renewed-token") && !text.contains("private-control-key"));
    }
}

#[tokio::test]
async fn writeback_recovery_keeps_the_unsaved_document_graph_separate_from_disk() {
    use yrs::{Doc, ReadTxn, Text, Transact, Update, updates::decoder::Decode};
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    let private = private.path().to_path_buf();
    fs::write(path.join("notes.txt"), "saved").unwrap();
    let gateway = Gateway::new(base(1, "saved")).await;
    let first = session(store(&path, &private), &gateway, "first-token", true, 1);
    first.clone().initialize().await;
    let docs = crate::docs::DocHub::new(first.store.clone(), Arc::new(|_| {}));
    let opened = docs
        .attach("notes.txt", "peer", None, Arc::new(|_| {}))
        .await
        .unwrap();
    let peer = Doc::with_options(yrs::Options {
        offset_kind: yrs::OffsetKind::Utf16,
        ..Default::default()
    });
    peer.transact_mut()
        .apply_update(Update::decode_v1(&opened.update).unwrap())
        .unwrap();
    peer.get_or_insert_text("text")
        .insert(&mut peer.transact_mut(), 5, " draft");
    let update = peer
        .transact()
        .encode_state_as_update_v1(&yrs::StateVector::default());
    docs.receive("notes.txt", "peer", &update).unwrap();
    docs.persist_journal("notes.txt").await.unwrap();
    drop(docs);
    drop(first);
    let next = session(store(&path, &private), &gateway, "first-token", false, 0);
    next.clone().initialize().await;
    let docs = crate::docs::DocHub::new(next.store.clone(), Arc::new(|_| {}));
    let recovered = docs
        .attach("notes.txt", "next", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(recovered.text, "saved draft");
    assert!(recovered.buffered && recovered.dirty);
    assert_eq!(fs::read_to_string(path.join("notes.txt")).unwrap(), "saved");
    assert_eq!(next.describe()["generation"], 1);
}

#[tokio::test]
async fn lost_publish_reply_is_reconciled_once_without_a_second_publish() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "old").unwrap();
    let gateway = Gateway::new(base(1, "old")).await;
    let first = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    first.clone().initialize().await;
    fs::write(path.join("notes.txt"), "published").unwrap();
    gateway.state.lock().unwrap().lost_reply = true;
    assert!(first.publish(path.clone()).await.is_err());
    assert_eq!(gateway.state.lock().unwrap().publishes, 1);
    drop(first);
    fs::write(path.join("notes.txt"), "later local edit").unwrap();
    let next = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        false,
        0,
    );
    next.clone().initialize().await;
    assert_eq!(next.describe()["ready"], true);
    assert_eq!(next.describe()["generation"], 2);
    assert_eq!(gateway.state.lock().unwrap().publishes, 1);
    assert_eq!(
        fs::read_to_string(path.join("notes.txt")).unwrap(),
        "later local edit"
    );
}

#[tokio::test]
async fn incomplete_merges_and_missing_or_corrupt_bases_never_adopt_edited_files() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "old").unwrap();
    let gateway = Gateway::new(base(1, "old")).await;
    let first = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    first.clone().initialize().await;
    let next = base(2, "remote");
    let expected = vec![Expected::Write {
        path: "notes.txt".into(),
        hash: sha256_hex(b"merged"),
        size: 6,
        executable: false,
    }];
    first
        .record(state::PENDING, &next, Some("merge"), expected)
        .await
        .unwrap();
    drop(first);
    let paused = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        false,
        0,
    );
    paused.clone().initialize().await;
    assert_eq!(paused.describe()["error"], "sync-recovery");
    assert!(paused.publish(path.clone()).await.is_err());
    assert_eq!(fs::read_to_string(path.join("notes.txt")).unwrap(), "old");
    fs::write(path.join("notes.txt"), "merged").unwrap();
    paused.clone().initialize().await;
    assert_eq!(paused.describe()["ready"], true);
    assert_eq!(paused.describe()["generation"], 2);
    paused
        .store
        .write_state(state::BASE, b"corrupt")
        .await
        .unwrap();
    paused.clone().initialize().await;
    assert_eq!(paused.describe()["error"], "sync-recovery");
    assert_eq!(
        fs::read_to_string(path.join("notes.txt")).unwrap(),
        "merged"
    );
    assert_eq!(gateway.state.lock().unwrap().publishes, 0);
    fs::remove_file(paused.store.state.join(format!(
        "{}.ydoc",
        crate::checkpoint::digest(state::BASE.as_bytes())
    )))
    .unwrap();
    let missing = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    missing.clone().initialize().await;
    assert_eq!(
        missing.describe()["error"],
        "sync-recovery",
        "an initialized binding cannot recapture a deleted base, even with a fresh flag"
    );
    assert_eq!(
        fs::read_to_string(path.join("notes.txt")).unwrap(),
        "merged"
    );
    let new_root = tempfile::tempdir().unwrap();
    fs::write(new_root.path().join("notes.txt"), "unsynced local").unwrap();
    let absent = session(
        store(&new_root.path().into(), &private.path().into()),
        &gateway,
        "first-token",
        false,
        0,
    );
    absent.clone().initialize().await;
    assert_eq!(absent.describe()["error"], "sync-recovery");
}

#[tokio::test]
async fn renewing_an_expired_token_preserves_the_tree_and_keeps_control_private() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "old").unwrap();
    let gateway = Gateway::new(base(1, "old")).await;
    let running = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    running.clone().initialize().await;
    gateway.state.lock().unwrap().token = "renewed-token".into();
    fs::write(path.join("notes.txt"), "local").unwrap();
    assert_eq!(
        running.publish(path.clone()).await.err().unwrap().code,
        "sync-auth"
    );
    assert!(
        running
            .authorize("guess", &gateway.url, &running.workspace, "renewed-token")
            .is_err()
    );
    assert!(
        running
            .authorize(
                "private-control-key",
                &gateway.url,
                "elsewhere",
                "renewed-token"
            )
            .is_err()
    );
    let reply = running
        .authorize(
            "private-control-key",
            &gateway.url,
            &running.workspace,
            "renewed-token",
        )
        .unwrap();
    assert!(
        !reply.to_string().contains("renewed-token")
            && !reply.to_string().contains("private-control-key")
    );
    assert_eq!(running.publish(path).await.unwrap()["generation"], 2);
}

#[tokio::test]
async fn closing_a_request_does_not_release_the_running_publish_lease() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "old").unwrap();
    let gateway = Gateway::new(base(1, "old")).await;
    let running = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    running.clone().initialize().await;
    fs::write(path.join("notes.txt"), "first").unwrap();
    let gate = Arc::new(Gate {
        entered: Default::default(),
        release: Default::default(),
    });
    gateway.state.lock().unwrap().gate = Some(gate.clone());
    let (client, root) = (running.clone(), path.clone());
    let first = tokio::spawn(async move { client.publish(root).await });
    gate.entered.notified().await;
    first.abort();
    let _ = first.await;
    fs::write(path.join("notes.txt"), "second").unwrap();
    let (client, root) = (running.clone(), path.clone());
    let mut second = tokio::spawn(async move { client.publish(root).await });
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(30), &mut second)
            .await
            .is_err()
    );
    gate.release.notify_one();
    assert_eq!(
        tokio::time::timeout(std::time::Duration::from_secs(5), second)
            .await
            .unwrap()
            .unwrap()
            .unwrap()["generation"],
        3
    );
    assert_eq!(gateway.state.lock().unwrap().publishes, 2);
    assert_eq!(
        gateway.state.lock().unwrap().base.texts["notes.txt"],
        b"second"
    );
}

#[tokio::test]
async fn capture_does_not_take_an_edited_working_file_as_the_common_base() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "already edited").unwrap();
    let gateway = Gateway::new(base(1, "original")).await;
    let running = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    running.clone().initialize().await;
    let kept = running.current().await.unwrap();
    assert_eq!(kept.texts["notes.txt"], b"original");
    assert_eq!(
        fs::read_to_string(path.join("notes.txt")).unwrap(),
        "already edited"
    );
}

#[tokio::test]
async fn a_failed_intent_write_cannot_advance_the_cloud_generation() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "old").unwrap();
    let gateway = Gateway::new(base(1, "old")).await;
    let running = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    running.clone().initialize().await;
    let pending = running.store.state.join(format!(
        "{}.ydoc",
        crate::checkpoint::digest(state::PENDING.as_bytes())
    ));
    gateway.state.lock().unwrap().fail_intent = Some(pending);
    fs::write(path.join("notes.txt"), "local").unwrap();
    assert!(running.publish(path.clone()).await.is_err());
    assert_eq!(gateway.state.lock().unwrap().publishes, 0);
    assert_eq!(fs::read_to_string(path.join("notes.txt")).unwrap(), "local");
}

#[tokio::test]
async fn a_changed_initial_generation_pauses_instead_of_offering_an_unsafe_merge() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "local edit").unwrap();
    let gateway = Gateway::new(base(2, "new cloud edit")).await;
    let running = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    running.clone().initialize().await;
    assert_eq!(running.describe()["error"], "sync-recovery");
    assert_eq!(running.describe()["ready"], false);
    assert!(running.publish(path.clone()).await.is_err());
    assert_eq!(
        fs::read_to_string(path.join("notes.txt")).unwrap(),
        "local edit"
    );
    assert_eq!(gateway.state.lock().unwrap().publishes, 0);
}

#[tokio::test]
async fn an_unconfirmed_publish_followed_by_another_writer_requires_reconciliation() {
    let root = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    let path = root.path().to_path_buf();
    fs::write(path.join("notes.txt"), "old").unwrap();
    let gateway = Gateway::new(base(1, "old")).await;
    let first = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        true,
        1,
    );
    first.clone().initialize().await;
    fs::write(path.join("notes.txt"), "ours").unwrap();
    gateway.state.lock().unwrap().lost_reply = true;
    assert!(first.publish(path.clone()).await.is_err());
    gateway.advance("another writer");
    drop(first);
    let recovered = session(
        store(&path, &private.path().into()),
        &gateway,
        "first-token",
        false,
        0,
    );
    recovered.clone().initialize().await;
    assert_eq!(recovered.describe()["error"], "sync-recovery");
    assert!(recovered.publish(path.clone()).await.is_err());
    assert_eq!(gateway.state.lock().unwrap().publishes, 1);
    assert_eq!(fs::read_to_string(path.join("notes.txt")).unwrap(), "ours");
}
