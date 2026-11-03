//! The runner's open, reuse, recovery, isolation and delete flows against an in-memory sandbox backend, so they need no VM.
//! A stand-in program plays the session bridge that runs inside a guest.

use rayde_runner::{Config, LocalRepository, SyncGateway, start_with, workspace_id};
use rayde_sandbox::{Capabilities, Labels, SandboxProvider, fake::Fake};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc,Mutex},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const SECRET: &str = "provisioning-control-credential-for-local-test";


fn git(root: &Path, args: &[&str]) {
    assert!(
        Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    );
}

/// What a guest runs: a shell that accepts the volume identity check, and a session bridge that answers the hello frame.
fn guest(controls:Arc<Mutex<Vec<Value>>>) -> Fake {
    Fake::new(Capabilities { persistent_volumes: true, network_allowlist: true, ..Default::default() })
        .with_program("/bin/sh", |_, _, _, _| async { 0 })
        .with_program("/opt/rayde-session", move |_, command, mut stdin, mut stdout| {let controls=controls.clone();async move {
            if command.args.first().map(String::as_str) != Some("bridge") {
                return 0;
            }
            let Ok(length) = stdin.read_u32().await else { return 1 };
            let mut hello = vec![0; length as usize];
            if stdin.read_exact(&mut hello).await.is_err() {
                return 1;
            }
            let reply = json!({"id":1,"ok":true,"root":"/workspace/project","privateJournals":1,"cacheIdentity":{"version":1,"authority":"fixture","workspace":"fixture"}});
            let event=json!({"ev":"sync.status","syncWriteback":{"workspace":"fixture","ready":true}});
            let _ = stdout.write_all(&rayde_session::framing::frame(&event.to_string())).await;
            let _ = stdout.write_all(&rayde_session::framing::frame(&reply.to_string())).await;
            while let Ok(length)=stdin.read_u32().await {
                let mut bytes=vec![0;length as usize];if stdin.read_exact(&mut bytes).await.is_err(){return 1;}
                let request:Value=serde_json::from_slice(&bytes).unwrap();
                assert_eq!(request["op"],"sync.authorize");controls.lock().unwrap().push(request.clone());
                stdout.write_all(&rayde_session::framing::frame(&json!({"id":request["id"],"ok":true}).to_string())).await.unwrap();
            }
            0
        }})
}

struct Fixture {
    _temp: tempfile::TempDir,
    fake: Arc<Fake>,
    base: String,
    http: reqwest::Client,
    running: Option<rayde_runner::Running<Fake>>,
    controls:Arc<Mutex<Vec<Value>>>,
    config: Config,
}

impl Fixture {
    async fn new(max_workspaces: usize) -> Self {
        Self::with_gateway(max_workspaces, None).await
    }

    async fn with_gateway(max_workspaces: usize, sync_gateway: Option<SyncGateway>) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("repository");
        std::fs::create_dir(&source).unwrap();
        git(&source, &["init", "-b", "main"]);
        git(&source, &["config", "user.name", "Fixture"]);
        git(&source, &["config", "user.email", "fixture@example.invalid"]);
        std::fs::write(source.join("build.hxml"), "-cp src\n-main Main\n--interp\n").unwrap();
        std::fs::create_dir(source.join("src")).unwrap();
        std::fs::write(source.join("src/Main.hx"), "class Main { static function main() trace(1); }\n").unwrap();
        git(&source, &["add", "."]);
        git(&source, &["commit", "-m", "fixture"]);
        let secret_file = temp.path().join("secret");
        std::fs::write(&secret_file, SECRET).unwrap();
        let session = temp.path().join("rayde-session");
        std::fs::write(&session, b"\x7fELF fixture: the fake backend never runs it\n").unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&secret_file, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let local = |owner, repository| LocalRepository { owner, repository, path: source.clone() };
        let config = Config {
            listen: ([127, 0, 0, 1], 0).into(),
            state_root: temp.path().join("state"),
            msb: PathBuf::from("/nonexistent/msb"),
            session_binary: session,
            secret_file,
            public_url: None,
            image: "alpine:3.23".into(),
            toolchain: None,
            persistent_disks: true,
            memory_mib: 512,
            cpus: 1,
            max_workspaces,
            max_duration_seconds: 300,
            local_repositories: vec![local(1, 111), local(2, 111), local(1, 222)],
            sync_gateway,
        };
        let controls=Arc::new(Mutex::new(vec![]));
        let fake = Arc::new(guest(controls.clone()));
        let running = start_with(config.clone(), fake.clone()).await.unwrap();
        let base = format!("http://{}", running.address);
        let http = reqwest::Client::builder().timeout(Duration::from_secs(60)).build().unwrap();
        Self { _temp: temp, fake, base, http, running: Some(running),controls,config }
    }

    async fn open(&self, owner: u64, repository: u64) -> (u16, Value) {
        let body = json!({"id":workspace_id(owner,repository),"owner":owner,"repository":{"id":repository,"fullName":"alice/demo","branch":"main","cloneUrl":"https://github.com/alice/demo.git"},"checkout":{"accessToken":"checkout-token-must-never-enter-guest"}});
        let response = self.http.post(format!("{}/workspaces/open", self.base)).bearer_auth(SECRET).json(&body).send().await.unwrap();
        let status = response.status().as_u16();
        (status, response.json().await.unwrap_or(Value::Null))
    }

    async fn delete(&self, owner: u64, repository: u64) -> u16 {
        self.http
            .post(format!("{}/workspaces/delete", self.base))
            .bearer_auth(SECRET)
            .json(&json!({"id":workspace_id(owner,repository),"owner":owner}))
            .send()
            .await
            .unwrap()
            .status()
            .as_u16()
    }

    async fn sandboxes(&self) -> Vec<String> {
        self.fake.list(&Labels::new()).await.unwrap().into_iter().map(|info| info.name).collect()
    }

    /// The volume names a sandbox mounts: its name without the generation, then `-work` and `-state`.
    fn volumes(sandbox: &str) -> [String; 2] {
        let prefix = sandbox.rsplit_once('-').unwrap().0;
        [format!("{prefix}-work"), format!("{prefix}-state")]
    }

    async fn volume_exists(&self, name: &str) -> bool {
        self.fake.volume(name).await.unwrap().is_some()
    }

    async fn stop(mut self) {
        if let Some(running) = self.running.take() {
            running.shutdown().await;
        }
    }

    async fn restart(&mut self) {
        self.running.take().unwrap().shutdown().await;
        let running=start_with(self.config.clone(),self.fake.clone()).await.unwrap();
        self.base=format!("http://{}",running.address);
        self.running=Some(running);
    }
}

#[tokio::test]
async fn opening_a_workspace_creates_one_labelled_sandbox_with_its_own_volumes() {
    let fixture = Fixture::new(2).await;
    let (status, connection) = fixture.open(1, 111).await;
    assert_eq!(status, 200, "{connection}");
    assert_eq!(connection["project"], "build.hxml");
    assert!(connection["token"].as_str().is_some_and(|token| token.len() >= 32));
    let names = fixture.sandboxes().await;
    assert_eq!(names.len(), 1, "{names:?}");
    let info = fixture.fake.get(&names[0]).await.unwrap().unwrap();
    assert_eq!(info.labels.get("rayde.workspace"), Some(&workspace_id(1, 111)));
    assert!(info.labels.contains_key("rayde.runner"));
    for volume in Fixture::volumes(&names[0]) {
        assert!(fixture.volume_exists(&volume).await, "{volume}");
    }
    fixture.stop().await;
}

#[tokio::test]
async fn opening_again_reuses_the_sandbox_and_returns_the_same_connection() {
    let fixture = Fixture::new(2).await;
    let (_, first) = fixture.open(1, 111).await;
    let (status, second) = fixture.open(1, 111).await;
    assert_eq!(status, 200);
    assert_eq!(first["token"], second["token"]);
    assert_eq!(first["generation"], second["generation"]);
    assert_eq!(fixture.sandboxes().await.len(), 1);
    fixture.stop().await;
}

#[tokio::test]
async fn a_lost_sandbox_is_recovered_onto_the_same_volumes_with_a_new_generation() {
    let fixture = Fixture::new(2).await;
    let (_, first) = fixture.open(1, 111).await;
    let old = fixture.sandboxes().await.remove(0);
    fixture.fake.remove(&old).await.unwrap();
    let (status, second) = fixture.open(1, 111).await;
    assert_eq!(status, 200, "{second}");
    assert_eq!(second["generation"], json!(first["generation"].as_u64().unwrap() + 1));
    assert!(first["token"] != second["token"], "a recovered session gets a new private token");
    let names = fixture.sandboxes().await;
    assert_eq!(names.len(), 1);
    assert!(names[0] != old);
    assert_eq!(Fixture::volumes(&names[0]), Fixture::volumes(&old), "recovery must reuse the workspace's own disks");
    fixture.stop().await;
}

#[tokio::test]
async fn recovery_never_starts_on_empty_disks_when_a_volume_is_gone() {
    let fixture = Fixture::new(2).await;
    fixture.open(1, 111).await;
    let old = fixture.sandboxes().await.remove(0);
    fixture.fake.remove(&old).await.unwrap();
    let volumes = Fixture::volumes(&old);
    fixture.fake.remove_volume(&volumes[0]).await.unwrap();
    let (status, _) = fixture.open(1, 111).await;
    assert_ne!(status, 200, "a workspace whose disk is gone must not reopen");
    assert!(fixture.sandboxes().await.is_empty(), "no sandbox may be created without its disks");
    assert!(!fixture.volume_exists(&volumes[0]).await, "recovery must not create a fresh empty workspace disk");
    fixture.stop().await;
}

#[tokio::test]
async fn workspaces_are_isolated_and_deleting_one_leaves_the_other() {
    let fixture = Fixture::new(2).await;
    assert_eq!(fixture.open(1, 111).await.0, 200);
    assert_eq!(fixture.open(2, 111).await.0, 200);
    let names = fixture.sandboxes().await;
    assert_eq!(names.len(), 2);
    let (a, b) = (names[0].clone(), names[1].clone());
    assert!(Fixture::volumes(&a)[0] != Fixture::volumes(&b)[0]);
    assert_eq!(fixture.delete(1, 111).await, 200);
    let left = fixture.sandboxes().await;
    assert_eq!(left.len(), 1);
    let (gone, kept) = if left[0] == a { (b, a) } else { (a, b) };
    for volume in Fixture::volumes(&gone) {
        assert!(!fixture.volume_exists(&volume).await, "{volume} must be removed with its workspace");
    }
    for volume in Fixture::volumes(&kept) {
        assert!(fixture.volume_exists(&volume).await, "{volume} belongs to the other workspace");
    }
    fixture.stop().await;
}

#[tokio::test]
async fn the_workspace_limit_is_enforced() {
    let fixture = Fixture::new(2).await;
    assert_eq!(fixture.open(1, 111).await.0, 200);
    assert_eq!(fixture.open(2, 111).await.0, 200);
    assert_eq!(fixture.open(1, 222).await.0, 429);
    fixture.stop().await;
}

const GATEWAY_SECRET: &str = "gateway-credential-for-the-local-test";

/// A stand-in for the sync gateway's runner routes serving one scanned folder.
async fn serve_snapshot(folder: &Path, id: &rayde_sync::ids::WorkspaceId) -> String {
    use axum::{Router, extract::{Path as Param, State}, http::{HeaderMap, StatusCode}, routing::get};
    use rayde_sync::{exclude::Selection, lifecycle::Limits, scan::{Options, Snapshot, scan}};
    let snapshot: Arc<Snapshot> = Arc::new(scan(folder, &Options { workspace: id.clone(), base_generation: 0, device: "test".into(), now_ms: 1, limits: Limits::default(), selection: Selection::default(), history: false, buffers: vec![] }).unwrap());
    fn allowed(headers: &HeaderMap) -> bool {
        headers.get("authorization").and_then(|value| value.to_str().ok()) == Some(&format!("Bearer {GATEWAY_SECRET}"))
    }
    let app = Router::new()
        .route("/api/sync/runner/:id/manifest", get(|State(snapshot): State<Arc<Snapshot>>, headers: HeaderMap, Param(_): Param<String>| async move {
            if allowed(&headers) { Ok(snapshot.manifest.to_bytes()) } else { Err(StatusCode::FORBIDDEN) }
        }))
        .route("/api/sync/runner/:id/chunks/:hash", get(|State(snapshot): State<Arc<Snapshot>>, headers: HeaderMap, Param((_, hash)): Param<(String, String)>| async move {
            if !allowed(&headers) { return Err(StatusCode::FORBIDDEN); }
            snapshot.read_chunk(&hash).map_err(|_| StatusCode::NOT_FOUND)
        }))
        .with_state(snapshot);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    url
}

fn sync_body(id: &str) -> Value {
    json!({"id":id,"owner":1,"repository":{"id":0,"name":"synced","fullName":format!("sync/{id}"),"private":true,"sync":{"workspace":id,"generation":1,"opened":1}},"checkout":{"accessToken":null}})
}

#[tokio::test]
async fn a_synced_workspace_is_restored_from_the_gateway_and_opens_like_any_other() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    std::fs::create_dir_all(folder.join("src")).unwrap();
    std::fs::write(folder.join("build.hxml"), "-cp src\n-main Main\n--interp\n").unwrap();
    std::fs::write(folder.join("src/Main.hx"), "class Main { static function main() trace(1); }\n").unwrap();
    git(&folder, &["init", "-b", "main"]);
    git(&folder, &["config", "user.name", "Fixture"]);
    git(&folder, &["config", "user.email", "fixture@example.invalid"]);
    git(&folder, &["add", "."]);
    git(&folder, &["commit", "-m", "fixture"]);
    let id = rayde_sync::ids::WorkspaceId::from_random(&[4; 32]);
    let url = serve_snapshot(&folder, &id).await;

    let guest_url = "https://sync.example.test:9443";
    let mut fixture = Fixture::with_gateway(2, Some(SyncGateway { url: url.clone(), secret: GATEWAY_SECRET.into(), guest_url: Some(guest_url.into()) })).await;
    let mut body = sync_body(id.as_str());
    body["publish"] = json!({"token": "rsp1.capability-for-the-test", "workspace": id.as_str()});
    let post = |body: &Value| fixture.http.post(format!("{}/workspaces/open", fixture.base)).bearer_auth(SECRET).json(body).send();
    let response = post(&body).await.unwrap();
    let status = response.status().as_u16();
    let connection: Value = response.json().await.unwrap_or(Value::Null);
    assert_eq!(status, 200, "{connection}");
    assert_eq!(connection["project"], "build.hxml", "the restored folder is the project");
    assert_eq!(fixture.sandboxes().await.len(), 1);
    let sandbox = fixture.sandboxes().await.pop().unwrap();
    assert_eq!(fixture.fake.spec(&sandbox).unwrap().network, rayde_sandbox::Network::Allow(vec!["sync.example.test".into()]));
    let launched = fixture.fake.detached().into_iter().find(|(_, command)| command.program == "/opt/rayde-session").expect("the session was launched").1.env;
    assert_eq!(launched.get("RAYDE_SYNC_TOKEN").map(String::as_str), Some("rsp1.capability-for-the-test"));
    assert_eq!(launched.get("RAYDE_SYNC_GATEWAY").map(String::as_str), Some(guest_url));
    assert_eq!(launched.get("RAYDE_SYNC_GENERATION").map(String::as_str), Some("1"), "the generation the snapshot was restored from");
    assert_eq!(launched.get("RAYDE_SYNC_FRESH").map(String::as_str),Some("1"));
    let control=launched["RAYDE_SYNC_CONTROL"].clone();assert_eq!(control.len(),64);
    assert!(!connection.to_string().contains(&control));
    {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::{connect_async, tungstenite::{client::IntoClientRequest, Message}};
        let mut request=format!("{}/workspaces/{id}/session",fixture.base.replace("http:","ws:")).into_client_request().unwrap();
        request.headers_mut().insert("Authorization",format!("Bearer {SECRET}").parse().unwrap());
        let (mut socket,_)=connect_async(request).await.unwrap();
        socket.send(Message::Text(json!({"id":1,"op":"hello","token":connection["token"]}).to_string().into())).await.unwrap();
        let event=socket.next().await.unwrap().unwrap();
        assert_eq!(serde_json::from_str::<Value>(event.to_text().unwrap()).unwrap()["ev"],"sync.status");
        let hello=socket.next().await.unwrap().unwrap();
        assert_eq!(serde_json::from_str::<Value>(hello.to_text().unwrap()).unwrap()["ok"],true);
        socket.send(Message::Text(json!({"id":2,"op":"sync.authorize","control":control,"token":"not-a-runner-grant"}).to_string().into())).await.unwrap();
        let refused=socket.next().await.unwrap().unwrap();
        assert_eq!(serde_json::from_str::<Value>(refused.to_text().unwrap()).unwrap()["code"],"forbidden");
        assert!(fixture.controls.lock().unwrap().is_empty());
        socket.close(None).await.unwrap();
    }
    // A capability for some other workspace is refused.
    let mut foreign = body.clone();
    foreign["publish"]["workspace"] = json!(rayde_sync::ids::WorkspaceId::from_random(&[8; 32]).as_str());
    assert_eq!(post(&foreign).await.unwrap().status().as_u16(), 400);
    // Reopening a live workspace renews access without replacing its files.
    body["publish"]["token"]=json!("rsp1.renewed-capability-for-the-test");
    assert_eq!(post(&body).await.unwrap().status().as_u16(), 200);
    assert_eq!(fixture.controls.lock().unwrap().last().unwrap()["token"],body["publish"]["token"]);
    assert_eq!(fixture.controls.lock().unwrap().last().unwrap()["control"],control);
    assert_eq!(fixture.sandboxes().await.len(), 1);
    let sandbox = fixture.sandboxes().await.pop().unwrap();
    assert_eq!(fixture.fake.spec(&sandbox).unwrap().network, rayde_sandbox::Network::Allow(vec!["sync.example.test".into()]));
    fixture.fake.remove(&sandbox).await.unwrap();
    let recovered=post(&body).await.unwrap();assert_eq!(recovered.status().as_u16(),200);
    let relaunched=fixture.fake.detached().into_iter().filter(|(_,command)|command.program=="/opt/rayde-session").last().unwrap().1.env;
    assert_eq!(relaunched["RAYDE_SYNC_FRESH"],"0");assert_eq!(relaunched["RAYDE_SYNC_GENERATION"],"0");
    assert_eq!(relaunched["RAYDE_SYNC_TOKEN"],"rsp1.renewed-capability-for-the-test");
    assert_ne!(relaunched["RAYDE_SYNC_CONTROL"],control);
    let records=fixture._temp.path().join("state/records");
    for file in std::fs::read_dir(records).unwrap(){let value=std::fs::read_to_string(file.unwrap().path()).unwrap();assert!(!value.contains("capability-for-the-test")&&!value.contains(&control));}
    // The workspace is named by its own id: another id with the same repository block is refused.
    let mut wrong = body.clone();
    wrong["id"] = json!(workspace_id(1, 111));
    assert_eq!(post(&wrong).await.unwrap().status().as_u16(), 400);
    let before=fixture.fake.detached().len();
    fixture.restart().await;
    body["publish"]["token"]=json!("rsp1.after-runner-restart");
    let reopened=fixture.http.post(format!("{}/workspaces/open",fixture.base)).bearer_auth(SECRET).json(&body).send().await.unwrap();
    assert_eq!(reopened.status().as_u16(),200);
    assert_eq!(fixture.fake.detached().len(),before,"runner restart reuses the live guest");
    let controls=fixture.controls.lock().unwrap();
    assert_eq!(controls.last().unwrap()["token"],"rsp1.after-runner-restart");
    assert_eq!(controls.last().unwrap()["control"],relaunched["RAYDE_SYNC_CONTROL"]);
    drop(controls);
    fixture.stop().await;
}

#[tokio::test]
async fn a_loopback_gateway_is_refused_before_any_guest_is_created() {
    let fixture = Fixture::with_gateway(2, Some(SyncGateway { url: "http://127.0.0.1:9792".into(), secret: GATEWAY_SECRET.into(), guest_url: None })).await;
    let id = rayde_sync::ids::WorkspaceId::from_random(&[6; 32]);
    let response = fixture.http.post(format!("{}/workspaces/open", fixture.base)).bearer_auth(SECRET).json(&sync_body(id.as_str())).send().await.unwrap();
    assert_eq!(response.status().as_u16(), 400);
    assert!(response.json::<Value>().await.unwrap()["message"].as_str().unwrap().contains("guestUrl"));
    assert!(fixture.sandboxes().await.is_empty());
    assert_eq!(fixture.open(1, 111).await.0, 200, "ordinary Git workspaces do not need gateway egress");
    let sandbox = fixture.sandboxes().await.pop().unwrap();
    assert_eq!(fixture.fake.spec(&sandbox).unwrap().network, rayde_sandbox::Network::None);
    fixture.stop().await;
}

#[tokio::test]
async fn a_synced_workspace_cannot_open_on_a_runner_with_no_gateway() {
    let fixture = Fixture::new(2).await;
    let id = rayde_sync::ids::WorkspaceId::from_random(&[5; 32]);
    let response = fixture.http.post(format!("{}/workspaces/open", fixture.base)).bearer_auth(SECRET).json(&sync_body(id.as_str())).send().await.unwrap();
    assert_eq!(response.status().as_u16(), 503);
    assert!(fixture.sandboxes().await.is_empty());
    fixture.stop().await;
}

#[tokio::test]
async fn metrics_need_private_authority_and_workspace_ownership() {
    let mut fixture=Fixture::new(1).await;
    assert_eq!(fixture.open(1,111).await.0,200);
    let body=json!({"id":workspace_id(1,111),"owner":1});
    let url=format!("{}/workspaces/metrics",fixture.base);
    assert_eq!(fixture.http.post(&url).json(&body).send().await.unwrap().status(),401);
    let denied=fixture.http.post(&url).bearer_auth(SECRET).json(&json!({"id":body["id"],"owner":2})).send().await.unwrap();
    assert_eq!(denied.status(),403);
    let response=fixture.http.post(&url).bearer_auth(SECRET).json(&body).send().await.unwrap();
    assert_eq!(response.status(),200);assert_eq!(response.headers()["cache-control"],"no-store");
    let usage:Value=response.json().await.unwrap();
    assert_eq!(usage["available"],false);assert_eq!(usage["cpuLimit"],1);assert_eq!(usage["memoryLimitBytes"],512*1024*1024);assert_eq!(usage["durationLimitSeconds"],300);
    assert!(usage["memoryBytes"].is_null());assert!(usage["cpuPercent"].is_null());
    assert!(!usage.to_string().contains("sandbox") && !usage.to_string().contains(SECRET));
    fixture.running.take().unwrap().shutdown().await;
}
