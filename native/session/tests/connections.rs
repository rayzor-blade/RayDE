use futures_util::{SinkExt, StreamExt};
use rayde_session::{
    auth::{Identity, SignedCredentials},
    server::{Options, Running, frame, start},
    session::{MAX_CONNECTIONS, MAX_IDENTITY_CONNECTIONS},
};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream,
    tungstenite::{Error, Message},
};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

async fn connect(server: &Running) -> Result<Socket, Error> {
    tokio_tungstenite::connect_async(format!("ws://{}/session", server.address))
        .await
        .map(|(socket, _)| socket)
}

async fn rpc(socket: &mut Socket, mut request: Value) -> Value {
    request["id"] = json!(1);
    socket
        .send(Message::Text(request.to_string().into()))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Message::Text(text) = socket.next().await.unwrap().unwrap() {
                let reply: Value = serde_json::from_str(&text).unwrap();
                if reply["id"] == 1 {
                    return reply;
                }
            }
        }
    })
    .await
    .unwrap()
}

async fn hello(server: &Running) -> Socket {
    let mut socket = connect(server).await.unwrap();
    assert_eq!(rpc(&mut socket, json!({"op":"hello"})).await["ok"], true);
    socket
}

async fn raw_reply(stream: &mut TcpStream) -> Value {
    tokio::time::timeout(Duration::from_secs(5), async {
        let length = stream.read_u32().await.unwrap();
        let mut bytes = vec![0; length as usize];
        stream.read_exact(&mut bytes).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    })
    .await
    .unwrap()
}

async fn reconnect(server: &Running) -> Socket {
    for _ in 0..100 {
        match connect(server).await {
            Ok(mut socket) => {
                assert_eq!(rpc(&mut socket, json!({"op":"hello"})).await["ok"], true);
                return socket;
            }
            Err(Error::Http(reply)) if reply.status() == 429 => {
                tokio::time::sleep(Duration::from_millis(20)).await
            }
            result => panic!("Unexpected reconnect result: {result:?}"),
        }
    }
    panic!("Disconnected socket did not release its slot");
}

#[tokio::test]
async fn websocket_and_tcp_share_atomic_admission_and_release_slots_on_disconnect() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.raw = Some(([127, 0, 0, 1], 0).into());
    let server = start(options).await.unwrap();
    let mut clients = Vec::new();
    for _ in 0..MAX_CONNECTIONS - 2 {
        clients.push(hello(&server).await);
    }
    let mut raw = TcpStream::connect(server.raw_address.unwrap())
        .await
        .unwrap();
    raw.write_all(&frame(r#"{"id":1,"op":"hello"}"#))
        .await
        .unwrap();
    assert_eq!(raw_reply(&mut raw).await["ok"], true);

    let (a, b) = tokio::join!(connect(&server), connect(&server));
    let mut accepted = 0;
    for result in [a, b] {
        match result {
            Ok(mut socket) => {
                accepted += 1;
                assert_eq!(rpc(&mut socket, json!({"op":"hello"})).await["ok"], true);
                clients.push(socket);
            }
            Err(Error::Http(reply)) => assert_eq!(reply.status(), 429),
            result => panic!("Unexpected admission result: {result:?}"),
        }
    }
    assert_eq!(accepted, 1, "only one contender may reserve the last slot");
    let mut refused = TcpStream::connect(server.raw_address.unwrap())
        .await
        .unwrap();
    assert_eq!(raw_reply(&mut refused).await["code"], "busy");

    clients.pop().unwrap().close(None).await.unwrap();
    clients.push(reconnect(&server).await);
    drop(raw);
    clients.push(reconnect(&server).await);
    assert!(matches!(connect(&server).await, Err(Error::Http(reply)) if reply.status() == 429));
    for mut client in clients {
        let _ = client.close(None).await;
    }
    server.shutdown().await;
}

#[tokio::test]
async fn verified_account_admission_is_atomic_and_reauthentication_does_not_leak_slots() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.authority = Some(Arc::new(SignedCredentials::new(
        b"edge".to_vec(),
        "https://example/login",
    )));
    let server = start(options).await.unwrap();
    let edge = SignedCredentials::new(b"edge".to_vec(), "https://example/login");
    let expiry = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 600;
    let credential = |id, login: &str| {
        edge.issue(
            &Identity {
                id,
                login: login.into(),
            },
            expiry,
        )
    };
    let login = |id, name| json!({"op":"auth.login","credential":credential(id, name)});
    let mut clients = Vec::new();
    for _ in 0..MAX_IDENTITY_CONNECTIONS - 1 {
        let mut client = hello(&server).await;
        assert_eq!(rpc(&mut client, login(1, "alice")).await["ok"], true);
        clients.push(client);
    }
    let mut bob = hello(&server).await;
    assert_eq!(rpc(&mut bob, login(2, "bob")).await["ok"], true);
    let (mut a, mut b) = (hello(&server).await, hello(&server).await);
    let (a_result, b_result) = tokio::join!(
        rpc(&mut a, login(1, "alice")),
        rpc(&mut b, login(1, "alice"))
    );
    assert_ne!(a_result["ok"], b_result["ok"]);
    let (mut winner, mut viewer, refused) = if a_result["ok"] == true {
        (a, b, b_result)
    } else {
        (b, a, a_result)
    };
    assert_eq!(refused["code"], "busy");
    assert_eq!(
        rpc(&mut viewer, json!({"op":"hello"})).await["cacheIdentity"]["principal"],
        "viewer"
    );
    assert_eq!(
        rpc(
            &mut viewer,
            json!({"op":"auth.login","credential":"invalid"})
        )
        .await["code"],
        "unauthorised"
    );
    for _ in 0..MAX_IDENTITY_CONNECTIONS * 2 {
        assert_eq!(
            rpc(&mut winner, login(1, "renamed-alice")).await["ok"],
            true
        );
        assert_eq!(
            rpc(&mut winner, json!({"op":"hello"})).await["cacheIdentity"]["principal"],
            "account:1"
        );
    }
    assert_eq!(rpc(&mut bob, login(1, "alice")).await["code"], "busy");
    assert_eq!(
        rpc(&mut bob, json!({"op":"hello"})).await["cacheIdentity"]["principal"],
        "account:2"
    );
    drop(winner);
    let mut admitted = false;
    for _ in 0..100 {
        let reply = rpc(&mut viewer, login(1, "alice")).await;
        if reply["ok"] == true {
            admitted = true;
            break;
        }
        assert_eq!(reply["code"], "busy");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(admitted, "abrupt disconnect must release the account slot");
    assert_eq!(rpc(&mut bob, login(3, "carol")).await["ok"], true);
    let mut bob_again = hello(&server).await;
    assert_eq!(rpc(&mut bob_again, login(2, "bob")).await["ok"], true);
    for mut client in clients.into_iter().chain([viewer, bob, bob_again]) {
        let _ = client.close(None).await;
    }
    server.shutdown().await;
}

#[tokio::test]
async fn idle_and_failed_hello_deadlines_close_both_transports_but_keep_ready_clients() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut options = Options::new(root.path());
    options.state_root = Some(state.path().into());
    options.token = Some("secret".into());
    options.raw = Some(([127, 0, 0, 1], 0).into());
    let server = start(options).await.unwrap();
    let mut ready = connect(&server).await.unwrap();
    assert_eq!(
        rpc(&mut ready, json!({"op":"hello","token":"secret"})).await["ok"],
        true
    );
    let mut idle = connect(&server).await.unwrap();
    assert_eq!(
        rpc(&mut idle, json!({"op":"hello","token":"wrong"})).await["code"],
        "unauthorised"
    );
    let mut raw = TcpStream::connect(server.raw_address.unwrap())
        .await
        .unwrap();
    raw.write_all(&[0, 0]).await.unwrap();
    tokio::time::timeout(Duration::from_secs(12), async {
        let mut byte = [0u8; 1];
        let (closed, count) = tokio::join!(idle.next(), raw.read(&mut byte));
        assert!(!matches!(closed, Some(Ok(Message::Text(_)))));
        assert_eq!(count.unwrap(), 0);
    })
    .await
    .expect("unauthenticated clients must not retain slots indefinitely");
    assert_eq!(rpc(&mut ready, json!({"op":"fs.list"})).await["ok"], true);
    let _ = ready.close(None).await;
    server.shutdown().await;
}
