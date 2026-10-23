use crate::document::{Document, MAX_SESSION, MAX_UPDATE};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{Notify, Semaphore, mpsc},
    task::JoinSet,
};
use tokio_tungstenite::{
    accept_async_with_config, connect_async_with_config,
    tungstenite::{Message, protocol::WebSocketConfig},
};

pub const VERSION: u32 = 1;
const MAX_WIRE: usize = MAX_UPDATE * 4 / 3 + 4096;
const MAX_PEERS: usize = 8;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PeerInfo {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case", deny_unknown_fields)]
pub enum Wire {
    Hello {
        v: u32,
        token: String,
        peer: String,
        name: String,
    },
    Welcome {
        v: u32,
        file: String,
        state: String,
        vector: String,
    },
    Sync {
        id: u64,
        update: String,
    },
    Update {
        peer: String,
        update: String,
    },
    Ack {
        id: u64,
    },
    Presence {
        caret: String,
        anchor: String,
    },
    Cursor {
        peer: String,
        caret: String,
        anchor: String,
    },
    Peers {
        list: Vec<PeerInfo>,
    },
    Error {
        code: String,
        message: String,
    },
    RoomClosed,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub host: bool,
    #[serde(default)]
    pub invite: String,
    pub name: String,
    #[serde(default)]
    pub file: String,
    #[serde(default)]
    pub state: String,
}
struct Queued {
    message: Wire,
    bytes: usize,
    budget: Arc<AtomicUsize>,
}
impl Drop for Queued {
    fn drop(&mut self) {
        self.budget.fetch_sub(self.bytes, Ordering::Relaxed);
    }
}
enum Command {
    Send(Queued),
    Pause(bool),
}
type Wake = Option<unsafe extern "C" fn() -> bool>;
struct Events {
    list: VecDeque<Value>,
    bytes: usize,
}

/// Network workers own no managed objects. A closed handle cancels all its tasks.
pub struct Session {
    commands: mpsc::Sender<Command>,
    queued_bytes: Arc<AtomicUsize>,
    events: Mutex<Events>,
    stopped: AtomicBool,
    cancel: Notify,
    wake: Wake,
}

fn valid_id(value: &str) -> bool {
    (16..=64).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
}
pub fn invite_address(invite: &str) -> Result<(String, String), String> {
    let uri: tokio_tungstenite::tungstenite::http::Uri =
        invite.parse().map_err(|_| "Invalid Jam invitation")?;
    if uri.scheme_str() != Some("ws") || uri.query().is_some() {
        return Err("Local Jam requires a loopback ws:// invitation".into());
    }
    let addr: SocketAddr = uri
        .authority()
        .ok_or("Missing Jam address")?
        .as_str()
        .parse()
        .map_err(|_| "Local Jam requires a numeric loopback address")?;
    if !addr.ip().is_loopback() || addr.port() == 0 {
        return Err(
            "Local Jam only accepts loopback addresses; use an SSH tunnel for another machine"
                .into(),
        );
    }
    let token = uri
        .path()
        .strip_prefix("/jam/")
        .ok_or("Invalid Jam invitation")?;
    if !valid_id(token) {
        return Err("Invalid Jam invitation".into());
    }
    Ok((invite.to_owned(), token.to_owned()))
}
fn config() -> WebSocketConfig {
    WebSocketConfig::default()
        .read_buffer_size(4096)
        .write_buffer_size(0)
        .max_write_buffer_size(MAX_WIRE * 2)
        .max_message_size(Some(MAX_WIRE))
        .max_frame_size(Some(MAX_WIRE))
}
fn packet(message: &Wire) -> Message {
    Message::Text(serde_json::to_string(message).unwrap().into())
}
fn parse(message: Message) -> Result<Option<Wire>, String> {
    match message {
        Message::Text(text) if text.len() <= MAX_WIRE => serde_json::from_str(&text)
            .map(Some)
            .map_err(|_| "Invalid Jam message".into()),
        Message::Ping(_) | Message::Pong(_) => Ok(None),
        _ => Err("Jam expects a text protocol message".into()),
    }
}

impl Session {
    pub fn start(config: Config, wake: Wake) -> Result<Arc<Self>, String> {
        if config.name.trim().is_empty() || config.name.len() > 64 {
            return Err("Choose a Jam name of 1–64 bytes".into());
        }
        if config.host {
            if config.file.is_empty()
                || config.file.len() > 255
                || config.file.contains(['/', '\\'])
                || config.file == "."
                || config.file == ".."
            {
                return Err("Invalid shared document name".into());
            }
            if config.state.len() > MAX_WIRE - 4096 {
                return Err("Jam seed exceeds its limit".into());
            }
        } else {
            invite_address(&config.invite)?;
        }
        let (tx, rx) = mpsc::channel(64);
        let session = Arc::new(Self {
            commands: tx,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            events: Mutex::new(Events {
                list: VecDeque::new(),
                bytes: 0,
            }),
            stopped: AtomicBool::new(false),
            cancel: Notify::new(),
            wake,
        });
        let worker = session.clone();
        std::thread::Builder::new()
            .name("rayde-jam".into())
            .stack_size(2 << 20)
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|e| e.to_string())?;
                    runtime.block_on(worker.run(config, rx))
                }));
                match result {
                    Ok(Err(error)) => worker.push(json!({"t":"failed","message":error})),
                    Err(_) => worker.push(json!({"t":"failed","message":"Jam worker failed"})),
                    _ => {}
                }
                worker.stopped.store(true, Ordering::Release);
            })
            .map_err(|e| e.to_string())?;
        Ok(session)
    }
    fn push(&self, event: Value) {
        let size = event.to_string().len();
        let mut events = self.events.lock().unwrap();
        if events.bytes + size > MAX_SESSION || events.list.len() >= 128 {
            events.list.clear();
            events.bytes = 0;
            events.list.push_back(
                json!({"t":"failed","message":"Jam receiver is too slow; leave and rejoin"}),
            );
            self.close();
        } else {
            events.bytes += size;
            events.list.push_back(event);
        }
        drop(events);
        if let Some(wake) = self.wake {
            unsafe {
                wake();
            }
        }
    }
    pub fn poll(&self) -> Vec<Value> {
        let mut events = self.events.lock().unwrap();
        events.bytes = 0;
        events.list.drain(..).collect()
    }
    pub fn pending(&self) -> bool {
        !self.events.lock().unwrap().list.is_empty()
    }
    pub fn can_wake(&self) -> bool {
        self.wake.is_some()
    }
    pub fn send(&self, value: Value) -> bool {
        if self.stopped.load(Ordering::Acquire) {
            return false;
        }
        let command = if value["t"] == "pause" {
            Command::Pause(value["paused"].as_bool().unwrap_or(true))
        } else {
            let Ok(message) = serde_json::from_value::<Wire>(value) else {
                return false;
            };
            let bytes = match &message {
                Wire::Sync { update, .. } if update.len() <= MAX_WIRE - 4096 => update.len() + 128,
                Wire::Presence { caret, anchor } if caret.len() <= 256 && anchor.len() <= 256 => {
                    caret.len() + anchor.len() + 128
                }
                _ => return false,
            };
            let mut current = self.queued_bytes.load(Ordering::Relaxed);
            let reserved = loop {
                let Some(next) = current.checked_add(bytes).filter(|n| *n <= MAX_SESSION) else {
                    break false;
                };
                match self.queued_bytes.compare_exchange_weak(
                    current,
                    next,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => break true,
                    Err(actual) => current = actual,
                }
            };
            if !reserved {
                self.push(
                    json!({"t":"failed","message":"Jam send budget is full; leave and rejoin"}),
                );
                self.close();
                return false;
            }
            Command::Send(Queued {
                message,
                bytes,
                budget: self.queued_bytes.clone(),
            })
        };
        if self.commands.try_send(command).is_err() {
            self.push(json!({"t":"failed","message":"Jam send queue is full; leave and rejoin"}));
            self.close();
            return false;
        }
        true
    }
    pub fn close(&self) {
        self.stopped.store(true, Ordering::Release);
        self.cancel.notify_one();
    }

    async fn run(&self, config: Config, commands: mpsc::Receiver<Command>) -> Result<(), String> {
        let peer = Document::new("")?.id();
        let mut server = JoinSet::new();
        let mut local_room = None;
        let (url, token) = if config.host {
            let listener = TcpListener::bind("127.0.0.1:0")
                .await
                .map_err(|e| e.to_string())?;
            let mut secret = [0u8; 32];
            getrandom::fill(&mut secret).map_err(|_| "Cannot create a Jam invitation")?;
            let token: String = secret.iter().map(|byte| format!("{byte:02x}")).collect();
            let invite = format!(
                "ws://{}/jam/{token}",
                listener.local_addr().map_err(|e| e.to_string())?
            );
            let mut doc = Document::new("")?;
            doc.apply(&config.state)?;
            let room = Room {
                doc,
                token: token.clone(),
                file: config.file,
                peers: HashMap::new(),
                bytes: 0,
            };
            let room = Arc::new(Mutex::new(room));
            local_room = Some(room.clone());
            server.spawn(serve(listener, room));
            self.push(json!({"t":"hosting","invite":invite}));
            (invite, token)
        } else {
            invite_address(&config.invite)?
        };
        let result = self.connect(url, token, peer, config.name, commands).await;
        if let Some(room) = local_room {
            room.lock().unwrap().broadcast(Wire::RoomClosed, "");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        server.abort_all();
        result
    }

    async fn connect(
        &self,
        url: String,
        token: String,
        peer: String,
        name: String,
        mut commands: mpsc::Receiver<Command>,
    ) -> Result<(), String> {
        self.push(json!({"t":"identity","peer":peer}));
        let mut paused = false;
        loop {
            if self.stopped.load(Ordering::Acquire) {
                return Ok(());
            }
            if paused {
                tokio::select! { _ = self.cancel.notified() => return Ok(()), next = commands.recv() => match next { Some(Command::Pause(false)) => paused=false, None => return Ok(()), _ => {} } }
                continue;
            }
            let connected = tokio::select! {
                _ = self.cancel.notified() => return Ok(()),
                result = tokio::time::timeout(Duration::from_secs(5),connect_async_with_config(&url,Some(self::config()),true)) => result,
            };
            if let Ok(Ok((mut socket, _))) = connected {
                let hello = Wire::Hello {
                    v: VERSION,
                    token: token.clone(),
                    peer: peer.clone(),
                    name: name.clone(),
                };
                if tokio::time::timeout(Duration::from_secs(3), socket.send(packet(&hello)))
                    .await
                    .is_ok_and(|r| r.is_ok())
                {
                    let mut welcomed = false;
                    let handshake = tokio::time::sleep(Duration::from_secs(5));
                    tokio::pin!(handshake);
                    loop {
                        tokio::select! {
                            _ = self.cancel.notified() => return Ok(()),
                            _ = &mut handshake, if !welcomed => break,
                            next = commands.recv() => match next {
                                Some(Command::Pause(true)) => { paused=true; break; },
                                Some(Command::Send(message)) if welcomed && !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&message.message))).await.is_ok_and(|r|r.is_ok()) => break,
                                None => return Ok(()), _ => {},
                            },
                            next = socket.next() => match next {
                                Some(Ok(message)) => match parse(message) {
                                    Ok(Some(Wire::Error {message,..})) => return Err(message),
                                    Ok(Some(Wire::RoomClosed)) => { self.push(json!({"t":"room_closed"})); return Ok(()); },
                                    Ok(Some(message @ Wire::Welcome {v:VERSION,..})) if !welcomed => { welcomed=true; self.push(serde_json::to_value(message).unwrap()); },
                                    Ok(Some(Wire::Welcome {..})) => return Err("Incompatible Jam protocol".into()),
                                    Ok(Some(message @ (Wire::Update {..}|Wire::Ack {..}|Wire::Peers {..}|Wire::Cursor {..}))) if welcomed => self.push(serde_json::to_value(message).unwrap()),
                                    Ok(None) => {}, _ => break,
                                }, _ => break,
                            }
                        }
                    }
                }
            }
            self.push(json!({"t":if paused {"paused"} else {"reconnecting"}}));
            // Updates are reconstructed from the CRDT on the next welcome; stale presence is disposable.
            while let Ok(command) = commands.try_recv() {
                if let Command::Pause(on) = command {
                    paused = on;
                }
            }
            if !paused {
                tokio::select! { _ = self.cancel.notified() => return Ok(()), _ = tokio::time::sleep(Duration::from_secs(1)) => {} }
            }
        }
    }
}

struct Peer {
    info: PeerInfo,
    tx: mpsc::Sender<Wire>,
    cursor: Option<(String, String)>,
}
struct Room {
    doc: Document,
    token: String,
    file: String,
    peers: HashMap<String, Peer>,
    bytes: usize,
}
impl Room {
    fn broadcast(&mut self, message: Wire, except: &str) {
        self.peers
            .retain(|id, peer| id == except || peer.tx.try_send(message.clone()).is_ok());
    }
    fn presence(&mut self) {
        let list = self.peers.values().map(|p| p.info.clone()).collect();
        self.broadcast(Wire::Peers { list }, "");
    }
    fn process(&mut self, peer: &str, message: Wire) -> Result<(), String> {
        match message {
            Wire::Sync { id, update } => {
                self.bytes += update.len();
                if self.bytes > MAX_SESSION {
                    return Err("Local Jam room limit reached; start a new room".into());
                }
                self.doc.apply(&update)?;
                self.broadcast(
                    Wire::Update {
                        peer: peer.into(),
                        update,
                    },
                    peer,
                );
                if let Some(p) = self.peers.get(peer) {
                    p.tx.try_send(Wire::Ack { id })
                        .map_err(|_| "Jam participant is too slow")?;
                }
            }
            Wire::Presence { caret, anchor } if caret.len() <= 256 && anchor.len() <= 256 => {
                self.doc.resolve(&caret)?;
                self.doc.resolve(&anchor)?;
                if let Some(p) = self.peers.get_mut(peer) {
                    p.cursor = Some((caret.clone(), anchor.clone()));
                }
                self.broadcast(
                    Wire::Cursor {
                        peer: peer.into(),
                        caret,
                        anchor,
                    },
                    peer,
                );
            }
            _ => return Err("Unexpected Jam message".into()),
        }
        Ok(())
    }
}
async fn serve(listener: TcpListener, room: Arc<Mutex<Room>>) {
    let gate = Arc::new(Semaphore::new(MAX_PEERS));
    let mut tasks = JoinSet::new();
    loop {
        tokio::select! {
            next = listener.accept() => if let Ok((socket,_)) = next && let Ok(permit) = gate.clone().try_acquire_owned() {
                let room = room.clone(); tasks.spawn(async move { let _permit=permit; serve_peer(socket,room).await; });
            },
            _ = tasks.join_next(), if !tasks.is_empty() => {},
        }
    }
}
async fn serve_peer(stream: TcpStream, room: Arc<Mutex<Room>>) {
    let _ = stream.set_nodelay(true);
    let Ok(Ok(mut socket)) = tokio::time::timeout(
        Duration::from_secs(5),
        accept_async_with_config(stream, Some(config())),
    )
    .await
    else {
        return;
    };
    let Ok(Some(Ok(first))) = tokio::time::timeout(Duration::from_secs(5), socket.next()).await
    else {
        return;
    };
    let Ok(Some(Wire::Hello {
        v,
        token,
        peer,
        name,
    })) = parse(first)
    else {
        return;
    };
    let error = if v != VERSION {
        Some("Incompatible Jam protocol")
    } else if !valid_id(&peer) || name.trim().is_empty() || name.len() > 64 {
        Some("Invalid Jam participant")
    } else if room.lock().unwrap().token != token {
        Some("Invalid Jam invitation")
    } else {
        None
    };
    if let Some(error) = error {
        let _ = socket
            .send(packet(&Wire::Error {
                code: "join_rejected".into(),
                message: error.into(),
            }))
            .await;
        return;
    }
    let (tx, mut rx) = mpsc::channel(32);
    let connection = tx.clone();
    {
        let mut room = room.lock().unwrap();
        let welcome = Wire::Welcome {
            v: VERSION,
            file: room.file.clone(),
            state: room.doc.state(),
            vector: room.doc.vector(),
        };
        let _ = tx.try_send(welcome);
        for (id, p) in &room.peers {
            if let Some((caret, anchor)) = &p.cursor {
                let _ = tx.try_send(Wire::Cursor {
                    peer: id.clone(),
                    caret: caret.clone(),
                    anchor: anchor.clone(),
                });
            }
        }
        room.peers.insert(
            peer.clone(),
            Peer {
                info: PeerInfo {
                    id: peer.clone(),
                    name,
                },
                tx,
                cursor: None,
            },
        );
        room.presence();
    }
    loop {
        tokio::select! {
            next = rx.recv() => match next {
                Some(message) => if !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&message))).await.is_ok_and(|r|r.is_ok()) { break; },
                None => break,
            },
            next = socket.next() => match next {
                Some(Ok(message)) => match parse(message) {
                    Ok(Some(message)) => {
                        let result = room.lock().unwrap().process(&peer,message);
                        if let Err(message) = result { let _=socket.send(packet(&Wire::Error {code:"invalid_update".into(),message})).await; break; }
                    }, Ok(None) => {}, _ => break,
                }, _ => break,
            }
        }
    }
    let mut room = room.lock().unwrap();
    if room
        .peers
        .get(&peer)
        .is_some_and(|p| p.tx.same_channel(&connection))
    {
        room.peers.remove(&peer);
        room.presence();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn until(
        session: &Session,
        events: &mut Vec<Value>,
        predicate: impl Fn(&Value) -> bool,
    ) -> Value {
        let end = std::time::Instant::now() + Duration::from_secs(8);
        loop {
            events.extend(session.poll());
            if let Some(index) = events.iter().position(&predicate) {
                return events.remove(index);
            }
            assert!(
                std::time::Instant::now() < end,
                "Jam event timeout: {events:?}"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn welcome(session: &Session, doc: &mut Document, events: &mut Vec<Value>, id: u64) {
        let event = until(session, events, |e| e["t"] == "welcome");
        doc.apply(event["state"].as_str().unwrap()).unwrap();
        assert!(session.send(json!({"t":"sync","id":id,"update":doc.diff(event["vector"].as_str().unwrap()).unwrap()})));
        until(session, events, |e| e["t"] == "ack" && e["id"] == id);
    }
    #[test]
    fn real_websocket_edit_presence_reconnect_and_close() {
        let mut a = Document::new("hello 🦀").unwrap();
        let mut b = Document::new("").unwrap();
        let host = Session::start(
            Config {
                host: true,
                invite: String::new(),
                name: "Host".into(),
                file: "Main.hx".into(),
                state: a.state(),
            },
            None,
        )
        .unwrap();
        let mut ha = vec![];
        let mut hb = vec![];
        let invite = until(&host, &mut ha, |e| e["t"] == "hosting")["invite"]
            .as_str()
            .unwrap()
            .to_string();
        welcome(&host, &mut a, &mut ha, 1);
        let guest = Session::start(
            Config {
                host: false,
                invite,
                name: "Guest".into(),
                file: String::new(),
                state: String::new(),
            },
            None,
        )
        .unwrap();
        welcome(&guest, &mut b, &mut hb, 1);
        assert_eq!(a.text(), b.text());
        host.send(json!({"t":"sync","id":2,"update":a.edit("hello 🦀",&[crate::document::Patch {from:6,removed:"🦀".into(),inserted:"world".into()}]).unwrap()}));
        let event = until(&guest, &mut hb, |e| e["t"] == "update");
        b.apply(event["update"].as_str().unwrap()).unwrap();
        assert_eq!(a.text(), b.text());
        guest.send(
            json!({"t":"presence","caret":b.position(11).unwrap(),"anchor":b.position(6).unwrap()}),
        );
        let cursor = until(&host, &mut ha, |e| e["t"] == "cursor");
        assert_eq!(a.resolve(cursor["caret"].as_str().unwrap()).unwrap(), 11);
        guest.send(json!({"t":"pause","paused":true}));
        until(&guest, &mut hb, |e| e["t"] == "paused");
        b.edit(
            "hello world",
            &[crate::document::Patch {
                from: 11,
                removed: "".into(),
                inserted: " offline".into(),
            }],
        )
        .unwrap();
        guest.send(json!({"t":"pause","paused":false}));
        welcome(&guest, &mut b, &mut hb, 3);
        loop {
            let e = until(&host, &mut ha, |e| e["t"] == "update");
            a.apply(e["update"].as_str().unwrap()).unwrap();
            if a.text() == b.text() {
                break;
            }
        }
        assert_eq!(a.text(), "hello world offline");
        guest.send(json!({"t":"sync","id":4,"update":b.undo(false)}));
        let e = until(&host, &mut ha, |e| e["t"] == "update");
        a.apply(e["update"].as_str().unwrap()).unwrap();
        assert_eq!(a.text(), "hello world");
        host.close();
        until(&guest, &mut hb, |e| e["t"] == "room_closed");
        guest.close();
        let end = std::time::Instant::now() + Duration::from_secs(3);
        while Arc::strong_count(&host) > 1 || Arc::strong_count(&guest) > 1 {
            assert!(
                std::time::Instant::now() < end,
                "Jam worker retained after close"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[tokio::test(flavor = "current_thread")]
    async fn rejects_wrong_version_token_and_invalid_updates() {
        let seed = Document::new("safe").unwrap();
        let room = Arc::new(Mutex::new(Room {
            doc: seed,
            token: "0123456789abcdef".into(),
            file: "Main.hx".into(),
            peers: HashMap::new(),
            bytes: 0,
        }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(serve(listener, room.clone()));
        for (version, token) in [(2, "0123456789abcdef"), (1, "bad")] {
            let (mut ws, _) = connect_async_with_config(
                format!("ws://{addr}/jam/0123456789abcdef"),
                Some(config()),
                true,
            )
            .await
            .unwrap();
            ws.send(packet(&Wire::Hello {
                v: version,
                token: token.into(),
                peer: Document::new("").unwrap().id(),
                name: "Test".into(),
            }))
            .await
            .unwrap();
            let message = ws.next().await.unwrap().unwrap();
            assert!(matches!(parse(message).unwrap(), Some(Wire::Error { .. })));
        }
        let (mut ws, _) = connect_async_with_config(
            format!("ws://{addr}/jam/0123456789abcdef"),
            Some(config()),
            true,
        )
        .await
        .unwrap();
        ws.send(packet(&Wire::Hello {
            v: VERSION,
            token: "0123456789abcdef".into(),
            peer: Document::new("").unwrap().id(),
            name: "Test".into(),
        }))
        .await
        .unwrap();
        assert!(matches!(
            parse(ws.next().await.unwrap().unwrap()).unwrap(),
            Some(Wire::Welcome { .. })
        ));
        ws.send(packet(&Wire::Sync {
            id: 1,
            update: "invalid!".into(),
        }))
        .await
        .unwrap();
        loop {
            if matches!(
                parse(ws.next().await.unwrap().unwrap()).unwrap(),
                Some(Wire::Error { .. })
            ) {
                break;
            }
        }
        assert_eq!(room.lock().unwrap().doc.text(), "safe");
        server.abort();
    }
    #[test]
    fn slow_sender_has_a_byte_budget_and_releases_it_on_cancel() {
        let (tx, rx) = mpsc::channel(64);
        let session = Session {
            commands: tx,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            events: Mutex::new(Events {
                list: VecDeque::new(),
                bytes: 0,
            }),
            stopped: AtomicBool::new(false),
            cancel: Notify::new(),
            wake: None,
        };
        for id in 0..3 {
            assert!(session.send(json!({"t":"sync","id":id,"update":"x".repeat(MAX_UPDATE)})));
        }
        assert!(!session.send(json!({"t":"sync","id":4,"update":"x".repeat(MAX_UPDATE)})));
        assert!(session.queued_bytes.load(Ordering::Relaxed) <= MAX_SESSION);
        drop(rx);
        assert_eq!(session.queued_bytes.load(Ordering::Relaxed), 0);
    }
    #[test]
    fn local_invites_and_strict_wire() {
        assert!(invite_address("ws://127.0.0.1:1234/jam/0123456789abcdef0123456789abcdef").is_ok());
        for url in [
            "ws://example.com:1234/jam/0123456789abcdef",
            "ws://192.168.1.1:1234/jam/0123456789abcdef",
            "ws://127.0.0.1:0/jam/0123456789abcdef",
            "ws://127.0.0.1:1234/jam/x",
            "ws://127.0.0.1:1234/jam/0123456789abcdef?token=secret",
        ] {
            assert!(invite_address(url).is_err());
        }
        assert!(
            serde_json::from_str::<Wire>(r#"{"t":"sync","id":1,"update":"AA==","extra":true}"#)
                .is_err()
        );
    }
}
