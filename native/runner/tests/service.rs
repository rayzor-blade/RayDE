//! The runner's open, reuse, recovery, isolation and delete flows against an in-memory sandbox backend, so they need no VM.
//! A stand-in program plays the session bridge that runs inside a guest.

use rayde_runner::{Config, LocalRepository, start_with, workspace_id};
use rayde_sandbox::{Capabilities, Labels, SandboxProvider, fake::Fake};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
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
fn guest() -> Fake {
    Fake::new(Capabilities { persistent_volumes: true, ..Default::default() })
        .with_program("/bin/sh", |_, _, _, _| async { 0 })
        .with_program("/opt/rayde-session", |_, command, mut stdin, mut stdout| async move {
            if command.args.first().map(String::as_str) != Some("bridge") {
                return 0;
            }
            let Ok(length) = stdin.read_u32().await else { return 1 };
            let mut hello = vec![0; length as usize];
            if stdin.read_exact(&mut hello).await.is_err() {
                return 1;
            }
            let reply = json!({"id":1,"ok":true,"root":"/workspace/project","privateJournals":1,"cacheIdentity":{"version":1,"authority":"fixture","workspace":"fixture"}});
            let _ = stdout.write_all(&rayde_session::framing::frame(&reply.to_string())).await;
            let mut rest = Vec::new();
            let _ = stdin.read_to_end(&mut rest).await;
            0
        })
}

struct Fixture {
    _temp: tempfile::TempDir,
    fake: Arc<Fake>,
    base: String,
    http: reqwest::Client,
    running: Option<rayde_runner::Running<Fake>>,
}

impl Fixture {
    async fn new(max_workspaces: usize) -> Self {
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
        };
        let fake = Arc::new(guest());
        let running = start_with(config, fake.clone()).await.unwrap();
        let base = format!("http://{}", running.address);
        let http = reqwest::Client::builder().timeout(Duration::from_secs(60)).build().unwrap();
        Self { _temp: temp, fake, base, http, running: Some(running) }
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
