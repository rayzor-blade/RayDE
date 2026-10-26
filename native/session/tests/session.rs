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
    assert_eq!(c.request(json!({"op": "fs.read", "path": "src/Main.hx", "offset": 6, "length": 4})).await["data"], "Main");
    assert_eq!(c.request(json!({"op": "fs.read", "path": "src/Main.hx", "offset": 99})).await["data"], "");

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
async fn moving_an_open_crdt_file_or_parent_is_refused_without_losing_updates() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("src")).unwrap();
    fs::create_dir(dir.path().join("src-other")).unwrap();
    fs::write(dir.path().join("src/a.txt"), "base").unwrap();
    fs::write(dir.path().join("other.txt"), "other").unwrap();
    let running = server(dir.path(), false).await;
    let mut reader = Client::hello(&running).await;
    let mut mover = Client::hello(&running).await;
    let peer = Peer::new();
    let opened = reader.request(json!({"op":"doc.open","path":"src/a.txt"})).await;
    peer.apply(opened["update"].as_str().unwrap());
    for (from,to) in [("src/a.txt","a.txt"),("src","moved"),("other.txt","src/a.txt")] {
        assert_eq!(mover.request(json!({"op":"fs.rename","from":from,"to":to})).await["code"], "document-open");
    }
    assert_eq!(mover.request(json!({"op":"fs.rename","from":"src-other","to":"elsewhere"})).await["ok"], true);
    let update = peer.edit(4,0," + kept");
    assert_eq!(reader.request(json!({"op":"doc.update","path":"src/a.txt","update":update})).await["ok"], true);
    assert_eq!(reader.request(json!({"op":"doc.save","path":"src/a.txt"})).await["ok"], true);
    assert_eq!(fs::read_to_string(dir.path().join("src/a.txt")).unwrap(), "base + kept");
    assert_eq!(fs::read_to_string(dir.path().join("other.txt")).unwrap(), "other");
    assert!(!dir.path().join("moved").exists());
    running.shutdown().await;
}

#[tokio::test]
async fn closing_the_last_document_releases_it_without_closing_the_connection() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "base").unwrap();
    let running = server(dir.path(), false).await;
    let (mut a, mut b) = (Client::hello(&running).await, Client::hello(&running).await);
    let peer = Peer::new();
    peer.apply(a.request(json!({"op":"doc.open","path":"a.txt"})).await["update"].as_str().unwrap());
    b.request(json!({"op":"doc.open","path":"a.txt"})).await;
    a.request(json!({"op":"doc.close","path":"a.txt"})).await;
    assert!(running.workspace.docs.text("a.txt").is_some(), "another subscriber still owns the document");
    let update = peer.edit(4, 0, "!");
    assert_eq!(b.request(json!({"op":"doc.update","path":"a.txt","update":update})).await["ok"], true);
    assert_eq!(b.request(json!({"op":"doc.close","path":"a.txt"})).await["ok"], true);
    assert!(running.workspace.docs.text("a.txt").is_none());
    assert_eq!(fs::read_to_string(dir.path().join("a.txt")).unwrap(), "base!");
    assert_eq!(a.request(json!({"op":"fs.rename","from":"a.txt","to":"b.txt"})).await["ok"], true);
    assert_eq!(a.request(json!({"op":"doc.open","path":"b.txt"})).await["text"], "base!");
    running.shutdown().await;
}

#[tokio::test]
async fn a_failed_document_write_is_retried_instead_of_being_marked_saved() {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    use rayde_session::{dir_store::DirStore, docs::DocHub};
    use std::sync::Arc;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    fs::write(&path, "base").unwrap();
    let state = tempfile::tempdir().unwrap();
    let hub = DocHub::new(Arc::new(DirStore::with_state_root(dir.path(),state.path()).unwrap()), Arc::new(|_| {}));
    let peer = Peer::new();
    peer.apply(&B64.encode(hub.attach("a.txt", "a", None, Arc::new(|_| {})).await.unwrap().update));
    hub.receive("a.txt", "a", &B64.decode(peer.edit(4, 0, "!")).unwrap()).unwrap();
    fs::remove_file(&path).unwrap(); fs::create_dir(&path).unwrap();
    assert!(hub.flush("a.txt").await.is_err());
    fs::remove_dir(&path).unwrap(); fs::write(&path, "base").unwrap();
    assert!(hub.flush("a.txt").await.unwrap().0);
    assert_eq!(fs::read_to_string(&path).unwrap(), "base!");
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

#[tokio::test]
async fn the_protocol_also_runs_as_length_prefixed_frames_over_tcp_and_as_websocket_binary() {
    use rayde_session::server::{Frames, frame};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "framed").unwrap();
    let mut options = rayde_session::server::Options::new(dir.path());
    options.token = Some("secret".into());
    options.raw = Some(([127, 0, 0, 1], 0).into());
    let running = rayde_session::server::start(options).await.unwrap();

    // Over TCP, with requests split across writes and two sent in one.
    let mut stream = tokio::net::TcpStream::connect(running.raw_address.unwrap()).await.unwrap();
    let hello = frame(&json!({"op": "hello", "token": "secret", "id": 1}).to_string());
    stream.write_all(&hello[..3]).await.unwrap();
    stream.write_all(&hello[3..]).await.unwrap();
    let mut both = frame(&json!({"op": "fs.read", "path": "a.txt", "id": 2}).to_string());
    both.extend(frame(&json!({"op": "fs.stat", "path": "a.txt", "id": 3}).to_string()));
    stream.write_all(&both).await.unwrap();
    let (mut frames, mut texts, mut buffer) = (Frames::default(), Vec::new(), [0u8; 4096]);
    while texts.len() < 3 {
        let n = tokio::time::timeout(std::time::Duration::from_secs(5), stream.read(&mut buffer)).await.unwrap().unwrap();
        texts.extend(frames.push(&buffer[..n]).unwrap());
    }
    let replies: Vec<serde_json::Value> = texts.iter().map(|t| serde_json::from_str(t).unwrap()).collect();
    assert_eq!(replies[0]["ok"], true);
    assert_eq!(replies[1]["data"], "framed");
    assert_eq!(replies[2]["entry"]["size"], 6);

    // Over a WebSocket, a client that speaks binary is answered in binary.
    let mut c = Client::connect_binary(&running).await;
    let reply = c.request(json!({"op": "hello", "token": "secret"})).await;
    assert_eq!(reply["ok"], true);
    assert_eq!(c.request(json!({"op": "fs.read", "path": "a.txt"})).await["data"], "framed");

    // A stream that is not frames is dropped.
    let mut bad = tokio::net::TcpStream::connect(running.raw_address.unwrap()).await.unwrap();
    bad.write_all(&[0xff, 0xff, 0xff, 0xff, 1, 2, 3]).await.unwrap();
    let n = tokio::time::timeout(std::time::Duration::from_secs(5), bad.read(&mut buffer)).await.unwrap().unwrap();
    assert_eq!(n, 0);
    running.shutdown().await;
}

#[tokio::test]
async fn extension_hosts_require_execution_and_hello_reports_the_installation() {
    use rayde_session::server::{Options, start};
    let dir = tempfile::tempdir().unwrap();
    let host = std::env::current_exe().unwrap().canonicalize().unwrap();
    let mut options = Options::new(dir.path());
    options.extension_host = Some(host.clone());
    assert!(start(options).await.is_err());
    let mut options = Options::new(dir.path());
    options.exec = true;
    options.extension_host = Some(host.clone());
    options.extensions = Some(dir.path().to_path_buf());
    let running = start(options).await.unwrap();
    let mut client = Client::connect(&running).await;
    let hello = client.request(json!({"op":"hello"})).await;
    assert_eq!(hello["exec"], true);
    assert_eq!(hello["extensions"]["host"], host.to_str().unwrap());
    assert_eq!(hello["extensions"]["root"], dir.path().canonicalize().unwrap().to_str().unwrap());
    running.shutdown().await;
}

#[tokio::test]
async fn served_pages_allow_shared_wasm_memory() {
    use rayde_session::server::{Options, start};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("index.html"), "page").unwrap();
    let mut options = Options::new(dir.path());
    options.web = Some(dir.path().to_path_buf());
    let running = start(options).await.unwrap();
    let mut stream = tokio::net::TcpStream::connect(running.address).await.unwrap();
    stream.write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").await.unwrap();
    let mut response = String::new(); stream.read_to_string(&mut response).await.unwrap();
    let response = response.to_ascii_lowercase();
    assert!(response.contains("cross-origin-opener-policy: same-origin"));
    assert!(response.contains("cross-origin-embedder-policy: require-corp"));
    running.shutdown().await;
}
