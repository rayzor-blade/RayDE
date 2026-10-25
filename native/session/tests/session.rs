mod support;
use serde_json::json;
use std::fs;
use support::{Client, Peer, server, until};

#[tokio::test]
async fn a_wrong_token_is_refused_and_nothing_works_before_hello() {
    let dir = tempfile::tempdir().unwrap();
    let running = server(dir.path(), false).await;
    let mut client = Client::connect(&running).await;
    assert_eq!(client.request(json!({"op": "fs.list", "path": ""})).await["code"], "unauthorised");
    assert_eq!(client.request(json!({"op": "hello", "token": "wrong"})).await["code"], "unauthorised");
    assert_eq!(client.request(json!({"op": "hello", "token": "secret"})).await["ok"], true);
    assert_eq!(client.request(json!({"op": "fs.list", "path": ""})).await["ok"], true);
    running.shutdown().await;
}

#[tokio::test]
async fn files_are_listed_read_written_renamed_and_removed_inside_the_workspace() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("src")).unwrap();
    fs::write(dir.path().join("src/Main.hx"), "class Main {}").unwrap();
    let running = server(dir.path(), false).await;
    let mut c = Client::hello(&running).await;

    let list = c.request(json!({"op": "fs.list", "path": ""})).await;
    assert_eq!(list["entries"][0]["name"], "src");
    assert_eq!(list["entries"][0]["kind"], "dir");
    assert_eq!(c.request(json!({"op": "fs.read", "path": "src/Main.hx"})).await["data"], "class Main {}");

    assert_eq!(c.request(json!({"op": "fs.write", "path": "out/a.txt", "data": "hi"})).await["ok"], true);
    assert_eq!(fs::read_to_string(dir.path().join("out/a.txt")).unwrap(), "hi");
    assert_eq!(c.request(json!({"op": "fs.write", "path": "out/b.bin", "data": "AAEC", "encoding": "base64"})).await["ok"], true);
    assert_eq!(fs::read(dir.path().join("out/b.bin")).unwrap(), vec![0, 1, 2]);

    assert_eq!(c.request(json!({"op": "fs.rename", "from": "out/a.txt", "to": "out/c.txt"})).await["ok"], true);
    assert!(dir.path().join("out/c.txt").exists());
    assert_eq!(c.request(json!({"op": "fs.read", "path": "out/a.txt"})).await["code"], "not-found");
    assert_eq!(c.request(json!({"op": "fs.remove", "path": "out"})).await["code"], "exists");
    assert_eq!(c.request(json!({"op": "fs.remove", "path": "out", "recursive": true})).await["ok"], true);
    assert!(!dir.path().join("out").exists());
    // The session's own directory is not part of the workspace.
    assert!(c.request(json!({"op": "fs.list", "path": ""})).await["entries"].as_array().unwrap().iter().all(|e| e["name"] != ".rayde-session"));
    running.shutdown().await;
}

#[tokio::test]
async fn paths_cannot_leave_the_workspace() {
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("secret.txt"), "no").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside.path(), dir.path().join("link")).unwrap();
    let running = server(dir.path(), true).await;
    let mut c = Client::hello(&running).await;
    for path in ["../x", "a/../../x", ".rayde-session/state", "a\\b"] {
        let reply = c.request(json!({"op": "fs.read", "path": path})).await;
        assert_eq!(reply["ok"], false, "{path}: {reply}");
    }
    #[cfg(unix)]
    {
        assert_eq!(c.request(json!({"op": "fs.read", "path": "link/secret.txt"})).await["code"], "outside");
        assert_eq!(c.request(json!({"op": "fs.write", "path": "link/new.txt", "data": "x"})).await["code"], "outside");
        assert!(!outside.path().join("new.txt").exists());
        assert_eq!(c.request(json!({"op": "proc.spawn", "command": "ls", "cwd": "link"})).await["code"], "outside");
    }
    assert_eq!(c.request(json!({"op": "fs.remove", "path": ""})).await["ok"], false);
    running.shutdown().await;
}

#[tokio::test]
async fn two_clients_edit_one_document_and_the_file_follows() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "hello world").unwrap();
    let running = server(dir.path(), false).await;
    let (mut a, mut b) = (Client::hello(&running).await, Client::hello(&running).await);
    let (pa, pb) = (Peer::new(), Peer::new());
    let opened_a = a.request(json!({"op": "doc.open", "path": "a.txt"})).await;
    pa.apply(opened_a["update"].as_str().unwrap());
    let opened_b = b.request(json!({"op": "doc.open", "path": "a.txt"})).await;
    pb.apply(opened_b["update"].as_str().unwrap());
    assert_eq!((pa.string().as_str(), pb.string().as_str()), ("hello world", "hello world"));

    // Concurrent edits at both ends merge.
    let ua = pa.edit(0, 0, "A: ");
    let ub = pb.edit(11, 0, "!");
    assert_eq!(a.request(json!({"op": "doc.update", "path": "a.txt", "update": ua})).await["ok"], true);
    assert_eq!(b.request(json!({"op": "doc.update", "path": "a.txt", "update": ub})).await["ok"], true);
    pb.apply(a_update(&mut b).await.as_str());
    pa.apply(a_update(&mut a).await.as_str());
    assert_eq!(pa.string(), "A: hello world!");
    assert_eq!(pb.string(), "A: hello world!");
    until(|| fs::read_to_string(dir.path().join("a.txt")).unwrap() == "A: hello world!").await;
    running.shutdown().await;
}

async fn a_update(client: &mut Client) -> String {
    client.event("doc.update").await["update"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn a_change_made_outside_the_session_becomes_an_edit_and_its_own_writes_do_not() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "one\ntwo\n").unwrap();
    let running = server(dir.path(), false).await;
    let mut c = Client::hello(&running).await;
    let peer = Peer::new();
    peer.apply(c.request(json!({"op": "doc.open", "path": "a.txt"})).await["update"].as_str().unwrap());
    fs::write(dir.path().join("a.txt"), "one\nTWO\nthree\n").unwrap();
    peer.apply(&a_update(&mut c).await);
    until(|| peer.string() == "one\nTWO\nthree\n").await;
    // The session's own write comes back as a file change but not as another edit.
    let update = peer.edit(0, 0, "x");
    c.request(json!({"op": "doc.update", "path": "a.txt", "update": update})).await;
    until(|| fs::read_to_string(dir.path().join("a.txt")).unwrap() == "xone\nTWO\nthree\n").await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(running.workspace.docs.text("a.txt").unwrap(), "xone\nTWO\nthree\n");
    running.shutdown().await;
}

#[tokio::test]
async fn edits_made_offline_merge_after_a_reconnect_and_after_the_server_restarts() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "base").unwrap();
    let running = server(dir.path(), false).await;
    let mut a = Client::hello(&running).await;
    let page = Peer::new();
    let opened = a.request(json!({"op": "doc.open", "path": "a.txt"})).await;
    page.apply(opened["update"].as_str().unwrap());
    a.request(json!({"op": "doc.save", "path": "a.txt"})).await;
    drop(a);
    running.shutdown().await;

    // The file is edited by someone else while the session is down, and the page edits offline.
    fs::write(dir.path().join("a.txt"), "base, from disk").unwrap();
    page.edit(4, 0, " (offline)");

    let running = server(dir.path(), false).await;
    let mut a = Client::hello(&running).await;
    let reopened = a.request(json!({"op": "doc.open", "path": "a.txt", "vector": page.vector()})).await;
    page.apply(reopened["update"].as_str().unwrap());
    let missing = page.missing(reopened["vector"].as_str().unwrap());
    assert_eq!(a.request(json!({"op": "doc.update", "path": "a.txt", "update": missing})).await["ok"], true);
    let merged = page.string();
    assert!(merged.contains("(offline)") && merged.contains("from disk"), "{merged}");
    assert_eq!(merged.matches("base").count(), 1, "history is shared, so the text is not duplicated: {merged}");
    until(|| fs::read_to_string(dir.path().join("a.txt")).unwrap() == merged).await;
    running.shutdown().await;
}

#[tokio::test]
async fn text_with_astral_characters_is_edited_in_utf16_units() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "a😀b😀c").unwrap();
    let running = server(dir.path(), false).await;
    let mut c = Client::hello(&running).await;
    let peer = Peer::new();
    peer.apply(c.request(json!({"op": "doc.open", "path": "a.txt"})).await["update"].as_str().unwrap());
    fs::write(dir.path().join("a.txt"), "a😀b😁c").unwrap();
    peer.apply(&a_update(&mut c).await);
    until(|| peer.string() == "a😀b😁c").await;
    running.shutdown().await;
}

#[tokio::test]
async fn a_program_runs_in_the_workspace_and_its_output_arrives() {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("sub")).unwrap();
    let running = server(dir.path(), true).await;
    let mut c = Client::hello(&running).await;
    let spawned = c.request(json!({"op": "proc.spawn", "command": "sh", "args": ["-c", "pwd; read x; echo got:$x; exit 3"], "cwd": "sub"})).await;
    let pid = spawned["pid"].as_u64().unwrap();
    c.request(json!({"op": "proc.write", "pid": pid, "data": B64.encode("hi\n")})).await;
    let mut out = String::new();
    let exit = loop {
        let event = c.events.recv().await.unwrap();
        if event["ev"] == "proc.out" {
            out += &String::from_utf8(B64.decode(event["data"].as_str().unwrap()).unwrap()).unwrap();
        } else if event["ev"] == "proc.exit" {
            break event;
        }
    };
    assert!(out.contains("sub") && out.contains("got:hi"), "{out}");
    assert_eq!(exit["code"], 3);
    // Another client cannot touch it, and a session without exec runs nothing.
    let other = Client::hello(&running).await;
    drop(other);
    running.shutdown().await;
    let running = server(dir.path(), false).await;
    let mut c = Client::hello(&running).await;
    assert_eq!(c.request(json!({"op": "proc.spawn", "command": "true"})).await["code"], "no-exec");
    running.shutdown().await;
}

#[tokio::test]
async fn a_connection_that_drops_stops_its_programs() {
    let dir = tempfile::tempdir().unwrap();
    let running = server(dir.path(), true).await;
    let mut c = Client::hello(&running).await;
    c.request(json!({"op": "proc.spawn", "command": "sleep", "args": ["30"]})).await;
    drop(c);
    until(|| running.workspace.programs.is_some()).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    running.shutdown().await;
}

#[tokio::test]
async fn nobody_edits_before_signing_in_with_a_credential_the_edge_signed() {
    use rayde_session::auth::{Identity, SignedCredentials};
    use rayde_session::server::{Options, start};
    use std::sync::Arc;
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "look").unwrap();
    let edge = SignedCredentials::new(b"edge-secret".to_vec(), "https://play.example/login");
    let mut options = Options::new(dir.path());
    options.token = Some("secret".into());
    options.authority = Some(Arc::new(SignedCredentials::new(b"edge-secret".to_vec(), "https://play.example/login")));
    let running = start(options).await.unwrap();
    let mut c = Client::hello(&running).await;
    let me = Identity { login: "darmie".into(), id: 42 };

    // Looking is open.
    assert_eq!(c.request(json!({"op": "fs.read", "path": "a.txt"})).await["data"], "look");
    let peer = Peer::new();
    peer.apply(c.request(json!({"op": "doc.open", "path": "a.txt"})).await["update"].as_str().unwrap());
    // Changing is not, and the refusal says where to sign in.
    let update = peer.edit(0, 0, "x");
    for request in [json!({"op": "doc.update", "path": "a.txt", "update": update}), json!({"op": "fs.write", "path": "b.txt", "data": "no"}), json!({"op": "proc.spawn", "command": "true"})] {
        let reply = c.request(request).await;
        assert_eq!((reply["code"].as_str(), reply["login"].as_str()), (Some("auth-required"), Some("https://play.example/login")), "{reply}");
    }
    assert!(!dir.path().join("b.txt").exists());

    // A forged, a foreign and an expired credential do not sign in.
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let foreign = SignedCredentials::new(b"another-secret".to_vec(), "x").issue(&me, now + 600);
    let expired = edge.issue(&me, now - 1);
    let mut forged = edge.issue(&me, now + 600);
    forged.insert(3, 'A');
    for credential in [foreign, expired, forged, "garbage".to_string()] {
        assert_eq!(c.request(json!({"op": "auth.login", "credential": credential})).await["code"], "unauthorised");
    }
    assert_eq!(c.request(json!({"op": "fs.write", "path": "b.txt", "data": "no"})).await["code"], "auth-required");

    // A genuine one does.
    let ok = c.request(json!({"op": "auth.login", "credential": edge.issue(&me, now + 600)})).await;
    assert_eq!((ok["ok"].as_bool(), ok["login"].as_str()), (Some(true), Some("darmie")));
    assert_eq!(c.request(json!({"op": "fs.write", "path": "b.txt", "data": "yes"})).await["ok"], true);
    assert_eq!(fs::read_to_string(dir.path().join("b.txt")).unwrap(), "yes");
    // Signing in is per connection.
    let mut other = Client::hello(&running).await;
    assert_eq!(other.request(json!({"op": "fs.write", "path": "c.txt", "data": "no"})).await["code"], "auth-required");
    running.shutdown().await;
}
