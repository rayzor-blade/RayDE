mod support;
use rayde_session::{
    auth::{Identity, SignedCredentials},
    docs::MAX_DOCUMENTS,
    server::{Options, start},
    session::{MAX_CONNECTION_DOCUMENTS, MAX_READ},
    store::FileStore,
};
use serde_json::json;
use std::{
    fs,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use support::{Client, server};

#[tokio::test]
async fn missing_paths_do_not_materialize_files_or_recovery_for_viewers_or_editors() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let authority = SignedCredentials::new(b"edge".to_vec(), "https://login.invalid");
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.authority = Some(Arc::new(SignedCredentials::new(
        b"edge".to_vec(),
        "https://login.invalid",
    )));
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    assert_eq!(client.request(json!({"op":"hello"})).await["ok"], true);
    for signed_in in [false, true] {
        if signed_in {
            let expires = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                + 600;
            let credential = authority.issue(
                &Identity {
                    login: "editor".into(),
                    id: 1,
                },
                expires,
            );
            assert_eq!(
                client
                    .request(json!({"op":"auth.login","credential":credential}))
                    .await["ok"],
                true
            );
        }
        for index in 0..20 {
            let path = format!("missing-{signed_in}-{index}.hx");
            assert_eq!(
                client.request(json!({"op":"doc.open","path":path})).await["code"],
                "not-found"
            );
            assert!(
                running
                    .workspace
                    .store
                    .read_state(&format!("doc:{path}"))
                    .await
                    .unwrap()
                    .is_none()
            );
            assert!(!root.path().join(path).exists());
        }
    }
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"new.hx","data":"class New {}"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"new.hx"}))
            .await["text"],
        "class New {}"
    );
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn oversized_binary_and_directory_opens_do_not_leave_document_state() {
    let root = tempfile::tempdir().unwrap();
    fs::File::create(root.path().join("large.hx"))
        .unwrap()
        .set_len(MAX_READ + 1)
        .unwrap();
    fs::write(root.path().join("binary.bin"), [0xff]).unwrap();
    fs::create_dir(root.path().join("folder")).unwrap();
    let running = server(root.path(), false).await;
    let mut client = Client::hello(&running).await;
    for (path, code) in [
        ("large.hx", "too-large"),
        ("binary.bin", "not-text"),
        ("folder", "wrong-kind"),
    ] {
        assert_eq!(
            client.request(json!({"op":"doc.open","path":path})).await["code"],
            code
        );
        assert!(
            running
                .workspace
                .store
                .read_state(&format!("doc:{path}"))
                .await
                .unwrap()
                .is_none()
        );
    }
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn connection_admission_supports_many_tabs_and_releases_closed_subscriptions() {
    let root = tempfile::tempdir().unwrap();
    for index in 0..=MAX_CONNECTION_DOCUMENTS {
        fs::write(
            root.path().join(format!("{index}.hx")),
            format!("class File{index} {{}}\n"),
        )
        .unwrap();
    }
    let running = server(root.path(), false).await;
    let mut client = Client::hello(&running).await;
    for index in 0..MAX_CONNECTION_DOCUMENTS {
        assert_eq!(
            client
                .request(json!({"op":"doc.open","path":format!("{index}.hx")}))
                .await["ok"],
            true,
            "tab {index}"
        );
    }
    assert!(MAX_CONNECTION_DOCUMENTS >= 65);
    assert_eq!(
        client.request(json!({"op":"doc.open","path":"0.hx"})).await["ok"],
        true
    );
    let overflow = format!("{MAX_CONNECTION_DOCUMENTS}.hx");
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":overflow}))
            .await["code"],
        "busy"
    );
    assert!(
        running
            .workspace
            .store
            .read_state(&format!("doc:{overflow}"))
            .await
            .unwrap()
            .is_none()
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.close","path":"0.hx"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":overflow}))
            .await["ok"],
        true
    );
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn workspace_admission_is_atomic_shares_existing_docs_and_recovers_after_disconnect() {
    let root = tempfile::tempdir().unwrap();
    for index in 0..MAX_DOCUMENTS + 3 {
        fs::write(
            root.path().join(format!("{index}.hx")),
            format!("class File{index} {{}}\n"),
        )
        .unwrap();
    }
    fs::write(root.path().join("bad.bin"), [0xff]).unwrap();
    let running = server(root.path(), false).await;
    let (mut a, mut b, mut c) = (
        Client::hello(&running).await,
        Client::hello(&running).await,
        Client::hello(&running).await,
    );
    for index in 0..MAX_CONNECTION_DOCUMENTS {
        assert_eq!(
            a.request(json!({"op":"doc.open","path":format!("{index}.hx")}))
                .await["ok"],
            true
        );
    }
    for index in MAX_CONNECTION_DOCUMENTS..MAX_DOCUMENTS - 1 {
        assert_eq!(
            b.request(json!({"op":"doc.open","path":format!("{index}.hx")}))
                .await["ok"],
            true
        );
    }
    assert_eq!(
        c.request(json!({"op":"doc.open","path":"bad.bin"})).await["code"],
        "not-text"
    );
    let (first, second) = tokio::join!(
        b.request(json!({"op":"doc.open","path":format!("{}.hx",MAX_DOCUMENTS-1)})),
        c.request(json!({"op":"doc.open","path":format!("{MAX_DOCUMENTS}.hx")}))
    );
    assert_eq!(
        usize::from(first["ok"] == true) + usize::from(second["ok"] == true),
        1
    );
    assert!(first["code"] == "busy" || second["code"] == "busy");
    let overflow = format!("{}.hx", MAX_DOCUMENTS + 1);
    assert_eq!(
        c.request(json!({"op":"doc.open","path":"0.hx"})).await["ok"],
        true
    );
    assert_eq!(
        a.request(json!({"op":"doc.close","path":"0.hx"})).await["ok"],
        true
    );
    assert_eq!(
        c.request(json!({"op":"doc.open","path":overflow})).await["code"],
        "busy"
    );
    assert!(
        running
            .workspace
            .store
            .read_state(&format!("doc:{overflow}"))
            .await
            .unwrap()
            .is_none()
    );
    assert_eq!(
        c.request(json!({"op":"doc.close","path":"0.hx"})).await["ok"],
        true
    );
    assert_eq!(
        c.request(json!({"op":"doc.open","path":overflow})).await["ok"],
        true
    );
    assert_eq!(c.request(json!({"op":"doc.update","path":format!("{MAX_CONNECTION_DOCUMENTS}.hx"),"update":"invalid"})).await["code"],"not-open");
    b.close().await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        let reply = c
            .request(json!({"op":"doc.open","path":format!("{}.hx",MAX_DOCUMENTS+2)}))
            .await;
        if reply["ok"] == true {
            break;
        }
        assert_eq!(reply["code"], "busy");
        assert!(tokio::time::Instant::now() < deadline);
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    a.close().await;
    c.close().await;
    running.shutdown().await;
}
