use super::*;
use std::process::Command;

fn repository() -> Repository {
    Repository {
        id: 111,
        full_name: "alice/demo".into(),
        branch: "main".into(),
        clone_url: "https://github.com/alice/demo.git".into(),
    }
}
fn request() -> Open {
    Open {
        id: workspace_id(1, 111),
        owner: 1,
        repository: repository(),
        checkout: Checkout {
            access_token: "fixture-access-must-not-persist".into(),
        },
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
