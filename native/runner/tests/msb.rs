//! Explicit real-runtime check; the default suite never creates a VM.
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use rayde_runner::{Config, LocalRepository, start, workspace_id};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use tokio_tungstenite::{connect_async, tungstenite::Message};

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
    async fn connect(connection: &Value) -> Self {
        let (socket, _) = connect_async(connection["url"].as_str().unwrap())
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
            let message = tokio::time::timeout(Duration::from_secs(15), self.socket.next())
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
                assert_eq!(event["code"], 0);
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
    std::fs::write(source.join("src/Main.hx"), "class Main {}\n").unwrap();
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
    let config = Config {
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
    };
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
    assert!(
        a == duplicate,
        "duplicate opens must return the same private connection"
    );
    let (b_status, b) = open(&http, &base, secret, opening(2, 111)).await;
    assert_eq!(b_status, 200);
    assert!(a["token"] != b["token"]);
    let (mut unauthenticated, _) = connect_async(a["url"].as_str().unwrap()).await.unwrap();
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
    let mut first = Peer::connect(&a).await;
    let mut second = Peer::connect(&b).await;
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
        "class Main {}\n"
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
    let mut first = Peer::connect(&retained).await;
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
    assert_eq!(
        open(&http, &base, secret, opening(1, 111)).await.0,
        409,
        "lost compute must not be silently replaced from Git"
    );
    assert_eq!(open(&http, &base, secret, opening(1, 111)).await.0, 409);
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
    assert_eq!(reopened["generation"], 2);
    assert!(reopened["token"] != a["token"]);
    assert_eq!(delete(&http, &base, secret, 1, 111).await, 200);
    assert_eq!(delete(&http, &base, secret, 2, 111).await, 200);
    running.shutdown().await;
}
