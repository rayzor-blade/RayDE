mod support;
use rayde_session::server::{Options, start};
use serde_json::json;
use support::Client;

#[tokio::test]
async fn app_artifacts_use_a_separate_origin_and_connection_owned_capabilities() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let output = root.path().join(".rayde/previews/one");
    std::fs::create_dir_all(&output).unwrap();
    std::fs::write(output.join("index.html"), "<html>preview</html>").unwrap();
    std::fs::write(output.join("app.wasm"), [0, 97, 115, 109, 1, 0, 0, 0]).unwrap();
    let mut options = Options::new(root.path());
    options.exec = true;
    options.state_root = Some(state.path().into());
    let running = start(options).await.unwrap();
    let mut owner = Client::connect(&running).await;
    assert_eq!(
        owner.request(json!({"op":"hello"})).await["appPreviews"],
        false
    );
    assert_eq!(
        owner
            .request(json!({"op":"preview.open","path":"data"}))
            .await["ok"],
        false
    );
    let opened = owner
        .request(json!({"op":"preview.open","path":".rayde/previews/one"}))
        .await;
    assert_eq!(opened["ok"], true, "{opened}");
    let id = &opened["preview"];
    let url = opened["url"].as_str().unwrap();
    assert!(!url.starts_with(&running.url()));
    let http = reqwest_client();
    let response = http.get(url).send().await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers()["cross-origin-opener-policy"],
        "same-origin"
    );
    assert_eq!(
        response.headers()["cross-origin-embedder-policy"],
        "require-corp"
    );
    let html=response.text().await.unwrap();
    assert!(html.contains("<html>preview</html>") && html.contains("data-rayde-preview-metadata"));
    let read = owner
        .request(json!({"op":"preview.read","preview":id,"path":"app.wasm","offset":4,"length":4}))
        .await;
    assert_eq!(read["data"], "AQAAAA==");
    assert_eq!(read["mime"], "application/wasm");
    assert_eq!(
        owner
            .request(json!({"op":"preview.read","preview":id,"path":"../outside"}))
            .await["ok"],
        false
    );
    let mut other = Client::connect(&running).await;
    other.request(json!({"op":"hello"})).await;
    assert_eq!(
        other
            .request(json!({"op":"preview.read","preview":id,"path":"index.html"}))
            .await["ok"],
        false
    );
    assert_eq!(
        owner
            .request(json!({"op":"preview.close","preview":id}))
            .await["ok"],
        true
    );
    assert_eq!(http.get(url).send().await.unwrap().status(), 404);
    let opened = owner
        .request(json!({"op":"preview.open","path":".rayde/previews/one"}))
        .await;
    let url = opened["url"].as_str().unwrap().to_owned();
    owner.close().await;
    for _ in 0..100 {
        if http.get(&url).send().await.unwrap().status() == 404 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(http.get(&url).send().await.unwrap().status(), 404);
    other.close().await;
    running.shutdown().await;
}
fn reqwest_client() -> reqwest::Client {
    reqwest::Client::new()
}

#[tokio::test]
async fn prepared_builds_install_the_bridge_and_are_released_with_their_owner() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    for name in [
        "haxe/rayde/preview/Files.hx",
        "ash_channel.wasm",
        "channel-agent.mjs",
        "rayde_preview_files.mjs",
        "preview-frames.mjs",
    ] {
        let path = tools.path().join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "fixture").unwrap();
    }
    let mut options = Options::new(root.path());
    options.exec = true;
    options.state_root = Some(state.path().into());
    options.preview_tools = Some(tools.path().into());
    let running = start(options).await.unwrap();
    let mut owner = Client::connect(&running).await;
    assert_eq!(
        owner.request(json!({"op":"hello"})).await["appPreviews"],
        true
    );
    let prepared = owner.request(json!({"op":"preview.prepare"})).await;
    assert_eq!(prepared["ok"], true, "{prepared}");
    let directory = std::path::PathBuf::from(prepared["directory"].as_str().unwrap());
    assert_eq!(
        std::fs::read_to_string(directory.join("rayde_preview_files.mjs")).unwrap(),
        "fixture"
    );
    let mut other = Client::connect(&running).await;
    other.request(json!({"op":"hello"})).await;
    assert_eq!(
        other
            .request(json!({"op":"preview.cache","path":prepared["path"],"stage":"wasm"}))
            .await["ok"],
        false
    );
    assert_eq!(
        other
            .request(json!({"op":"preview.discard","path":prepared["path"]}))
            .await["ok"],
        false
    );
    owner.close().await;
    for _ in 0..100 {
        if !directory.exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(!directory.exists());
    other.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn javascript_preview_uses_framework_assets_without_hashlink_tooling() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(root.path().join("bin")).unwrap();
    std::fs::write(
        root.path().join("index.html"),
        "<script src='./bin/app.js'></script>",
    )
    .unwrap();
    std::fs::write(root.path().join("style.css"), "body{color:red}").unwrap();
    std::fs::write(root.path().join("bin/app.js"), "stale source output").unwrap();
    std::fs::write(root.path().join(".env"), "private").unwrap();
    let mut options = Options::new(root.path());
    options.exec = true;
    options.state_root = Some(state.path().into());
    let running = start(options).await.unwrap();
    let mut owner = Client::connect(&running).await;
    let hello = owner.request(json!({"op":"hello"})).await;
    assert_eq!(hello["appPreviews"], false);
    assert_eq!(hello["webPreviews"], true);
    let prepared=owner.request(json!({"op":"preview.prepare","recipe":{"compiler":"haxe","args":[],"cwd":"","family":"haxe","primary":"bin/app.js"}})).await;
    assert_eq!(prepared["ok"], true, "{prepared}");
    let directory = std::path::PathBuf::from(prepared["directory"].as_str().unwrap());
    std::fs::create_dir_all(directory.join("bin")).unwrap();
    std::fs::write(directory.join("bin/app.js"), "fresh compiler output").unwrap();
    let collected=owner.request(json!({"op":"preview.collect","path":prepared["path"],"source":".","entry":"index.html","script":"bin/app.js"})).await;
    assert_eq!(collected["ok"], true, "{collected}");
    assert_eq!(
        std::fs::read_to_string(directory.join("bin/app.js")).unwrap(),
        "fresh compiler output"
    );
    assert!(!directory.join(".env").exists());
    assert!(directory.join("style.css").exists());
    let mut other = Client::connect(&running).await;
    other.request(json!({"op":"hello"})).await;
    assert_eq!(
        other
            .request(json!({"op":"preview.collect","path":prepared["path"]}))
            .await["ok"],
        false
    );
    assert_eq!(
        owner
            .request(json!({"op":"preview.collect","path":prepared["path"],"source":".."}))
            .await["ok"],
        false
    );
    let opened = owner
        .request(json!({"op":"preview.open","path":prepared["path"]}))
        .await;
    let http = reqwest_client();
    let url = opened["url"].as_str().unwrap();
    assert_eq!(http.get(url).send().await.unwrap().status(), 200);
    assert_eq!(
        http.get(url.replace("index.html", "bin/app.js"))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "fresh compiler output"
    );
    assert_eq!(
        http.get(url.replace("index.html", ".env"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    owner.close().await;
    other.close().await;
    running.shutdown().await;
}
