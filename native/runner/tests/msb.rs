//! Explicit real-runtime check; the default suite never creates a VM.
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use rayde_runner::{Config, LocalRepository, start, workspace_id, demo_workspace_id};
use sha2::{Digest,Sha256};
use serde_json::{Value, json};
use yrs::{Doc, ReadTxn, Text, Transact, Update, updates::decoder::Decode};
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use tokio_tungstenite::{connect_async, tungstenite::{Message,client::IntoClientRequest}};

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
struct Cleanup {
    msb: PathBuf,
    state: PathBuf,
}
impl Drop for Cleanup {
    fn drop(&mut self) {
        if let Ok(instance) = std::fs::read_to_string(self.state.join("instance")) {
            let _ = Command::new(&self.msb)
                .env("MSB_BACKEND", "local")
                .args([
                    "remove",
                    "--force",
                    "--label",
                    &format!("rayde.runner={instance}"),
                ])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            if let Ok(list) = Command::new(&self.msb).env("MSB_BACKEND","local").args(["volume","list"]).output() {
                let prefix = format!("rayde-{}-",&instance[..16]);
                for name in String::from_utf8_lossy(&list.stdout).lines().filter_map(|line|line.split_whitespace().next()).filter(|name|name.starts_with(&prefix)) {
                    let _ = Command::new(&self.msb).env("MSB_BACKEND","local").args(["volume","remove",name]).stdout(Stdio::null()).stderr(Stdio::null()).status();
                }
            }
        }
    }
}
type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
struct Peer {
    socket: Socket,
    serial: u64,
    events: Vec<Value>,
}
impl Peer {
    async fn connect(connection: &Value, secret: &str) -> Self {
        let mut request = connection["url"].as_str().unwrap().into_client_request().unwrap();
        request.headers_mut().insert("Authorization",format!("Bearer {secret}").parse().unwrap());
        let (socket, _) = connect_async(request)
            .await
            .unwrap();
        let mut peer = Self {
            socket,
            serial: 0,
            events: Vec::new(),
        };
        let hello = peer
            .rpc("hello", json!({"token":connection["token"]}))
            .await;
        assert_eq!(hello["ok"], true);
        peer
    }
    async fn next(&mut self) -> Value {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(60), self.socket.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            if let Message::Text(text) = message {
                return serde_json::from_str(&text).unwrap();
            }
        }
    }
    async fn rpc(&mut self, op: &str, mut value: Value) -> Value {
        self.serial += 1;
        value["id"] = json!(self.serial);
        value["op"] = json!(op);
        self.socket
            .send(Message::Text(value.to_string().into()))
            .await
            .unwrap();
        loop {
            let response = self.next().await;
            if response["id"] == self.serial {
                return response;
            }
            self.events.push(response);
        }
    }
    async fn output(&mut self, pid: &Value) -> String {
        let mut output = String::new();
        loop {
            let event = if self.events.is_empty() {
                self.next().await
            } else {
                self.events.remove(0)
            };
            if event["pid"] != *pid {
                continue;
            }
            if event["ev"] == "proc.out" {
                output.push_str(&String::from_utf8_lossy(
                    &B64.decode(event["data"].as_str().unwrap()).unwrap(),
                ));
            }
            if event["ev"] == "proc.exit" {
                assert_eq!(event["code"], 0, "{output}");
                return output;
            }
        }
    }
}
fn opening(owner: u64, repository: u64) -> Value {
    json!({"id":workspace_id(owner,repository),"owner":owner,"repository":{"id":repository,"fullName":"alice/demo","branch":"main","cloneUrl":"https://github.com/alice/demo.git"},"checkout":{"accessToken":"checkout-token-must-never-enter-guest"}})
}
async fn open(http: &reqwest::Client, base: &str, secret: &str, body: Value) -> (u16, Value) {
    let response = http
        .post(format!("{base}/workspaces/open"))
        .bearer_auth(secret)
        .json(&body)
        .send()
        .await
        .unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap())
}
async fn delete(
    http: &reqwest::Client,
    base: &str,
    secret: &str,
    owner: u64,
    repository: u64,
) -> u16 {
    http.post(format!("{base}/workspaces/delete"))
        .bearer_auth(secret)
        .json(&json!({"id":workspace_id(owner,repository),"owner":owner}))
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

#[tokio::test]
#[ignore = "requires local MSB/KVM and RAYDE_TEST_SESSION; starts two isolated short-lived Ubuntu guests"]
async fn real_msb_demo_leases_are_isolated_and_expire() {
    let temporary=tempfile::tempdir().unwrap();
    let secret="demo-probe-private-runner-control-credential";
    let secret_file=temporary.path().join("secret");std::fs::write(&secret_file,secret).unwrap();
    #[cfg(unix)] {use std::os::unix::fs::PermissionsExt;std::fs::set_permissions(&secret_file,std::fs::Permissions::from_mode(0o600)).unwrap();}
    let bundle=temporary.path().join("demo.json");
    let sources=json!({"version":1,"root":"/work/pocket-studio","project":"pocket-studio/build.hxml","entries":[
        {"path":"/work/pocket-studio","directory":true,"data":null},
        {"path":"/work/pocket-studio/build.hxml","directory":false,"data":B64.encode("-cp src\n-main Main\n--interp\n")},
        {"path":"/work/pocket-studio/src/Main.hx","directory":false,"data":B64.encode("class Main {static function main(){}}\n")},
        {"path":"/work/pocket-studio/live.txt","directory":false,"data":B64.encode("base")}
    ]});
    let bytes=serde_json::to_vec(&sources).unwrap();std::fs::write(&bundle,&bytes).unwrap();
    let release:String=Sha256::digest(bytes).iter().map(|byte|format!("{byte:02x}")).collect();
    let config:Config=serde_json::from_value(json!({
        "listen":"127.0.0.1:0","stateRoot":temporary.path().join("state"),
        "msb":std::env::var_os("RAYDE_TEST_MSB").map(PathBuf::from).unwrap_or_else(||PathBuf::from(std::env::var_os("HOME").unwrap()).join(".local/bin/msb")),
        "sessionBinary":std::env::var_os("RAYDE_TEST_SESSION").map(PathBuf::from).expect("Set RAYDE_TEST_SESSION"),
        "secretFile":secret_file,"image":"ubuntu:26.04","memoryMib":512,"cpus":1,"maxWorkspaces":2,"maxDurationSeconds":300,
        "demo":{"bundle":bundle,"release":release,"maxWorkspaces":2}
    })).unwrap();
    let _cleanup=Cleanup{msb:config.msb.clone(),state:config.state_root.clone()};
    let running=start(config.clone()).await.unwrap();let base=format!("http://{}",running.address);
    let http=reqwest::Client::builder().timeout(Duration::from_secs(90)).build().unwrap();
    let now=||std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let expires=now()+45;
    let request=|lease:&str|json!({"id":demo_workspace_id(&release,lease),"owner":0,"repository":{"id":0,"fullName":"demo/pocket-studio","demo":{"release":release,"lease":lease,"expires":expires}}});
    let a=request(&"a".repeat(43));let b=request(&"b".repeat(43));
    let (status,left)=open(&http,&base,secret,a.clone()).await;assert_eq!(status,200,"{left}");
    let (status,right)=open(&http,&base,secret,b).await;assert_eq!(status,200,"{right}");
    assert_ne!(left["token"],right["token"]);
    let mut first=Peer::connect(&left,secret).await;let mut second=Peer::connect(&right,secret).await;
    let one=first.rpc("hello",json!({"token":left["token"]})).await;
    let two=second.rpc("hello",json!({"token":right["token"]})).await;
    assert_eq!(one["demoSeed"],json!({"version":1,"release":release}));
    assert_eq!(two["demoSeed"],one["demoSeed"]);
    assert_ne!(one["cacheIdentity"],two["cacheIdentity"],"visitors share a CRDT authority");
    assert_eq!(first.rpc("fs.write",json!({"path":"only-a.txt","data":"private visitor A"})).await["ok"],true);
    assert!(second.rpc("fs.stat",json!({"path":"only-a.txt"})).await["entry"].is_null());
    let opened=first.rpc("doc.open",json!({"path":"live.txt"})).await;
    let graph=Doc::new();let text=graph.get_or_insert_text("text");
    graph.transact_mut().apply_update(Update::decode_v1(&B64.decode(opened["update"].as_str().unwrap()).unwrap()).unwrap()).unwrap();
    let vector=graph.transact().state_vector();text.insert(&mut graph.transact_mut(),4," edited");
    let update=graph.transact().encode_state_as_update_v1(&vector);
    assert_eq!(first.rpc("doc.update",json!({"path":"live.txt","update":B64.encode(update)})).await["ok"],true);
    let untouched=second.rpc("doc.open",json!({"path":"live.txt"})).await;
    assert_ne!(opened["documentId"],untouched["documentId"]);
    assert_eq!(second.rpc("fs.read",json!({"path":"live.txt"})).await["data"],"base");
    drop(first);drop(second);running.shutdown().await;
    let running=start(config.clone()).await.unwrap();let base=format!("http://{}",running.address);
    let (status,reused)=open(&http,&base,secret,a.clone()).await;assert_eq!(status,200,"{reused}");
    assert_eq!(left["token"],reused["token"]);
    let mut resumed=Peer::connect(&reused,secret).await;
    assert_eq!(resumed.rpc("hello",json!({"token":reused["token"]})).await["cacheIdentity"],one["cacheIdentity"]);
    assert_eq!(resumed.rpc("fs.read",json!({"path":"only-a.txt"})).await["data"],"private visitor A");drop(resumed);
    tokio::time::sleep(Duration::from_secs(expires.saturating_sub(now())+1)).await;
    assert_eq!(open(&http,&base,secret,a).await.0,410);
    for _ in 0..200 {
        if std::fs::read_dir(config.state_root.join("records")).unwrap().next().is_none(){break;}
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(std::fs::read_dir(config.state_root.join("records")).unwrap().next().is_none(),"expired lease records were retained");
    running.shutdown().await;
    println!("Demo MSB: separate files/CRDT identities, restart reuse and expiry reclamation passed");
}

#[tokio::test]
#[ignore = "requires local MSB 0.7.11/KVM and RAYDE_TEST_SESSION pointing to a static Linux session binary"]
async fn real_msb_provisioning_reuse_isolation_restart_and_cleanup() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("repository");
    std::fs::create_dir(&source).unwrap();
    git(&source, &["init", "-b", "main"]);
    git(&source, &["config", "user.name", "Fixture"]);
    git(
        &source,
        &["config", "user.email", "fixture@example.invalid"],
    );
    std::fs::write(source.join("build.hxml"), "-cp src\n-main Main\n--interp\n").unwrap();
    std::fs::create_dir(source.join("src")).unwrap();
    std::fs::write(source.join("src/Main.hx"), "class Main { static function main() trace(\"toolchain-ready\"); }\n").unwrap();
    git(&source, &["add", "."]);
    git(&source, &["commit", "-m", "fixture"]);
    let secret = "provisioning-control-credential-for-local-test";
    let secret_file = temp.path().join("secret");
    std::fs::write(&secret_file, secret).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&secret_file, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let mut config = Config {
        listen: ([127, 0, 0, 1], 0).into(),
        state_root: temp.path().join("state"),
        msb: std::env::var_os("RAYDE_TEST_MSB")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap()).join(".local/bin/msb")
            }),
        session_binary: std::env::var_os("RAYDE_TEST_SESSION")
            .map(PathBuf::from)
            .expect("Set RAYDE_TEST_SESSION"),
        secret_file,
        public_url: None,
        image: "alpine:3.23".into(),
        toolchain: None,
        persistent_disks: true,
        demo: None,
        memory_mib: 512,
        cpus: 1,
        max_workspaces: 2,
        max_duration_seconds: 300,
        local_repositories: vec![
            LocalRepository {
                owner: 1,
                repository: 111,
                path: source.clone(),
            },
            LocalRepository {
                owner: 2,
                repository: 111,
                path: source.clone(),
            },
            LocalRepository {
                owner: 1,
                repository: 222,
                path: source,
            },
        ],
        sync_gateway: None,
    };
    if let Some(path) = std::env::var_os("RAYDE_TEST_TOOLCHAIN") {
        config.toolchain = Some(serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap());
        config.memory_mib = 1024;
    }
    let _cleanup = Cleanup {
        msb: config.msb.clone(),
        state: config.state_root.clone(),
    };
    let running = start(config.clone()).await.unwrap();
    let base = format!("http://{}", running.address);
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()
        .unwrap();
    assert_eq!(open(&http, &base, "wrong", opening(1, 111)).await.0, 401);
    let mut wrong = opening(1, 111);
    wrong["owner"] = json!(2);
    assert_eq!(open(&http, &base, secret, wrong).await.0, 400);
    let ((a_status, a), (duplicate_status, duplicate)) = tokio::join!(
        open(&http, &base, secret, opening(1, 111)),
        open(&http, &base, secret, opening(1, 111))
    );
    assert_eq!(a_status, 200);
    assert_eq!(duplicate_status, 200);
    let measured:Value=http.post(format!("{base}/workspaces/metrics")).bearer_auth(secret)
        .json(&json!({"id":workspace_id(1,111),"owner":1})).send().await.unwrap().json().await.unwrap();
    assert_eq!(measured["available"],true);
    assert_eq!(measured["cpuLimit"],1);
    assert_eq!(measured["memoryLimitBytes"],u64::from(config.memory_mib)*1024*1024);
    assert!(measured["cpuPercent"].as_f64().is_some_and(|n|n>=0.));
    assert!(measured["memoryBytes"].as_u64().is_some_and(|n|n>0));
    assert!(measured["storageLimitBytes"].as_u64().is_some_and(|n|n>0 && n<=1024*1024*1024));
    assert!(measured["storageBytes"].as_u64().is_some());
    assert!(measured["uptimeSeconds"].as_f64().is_some());
    assert!(
        a == duplicate,
        "duplicate opens must return the same private connection"
    );
    let (b_status, b) = open(&http, &base, secret, opening(2, 111)).await;
    assert_eq!(b_status, 200);
    assert!(a["token"] != b["token"]);
    assert!(connect_async(a["url"].as_str().unwrap()).await.is_err());
    let mut request = a["url"].as_str().unwrap().into_client_request().unwrap();
    request.headers_mut().insert("Authorization",format!("Bearer {secret}").parse().unwrap());
    let (mut unauthenticated, _) = connect_async(request).await.unwrap();
    unauthenticated
        .send(Message::Text(
            json!({"id":1,"op":"hello","token":"wrong"})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(3), unauthenticated.next())
            .await
            .unwrap(),
        Some(Ok(Message::Close(_))) | None
    ));
    let forbidden = http
        .post(format!("{base}/workspaces/delete"))
        .bearer_auth(secret)
        .json(&json!({"id":workspace_id(1,111),"owner":2}))
        .send()
        .await
        .unwrap();
    assert_eq!(forbidden.status(), 403);
    assert_eq!(open(&http, &base, secret, opening(1, 222)).await.0, 429);
    assert_eq!(delete(&http, &base, secret, 2, 1111).await, 404);
    let mut first = Peer::connect(&a, secret).await;
    let mut second = Peer::connect(&b, secret).await;
    if config.toolchain.is_some() {
        let hello = first.rpc("hello",json!({"token":a["token"]})).await;
        assert_eq!(hello["readRoots"].as_array().unwrap().len(),4);
        assert_eq!(hello["extensions"]["root"],"/opt/rayde/extensions");
        let process = first.rpc("proc.spawn",json!({"command":"python3","args":["-u","-c",include_str!("toolchain.py")]})).await;
        assert_eq!(process["ok"],true);
        assert!(first.output(&process["pid"]).await.contains("toolchain-build-run-lsp-native-extension-ready"));
    }
    assert_eq!(
        first
            .rpc(
                "fs.write",
                json!({"path":"src/Main.hx","data":"changed in the first guest"})
            )
            .await["ok"],
        true
    );
    assert_eq!(
        second.rpc("fs.read", json!({"path":"src/Main.hx"})).await["data"],
        "class Main { static function main() trace(\"toolchain-ready\"); }\n"
    );
    let process = first
        .rpc(
            "proc.spawn",
            json!({"command":"/bin/sh","args":["-c","env; ps w; cat .git/config"]}),
        )
        .await;
    assert_eq!(process["ok"], true);
    let output = first.output(&process["pid"]).await;
    assert!(!output.contains(secret));
    assert!(!output.contains("checkout-token-must-never-enter-guest"));
    assert!(!output.contains(a["token"].as_str().unwrap()));
    assert!(!output.contains("extraheader"));
    assert_eq!(
        first.rpc("hello", json!({"token":a["token"]})).await["ok"],
        true
    );
    let payload = "large frame 🦊\n".repeat(30000);
    assert_eq!(
        first
            .rpc("fs.write", json!({"path":"large.txt","data":payload}))
            .await["ok"],
        true
    );
    let began = first.serial;
    for offset in 1..=20 {
        first.socket.send(Message::Text(json!({"id":began+offset,"op":if offset==1{"fs.read"}else{"fs.stat"},"path":"large.txt"}).to_string().into())).await.unwrap();
    }
    let mut replies = std::collections::BTreeSet::new();
    while replies.len() < 20 {
        let response = first.next().await;
        if let Some(id) = response["id"].as_u64() {
            assert_eq!(response["ok"], true);
            if id == began + 1 {
                assert_eq!(response["data"], payload);
            }
            replies.insert(id);
        } else {
            first.events.push(response);
        }
    }
    assert_eq!(first.rpc("fs.write",json!({"path":"live.txt","data":"base"})).await["ok"],true);
    let opened = first.rpc("doc.open",json!({"path":"live.txt"})).await;
    let shared = Doc::new();
    let text = shared.get_or_insert_text("text");
    shared.transact_mut().apply_update(Update::decode_v1(&B64.decode(opened["update"].as_str().unwrap()).unwrap()).unwrap()).unwrap();
    let vector = shared.transact().state_vector();
    text.insert(&mut shared.transact_mut(),4," live");
    let update = shared.transact().encode_state_as_update_v1(&vector);
    let journal = first.rpc("doc.update",json!({"path":"live.txt","journal":true,"vector":"AA==","update":B64.encode(update)})).await;
    assert_eq!(journal["ok"],true);
    let before_deletion = shared.transact().state_vector();
    text.remove_range(&mut shared.transact_mut(),4,1);
    assert_eq!(before_deletion,shared.transact().state_vector());
    let deleted = shared.transact().encode_state_as_update_v1(&before_deletion);
    let deletion = first.rpc("doc.update",json!({"path":"live.txt","journal":true,"vector":journal["journal"]["vector"],"update":B64.encode(deleted)})).await;
    assert_eq!(deletion["ok"],true);
    first.socket.close(None).await.unwrap();
    second.socket.close(None).await.unwrap();
    drop(first);
    drop(second);
    running.shutdown().await;
    let running = start(config.clone()).await.unwrap();
    let base = format!("http://{}", running.address);
    let (status, retained) = open(&http, &base, secret, opening(1, 111)).await;
    assert_eq!(status, 200);
    assert!(retained["token"] == a["token"]);
    assert_eq!(retained["generation"], 1);
    let mut first = Peer::connect(&retained, secret).await;
    assert_eq!(
        first.rpc("fs.read", json!({"path":"src/Main.hx"})).await["data"],
        "changed in the first guest"
    );
    first.socket.close(None).await.unwrap();
    drop(first);
    let record: Value = serde_json::from_slice(
        &std::fs::read(
            config
                .state_root
                .join("records")
                .join(format!("{}.json", workspace_id(1, 111))),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(
        Command::new(&config.msb)
            .env("MSB_BACKEND", "local")
            .args(["remove", "--force", record["sandbox"].as_str().unwrap()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    let ((status,recovered),(duplicate_status,duplicate)) = tokio::join!(open(&http,&base,secret,opening(1,111)),open(&http,&base,secret,opening(1,111)));
    assert_eq!(status,200,"{}",recovered["message"]);
    assert_eq!(duplicate_status,200);
    assert_eq!(recovered,duplicate);
    assert_eq!(recovered["generation"],2);
    assert_ne!(recovered["token"],a["token"]);
    let mut recovered_peer = Peer::connect(&recovered,secret).await;
    assert_eq!(recovered_peer.rpc("fs.read",json!({"path":"src/Main.hx"})).await["data"],"changed in the first guest");
    assert_eq!(recovered_peer.rpc("fs.read",json!({"path":"large.txt"})).await["data"],payload);
    let restored = recovered_peer.rpc("doc.open",json!({"path":"live.txt"})).await;
    assert_eq!(restored["text"],"baselive");
    assert_eq!(restored["vector"],deletion["journal"]["vector"]);
    let git_result = recovered_peer.rpc("proc.spawn",json!({"command":"/bin/sh","args":["-c","test -f .git/HEAD && test -f .git/index && echo git-preserved"]})).await;
    assert!(recovered_peer.output(&git_result["pid"]).await.contains("git-preserved"));
    recovered_peer.socket.close(None).await.unwrap();
    assert_eq!(delete(&http, &base, secret, 1, 111).await, 200);
    assert_eq!(delete(&http, &base, secret, 1, 111).await, 200);
    #[cfg(unix)]
    {
        let source = &config.local_repositories[0].path;
        std::os::unix::fs::symlink("/etc/passwd", source.join("unsafe-link")).unwrap();
        git(source, &["add", "."]);
        git(source, &["commit", "-m", "unsafe"]);
        assert_eq!(open(&http, &base, secret, opening(1, 222)).await.0, 422);
        git(source, &["rm", "unsafe-link"]);
        git(source, &["commit", "-m", "safe"]);
        assert_eq!(
            open(&http, &base, secret, opening(1, 222)).await.0,
            200,
            "failed checkout releases admission for a safe retry"
        );
        assert_eq!(delete(&http, &base, secret, 1, 222).await, 200);
    }
    let (status, reopened) = open(&http, &base, secret, opening(1, 111)).await;
    assert_eq!(status, 200);
    assert_eq!(reopened["generation"], 3);
    assert!(reopened["token"] != a["token"]);
    assert_eq!(delete(&http, &base, secret, 1, 111).await, 200);
    assert_eq!(delete(&http, &base, secret, 2, 111).await, 200);
    running.shutdown().await;
}
