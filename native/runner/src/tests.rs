use super::*;
use std::process::Command;

fn repository() -> Repository {
    Repository {
        id: 111,
        full_name: "alice/demo".into(),
        branch: "main".into(),
        clone_url: "https://github.com/alice/demo.git".into(),
        sync: None,
    }
}
fn request() -> Open {
    Open {
        id: workspace_id(1, 111),
        owner: 1,
        repository: repository(),
        checkout: Checkout {
            access_token: Some("fixture-access-must-not-persist".into()),
        },
        publish: None,
    }
}

#[test]
fn repository_and_workspace_binding_reject_untrusted_destinations() {
    assert!(valid_id(&workspace_id(1, 111)));
    assert_ne!(workspace_id(1, 111), workspace_id(2, 111));
    assert!(valid_repository(&repository()));
    for url in [
        "file:///etc/passwd",
        "https://evil.test/alice/demo.git",
        "https://github.com/alice/demo.git?token=private",
        "https://token@github.com/alice/demo.git",
    ] {
        let mut repo = repository();
        repo.clone_url = url.into();
        assert!(!valid_repository(&repo));
    }
    for name in [
        "../demo",
        "alice/../demo",
        "alice/demo/extra",
        "alice/;shell",
    ] {
        let mut repo = repository();
        repo.full_name = name.into();
        assert!(!valid_repository(&repo));
    }
    assert!(matches_secret("same", "same"));
    assert!(!matches_secret("same", "different"));
}

fn git(path: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
}
#[tokio::test]
async fn checkout_preserves_git_files_without_filters_or_export_substitution_and_rejects_links() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    std::fs::create_dir(&source).unwrap();
    git(&source, &["init", "-b", "main"]);
    git(&source, &["config", "user.name", "Fixture"]);
    git(
        &source,
        &["config", "user.email", "fixture@example.invalid"],
    );
    std::fs::write(
        source.join(".gitattributes"),
        "hidden.txt export-ignore\nsubstitute.txt export-subst\n*.txt filter=never-run-on-host\n",
    )
    .unwrap();
    std::fs::write(source.join("hidden.txt"), "keep").unwrap();
    std::fs::write(source.join("substitute.txt"), "$Format:%H$").unwrap();
    git(&source, &["add", "."]);
    git(&source, &["commit", "-m", "fixture"]);
    let project = checkout::prepare(
        &temp.path().join("stage"),
        &request(),
        Some(source.clone()),
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read_to_string(project.join("hidden.txt")).unwrap(),
        "keep"
    );
    assert_eq!(
        std::fs::read_to_string(project.join("substitute.txt")).unwrap(),
        "$Format:%H$"
    );
    let config = std::fs::read_to_string(project.join(".git/config")).unwrap();
    assert!(!config.contains("fixture-access-must-not-persist"));
    assert!(!config.contains("extraheader"));
    assert!(config.contains("https://github.com/alice/demo.git"));
    git(&project, &["diff", "--exit-code"]);
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("/etc/passwd", source.join("unsafe-link")).unwrap();
        git(&source, &["add", "."]);
        git(&source, &["commit", "-m", "link"]);
        assert!(
            checkout::prepare(&temp.path().join("reject"), &request(), Some(source), None)
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn registry_is_exclusive_private_and_does_not_reset_corrupt_state() {
    let temp = tempfile::tempdir().unwrap();
    let registry = registry::Registry::load(temp.path()).await.unwrap();
    assert!(registry::Registry::load(temp.path()).await.is_err());
    let record = registry::Record {
        version: 1,
        id: workspace_id(1, 111),
        owner: 1,
        repository: repository(),
        sandbox: format!(
            "rayde-{}-{}-1",
            &registry.instance[..16],
            workspace_id(1, 111)
        ),
        token: random(),
        phase: "ready".into(),
        generation: 1,
        project: Some("build.hxml".into()),
        identity: Some(
            serde_json::json!({"version":1,"authority":"a","workspace":"w","principal":"token"}),
        ),
        toolchain: None,
        storage: None,
        recovery_attempts: Vec::new(),
    };
    registry.save(&record).await.unwrap();
    let cell = registry::Cell::new(record.clone());
    let work = registry.work(&cell).unwrap();
    assert!(registry.work(&cell).is_err());
    drop(registry);
    assert!(registry::Registry::load(temp.path()).await.is_err());
    drop(work);
    let registry = registry::Registry::load(temp.path()).await.unwrap();
    let records = registry.records.lock().await;
    assert_eq!(records.len(), 1);
    assert!(matches_secret(
        &records[&record.id].record.lock().await.token,
        &record.token
    ));
    drop(records);
    drop(registry);
    let path = temp
        .path()
        .join("records")
        .join(format!("{}.json", record.id));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    std::fs::write(&path, b"incomplete").unwrap();
    assert!(registry::Registry::load(temp.path()).await.is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"incomplete");
}

#[tokio::test]
async fn process_output_and_lifetime_are_bounded() {
    let mut process = tokio::process::Command::new("/bin/sh");
    process.args(["-c", "head -c 70000 /dev/zero"]);
    assert!(command::capture(process, 1).await.is_err());
    let mut process = tokio::process::Command::new("/bin/sh");
    process.args(["-c", "sleep 60"]);
    let began = std::time::Instant::now();
    assert!(command::capture(process, 1).await.is_err());
    assert!(began.elapsed() < std::time::Duration::from_secs(3));
}

#[test]
fn toolchain_selectors_and_persistent_disk_bindings_are_operator_scoped() {
    let value = serde_json::json!({"listen":"127.0.0.1:9791","stateRoot":"/state","msb":"/bin/msb","sessionBinary":"/bin/session","secretFile":"/private/secret","toolchain":{"snapshot":"rayde-toolchains:linux-x86_64","digest":"a".repeat(64)}});
    let config:Config = serde_json::from_value(value.clone()).unwrap();
    assert!(config.validate().is_ok());
    assert!(!toolchain::session_args(&config).contains(&"--preview-tools"));
    let mut previews=value.clone();previews["toolchain"]["appPreviews"]=serde_json::json!(true);
    assert!(toolchain::session_args(&serde_json::from_value(previews).unwrap()).windows(2).any(|pair|pair==["--preview-tools","/opt/rayde/preview"]));
    for selector in ["--help","../other","/private/image","group:one two",""] {
        let mut invalid = value.clone(); invalid["toolchain"]["snapshot"] = serde_json::json!(selector);
        assert!(serde_json::from_value::<Config>(invalid).unwrap().validate().is_err());
    }
    let instance = "b".repeat(64);
    let id = workspace_id(1,111);
    let storage = volumes::Storage::new(&instance,&id);
    assert!(storage.valid(&instance,&id));
    assert!(!storage.valid(&"c".repeat(64),&id));
    assert!(!storage.valid(&instance,&workspace_id(2,111)));
}

fn sync_request(id: &str) -> Open {
    Open {
        id: id.into(),
        owner: 1,
        repository: Repository { id: 0, full_name: format!("sync/{id}"), branch: String::new(), clone_url: String::new(), sync: Some(SyncRef { workspace: id.into() }) },
        checkout: Checkout::default(),
        publish: None,
    }
}

#[test]
fn a_synced_workspace_is_bound_to_its_own_id() {
    let id = rayde_sync::ids::WorkspaceId::from_random(&[7; 32]);
    let id = id.as_str();
    assert!(binds(1, id, &sync_request(id).repository));
    assert!(!binds(1, &workspace_id(1, 111), &sync_request(id).repository), "another workspace's id does not bind it");
    let mut other = sync_request(id).repository;
    other.full_name = "sync/elsewhere".into();
    assert!(!binds(1, id, &other));
    other = sync_request(id).repository;
    other.id = 5;
    assert!(!binds(1, id, &other));
    assert!(binds(1, &workspace_id(1, 111), &repository()), "a GitHub workspace binds as before");
}

struct Gateway {
    url: String,
    corrupt: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

/// A stand-in for the sync gateway's runner routes, serving one scanned snapshot.
async fn gateway(snapshot: rayde_sync::scan::Snapshot, secret: &'static str) -> Gateway {
    use axum::{Router, extract::{Path as Param, State}, http::{HeaderMap, StatusCode as Status}, routing::get};
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
    struct Held {
        snapshot: rayde_sync::scan::Snapshot,
        corrupt: Arc<AtomicBool>,
    }
    fn allowed(headers: &HeaderMap, secret: &str) -> bool {
        headers.get("authorization").and_then(|value| value.to_str().ok()) == Some(&format!("Bearer {secret}"))
    }
    let corrupt = Arc::new(AtomicBool::new(false));
    let held = Arc::new(Held { snapshot, corrupt: corrupt.clone() });
    let manifest = move |State(held): State<Arc<Held>>, headers: HeaderMap, Param(_id): Param<String>| async move {
        if !allowed(&headers, secret) { return Err(Status::FORBIDDEN); }
        Ok(held.snapshot.manifest.to_bytes())
    };
    let chunk = move |State(held): State<Arc<Held>>, headers: HeaderMap, Param((_id, hash)): Param<(String, String)>| async move {
        if !allowed(&headers, secret) { return Err(Status::FORBIDDEN); }
        let mut bytes = held.snapshot.read_chunk(&hash).map_err(|_| Status::NOT_FOUND)?;
        if held.corrupt.load(Ordering::SeqCst) { bytes[0] ^= 1; }
        Ok(bytes)
    };
    let app = Router::new().route("/api/sync/runner/:id/manifest", get(manifest)).route("/api/sync/runner/:id/chunks/:hash", get(chunk)).with_state(held);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Gateway { url, corrupt }
}

#[tokio::test]
async fn a_snapshot_is_restored_from_the_gateway_and_a_bad_chunk_is_refused() {
    use rayde_sync::{exclude::Selection, ids::WorkspaceId, lifecycle::Limits, scan::{Options, scan}};
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    std::fs::create_dir_all(source.join("src")).unwrap();
    std::fs::write(source.join("build.hxml"), "-main Main\n").unwrap();
    std::fs::write(source.join("src/Main.hx"), "class Main { static function main() {} }\n").unwrap();
    std::fs::write(source.join("run.sh"), "#!/bin/sh\necho hi\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(source.join("run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    git(&source, &["init", "-q", "-b", "main"]);
    git(&source, &["add", "-A"]);
    git(&source, &["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first"]);
    let id = WorkspaceId::from_random(&[9; 32]);
    let snapshot = scan(&source, &Options { workspace: id.clone(), base_generation: 0, device: "test".into(), now_ms: 1, limits: Limits::default(), selection: Selection::default(), history: false, buffers: vec![] }).unwrap();
    let gateway = gateway(snapshot, "gateway-secret-for-the-test").await;
    let config: Config = serde_json::from_value(serde_json::json!({
        "listen": "127.0.0.1:0", "stateRoot": temp.path(), "msb": "/bin/true", "sessionBinary": "/bin/true", "secretFile": temp.path().join("secret"),
        "syncGateway": {"url": gateway.url, "secret": "gateway-secret-for-the-test"}
    })).unwrap();
    let http = reqwest::Client::new();
    let (project, generation) = restore::restore(&config, &http, &temp.path().join("restored"), &sync_request(id.as_str())).await.unwrap_or_else(|failure| panic!("restore failed: {}", failure.1));
    assert_eq!(generation, 1, "the restore says which generation it is a copy of");
    assert_eq!(std::fs::read_to_string(project.join("build.hxml")).unwrap(), "-main Main\n");
    assert_eq!(std::fs::read_to_string(project.join("src/Main.hx")).unwrap(), "class Main { static function main() {} }\n");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(project.join("run.sh")).unwrap().permissions().mode() & 0o111, 0o111, "the executable bit survives");
        assert_eq!(std::fs::metadata(project.join("build.hxml")).unwrap().permissions().mode() & 0o111, 0, "other files are not executable");
    }
    assert!(!project.join(".git").exists(), "no Git directory is restored");
    gateway.corrupt.store(true, std::sync::atomic::Ordering::SeqCst);
    let refused = restore::restore(&config, &http, &temp.path().join("tampered"), &sync_request(id.as_str())).await;
    assert!(matches!(refused, Err(Failure(StatusCode::UNPROCESSABLE_ENTITY, _))), "a chunk that fails its hash stops the restore");
    let wrong = restore::restore(&config, &http, &temp.path().join("wrong"), &sync_request(WorkspaceId::from_random(&[3; 32]).as_str())).await;
    assert!(wrong.is_err(), "a snapshot of another workspace is not restored under this id");
}

#[test]
fn metrics_reject_another_guest_and_preserve_unknown_measurements() {
    let sample=br#"{"name":"own-guest","state":"running","cpu_percent":2.5,"memory_bytes":1234,"uptime_secs":12.25,"memory_host_resident_bytes":999999}"#;
    let usage=crate::msb::parse_metrics(sample,"own-guest").unwrap();
    assert_eq!(usage.cpu_percent,Some(2.5));assert_eq!(usage.memory_bytes,Some(1234));assert_eq!(usage.uptime_seconds,Some(12.25));
    assert!(crate::msb::parse_metrics(sample,"someone-else").is_err());
    let unknown=crate::msb::parse_metrics(br#"{"name":"own-guest","state":"running","cpu_percent":-1,"memory_bytes":null}"#,"own-guest").unwrap();
    assert!(unknown.cpu_percent.is_none() && unknown.memory_bytes.is_none());
}
