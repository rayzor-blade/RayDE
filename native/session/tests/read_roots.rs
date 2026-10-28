mod support;
use rayde_session::server::{Options, start};
use serde_json::json;
use support::Client;

#[tokio::test]
async fn sources_are_explicit_bounded_read_only_and_do_not_enter_document_state() {
    let workspace = tempfile::tempdir().unwrap();
    let libraries = tempfile::tempdir().unwrap();
    let private = tempfile::tempdir().unwrap();
    std::fs::write(workspace.path().join("same.hx"),"editable").unwrap();
    std::fs::write(libraries.path().join("same.hx"),"library 🦊").unwrap();
    std::fs::write(private.path().join("secret"),"private").unwrap();
    #[cfg(unix)] std::os::unix::fs::symlink(private.path(),libraries.path().join("escape")).unwrap();
    let mut options = Options::new(workspace.path());
    options.state_root = Some(private.path().join("state"));
    options.read_roots = vec![libraries.path().into()];
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    let hello = client.request(json!({"op":"hello"})).await;
    assert_eq!(hello["readRoots"].as_array().unwrap().len(),1);
    let mount = &hello["readRoots"][0]["id"];
    assert_eq!(client.request(json!({"op":"fs.read","mount":mount,"path":"same.hx"})).await["data"],"library 🦊");
    assert_eq!(client.request(json!({"op":"fs.read","path":"same.hx"})).await["data"],"editable");
    assert_eq!(client.request(json!({"op":"fs.read","mount":mount,"path":"same.hx","offset":0,"length":7,"encoding":"base64"})).await["data"],"bGlicmFyeQ==");
    assert_eq!(client.request(json!({"op":"fs.stat","mount":mount,"path":"missing"})).await["entry"],serde_json::Value::Null);
    for op in ["fs.write","fs.mkdir","fs.remove","fs.rename","doc.open","doc.update","doc.save"] {
        assert_eq!(client.request(json!({"op":op,"mount":mount,"path":"same.hx","from":"same.hx","to":"changed.hx","data":"overwrite"})).await["code"],"read-only");
    }
    #[cfg(unix)]
    assert_eq!(client.request(json!({"op":"fs.read","mount":mount,"path":"escape/secret"})).await["code"],"outside");
    for path in ["../secret"] {
        assert_eq!(client.request(json!({"op":"fs.read","mount":mount,"path":path})).await["code"],"outside");
    }
    assert_eq!(client.request(json!({"op":"fs.read","mount":"unknown","path":"same.hx"})).await["code"],"outside");
    assert_eq!(std::fs::read_to_string(workspace.path().join("same.hx")).unwrap(),"editable");
    client.close().await;
    running.shutdown().await;
}
