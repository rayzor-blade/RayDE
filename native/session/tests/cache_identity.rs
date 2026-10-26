mod support;
use rayde_session::server::{Options, start};
use serde_json::json;
use support::Client;

#[tokio::test]
async fn recovery_identity_survives_restart_and_distinguishes_equal_names_and_authorities() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let first = root.path().join("first/project");
    let second = root.path().join("second/project");
    std::fs::create_dir_all(&first).unwrap();
    std::fs::create_dir_all(&second).unwrap();
    let mut identities = Vec::new();
    for directory in [&first, &second, &first] {
        let mut options = Options::new(directory);
        options.state_root = Some(state.path().to_path_buf());
        options.token = Some("private-token".into());
        let running = start(options).await.unwrap();
        let mut client = Client::connect(&running).await;
        let hello = client
            .request(json!({"op":"hello","token":"private-token"}))
            .await;
        assert_eq!(hello["name"], "project");
        assert_eq!(hello["cacheIdentity"]["version"], 1);
        assert_eq!(hello["cacheIdentity"]["principal"], "workspace");
        for field in ["authority", "workspace"] {
            let id = hello["cacheIdentity"][field].as_str().unwrap();
            assert_eq!(id.len(), 64);
            assert!(id.bytes().all(|byte| byte.is_ascii_hexdigit()));
        }
        assert!(!hello["cacheIdentity"].to_string().contains("private-token"));
        identities.push(hello["cacheIdentity"].clone());
        client.close().await;
        running.shutdown().await;
    }
    assert_eq!(identities[0], identities[2]);
    assert_ne!(identities[0]["workspace"], identities[1]["workspace"]);
    assert_eq!(identities[0]["authority"], identities[1]["authority"]);
    let namespace = std::fs::read_dir(state.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.join("state/workspace.id").is_file()
                && std::fs::read_to_string(path.join("state/workspace.id")).unwrap()
                    == identities[0]["workspace"].as_str().unwrap()
        })
        .unwrap();
    std::fs::remove_dir_all(namespace.join("state")).unwrap();
    let mut options = Options::new(&first);
    options.state_root = Some(state.path().to_path_buf());
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    let replacement = client.request(json!({"op":"hello"})).await;
    assert_eq!(
        identities[0]["authority"],
        replacement["cacheIdentity"]["authority"]
    );
    assert_ne!(
        identities[0]["workspace"],
        replacement["cacheIdentity"]["workspace"]
    );
    client.close().await;
    running.shutdown().await;
    let other_authority = tempfile::tempdir().unwrap();
    let mut options = Options::new(first);
    options.state_root = Some(other_authority.path().to_path_buf());
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    let hello = client.request(json!({"op":"hello"})).await;
    assert_ne!(
        identities[0]["authority"],
        hello["cacheIdentity"]["authority"]
    );
    client.close().await;
    running.shutdown().await;
}
