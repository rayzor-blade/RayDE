use crate::{
    document::{Document, MAX_SESSION, MAX_UPDATE},
    recovery::Recovery,
    workspace::{self, Message as WorkspaceMessage, Surface},
};
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
    sync::{Notify, Semaphore, mpsc, watch},
    task::JoinSet,
};
use tokio_tungstenite::{
    accept_async_with_config, connect_async_with_config,
    tungstenite::{Message, protocol::WebSocketConfig},
};

pub const VERSION: u32 = 3;
const MAX_WIRE: usize = MAX_UPDATE * 4 / 3 + 4096;
const MAX_PEERS: usize = 8;
fn is_false(value: &bool) -> bool {
    !value
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PeerInfo {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Viewport {
    pub top: String,
    pub offset: f64,
    pub x: f64,
}
impl Viewport {
    pub(crate) fn valid(&self) -> bool {
        self.top.len() <= 256
            && self.offset.is_finite()
            && (-16.0..1.0).contains(&self.offset)
            && self.x.is_finite()
            && (0.0..=1_000_000.0).contains(&self.x)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case", deny_unknown_fields)]
pub enum Wire {
    Hello {
        v: u32,
        token: String,
        peer: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        owner: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")]
        workspace: bool,
    },
    Welcome {
        v: u32,
        file: String,
        state: String,
        vector: String,
        #[serde(default)]
        document_id: String,
        #[serde(default)]
        durable: bool,
        #[serde(default, skip_serializing_if = "is_false")]
        workspace: bool,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        view: Option<Viewport>,
    },
    Cursor {
        peer: String,
        caret: String,
        anchor: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        view: Option<Viewport>,
    },
    Peers {
        list: Vec<PeerInfo>,
    },
    Error {
        code: String,
        message: String,
    },
    Workspace {
        message: WorkspaceMessage,
    },
    RoomClosed,
}

#[derive(Default, Deserialize)]
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
    #[serde(default)]
    pub document_id: String,
    #[serde(default)]
    pub recovery: String,
    #[serde(default)]
    pub restore: bool,
    #[serde(default)]
    pub workspace: bool,
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
    Checkpoint(u64),
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
    workspace: bool,
    host: bool,
    frame: Mutex<Option<workspace::Frame>>,
    frame_ready: Notify,
    desired: Mutex<Option<Surface>>,
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
            workspace: config.workspace,
            host: config.host,
            frame: Mutex::new(None),
            frame_ready: Notify::new(),
            desired: Mutex::new(None),
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
        let cursor = event["t"] == "cursor"
            || (event["t"] == "workspace" && event["message"]["t"] == "cursor");
        let frame = event["t"] == "workspace" && event["message"]["t"] == "frame";
        if (cursor || frame)
            && let Some(index) = events.list.iter().position(|previous| {
                if frame {
                    previous["t"] == "workspace" && previous["message"]["t"] == "frame"
                } else if event["t"] == "workspace" {
                    previous["t"] == "workspace"
                        && previous["message"]["t"] == "cursor"
                        && previous["message"]["peer"] == event["message"]["peer"]
                        && previous["message"]["document"] == event["message"]["document"]
                } else {
                    previous["t"] == "cursor" && previous["peer"] == event["peer"]
                }
            })
        {
            let previous = events.list.remove(index).unwrap();
            events.bytes -= previous.to_string().len();
        }
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
        let command = if value["t"] == "checkpoint" {
            Command::Checkpoint(value["id"].as_u64().unwrap_or(0))
        } else if value["t"] == "pause" {
            Command::Pause(value["paused"].as_bool().unwrap_or(true))
        } else {
            let Ok(message) = serde_json::from_value::<Wire>(value) else {
                return false;
            };
            if let Wire::Workspace { message: workspace } = &message {
                if !self.workspace || !workspace.client_valid() {
                    return false;
                }
                if matches!(
                    workspace,
                    WorkspaceMessage::Open { .. }
                        | WorkspaceMessage::Activate { .. }
                        | WorkspaceMessage::Frame { .. }
                ) && !self.host
                {
                    return false;
                }
                if let WorkspaceMessage::Activate { surface } = workspace {
                    self.frame.lock().unwrap().take();
                    *self.desired.lock().unwrap() = Some(surface.clone());
                }
                if let WorkspaceMessage::Frame { frame } = workspace {
                    *self.frame.lock().unwrap() = Some(frame.clone());
                    self.frame_ready.notify_one();
                    return true;
                }
            }
            let bytes = match &message {
                Wire::Sync { update, .. } if update.len() <= MAX_WIRE - 4096 => update.len() + 128,
                Wire::Presence {
                    caret,
                    anchor,
                    view,
                } if caret.len() <= 256
                    && anchor.len() <= 256
                    && view.as_ref().is_none_or(Viewport::valid) =>
                {
                    caret.len() + anchor.len() + view.as_ref().map_or(0, |v| v.top.len() + 64) + 128
                }
                Wire::Workspace { .. } => {
                    serde_json::to_vec(&message).map_or(MAX_SESSION + 1, |bytes| bytes.len())
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
        self.frame.lock().unwrap().take();
    }

    async fn next_frame(&self) -> Wire {
        loop {
            if let Some(frame) = self.frame.lock().unwrap().take() {
                return Wire::Workspace {
                    message: WorkspaceMessage::Frame { frame },
                };
            }
            self.frame_ready.notified().await;
        }
    }

    async fn run(
        &self,
        config: Config,
        mut commands: mpsc::Receiver<Command>,
    ) -> Result<(), String> {
        let peer = Document::new("")?.id();
        let id = if config.host && config.document_id.is_empty() {
            peer.clone()
        } else {
            config.document_id
        };
        let recovery = Arc::new(Mutex::new(Recovery::open(
            &config.recovery,
            &config.file,
            config.restore,
            &id,
            &config.state,
        )?));
        let workspace = if config.workspace {
            Some(Arc::new(Mutex::new(workspace::Store::open(
                &config.recovery,
                config.restore,
            )?)))
        } else {
            None
        };
        if config.restore {
            let saved = recovery.lock().unwrap();
            self.push(json!({"t":"restored","document_id":saved.id,"file":saved.file,"state":saved.doc.state()}));
            if let Some(workspace) = &workspace {
                for message in workspace.lock().unwrap().snapshots() {
                    if let WorkspaceMessage::Document {
                        document,
                        file,
                        state,
                        ..
                    } = message
                    {
                        self.push(json!({"t":"workspace","message":{"t":"restored","document":document,"file":file,"state":state}}));
                    }
                }
            }
        }
        let mut server = JoinSet::new();
        let mut local_room = None;
        let (fatal_tx, mut fatal_rx) = mpsc::channel(1);
        let mut owner = None;
        let (url, token) = if config.host {
            let listener = TcpListener::bind("127.0.0.1:0")
                .await
                .map_err(|_| "Cannot listen for a local Jam")?;
            let mut secret = [0u8; 32];
            getrandom::fill(&mut secret).map_err(|_| "Cannot create a Jam invitation")?;
            let token: String = secret.iter().map(|byte| format!("{byte:02x}")).collect();
            getrandom::fill(&mut secret).map_err(|_| "Cannot create a Jam host credential")?;
            owner = Some(
                secret
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>(),
            );
            let invite = format!(
                "ws://{}/jam/{token}",
                listener
                    .local_addr()
                    .map_err(|_| "Cannot read Jam address")?
            );
            let mut doc = Document::new("")?;
            doc.apply(&recovery.lock().unwrap().doc.state())?;
            let room = Arc::new(Mutex::new(Room {
                doc,
                token: token.clone(),
                file: config.file,
                peers: HashMap::new(),
                bytes: 0,
                recovery: recovery.clone(),
                fatal: fatal_tx.clone(),
                owner: owner.clone().unwrap(),
                workspace: workspace.clone(),
            }));
            local_room = Some(room.clone());
            server.spawn(serve(listener, room));
            self.push(json!({"t":"hosting","invite":invite}));
            (invite, token)
        } else {
            invite_address(&config.invite)?
        };
        let result = tokio::select! {
            result = self.connect(url, token, owner, peer, config.name, &mut commands, &recovery, &workspace) => result,
            Some(error) = fatal_rx.recv() => Err(error),
        };
        // Closing a view is non-blocking; the worker finishes already accepted local writes.
        commands.close();
        let mut paused = true;
        let mut result = result;
        while let Some(command) = commands.recv().await {
            if let Err(error) = self.local(command, &recovery, &workspace, &mut paused) {
                result = Err(error);
                break;
            }
        }
        if let Some(room) = local_room {
            room.lock().unwrap().broadcast(Wire::RoomClosed, "");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        server.abort_all();
        result
    }

    fn local(
        &self,
        command: Command,
        recovery: &Arc<Mutex<Recovery>>,
        workspace: &Option<Arc<Mutex<workspace::Store>>>,
        paused: &mut bool,
    ) -> Result<Option<Wire>, String> {
        match command {
            Command::Pause(on) => {
                *paused = on;
                Ok(None)
            }
            Command::Checkpoint(id) => {
                recovery.lock().unwrap().checkpoint()?;
                if let Some(workspace) = workspace {
                    workspace.lock().unwrap().checkpoint()?;
                }
                self.push(json!({"t":"checkpointed","id":id}));
                Ok(None)
            }
            Command::Send(message) => {
                if let Wire::Sync { id, update } = &message.message {
                    let mut saved = recovery.lock().unwrap();
                    saved.accept(update)?;
                    if saved.durable() {
                        self.push(json!({"t":"locally_saved","id":id}));
                    }
                }
                if let Wire::Workspace { message: operation } = &message.message {
                    let mut saved = workspace
                        .as_ref()
                        .ok_or("This Jam does not share a workspace")?
                        .lock()
                        .unwrap();
                    match operation {
                        WorkspaceMessage::Open {
                            document,
                            file,
                            state,
                        } if self.host => saved.adopt(document, file, state)?,
                        WorkspaceMessage::Sync {
                            document,
                            id,
                            update,
                        } => {
                            saved.accept(document, update)?;
                            if recovery.lock().unwrap().durable() {
                                self.push(json!({"t":"workspace","message":{"t":"locally_saved","document":document,"id":id}}));
                            }
                        }
                        _ => {}
                    }
                }
                Ok(Some(message.message.clone()))
            }
        }
    }

    async fn connect(
        &self,
        url: String,
        token: String,
        owner: Option<String>,
        peer: String,
        name: String,
        commands: &mut mpsc::Receiver<Command>,
        recovery: &Arc<Mutex<Recovery>>,
        workspace: &Option<Arc<Mutex<workspace::Store>>>,
    ) -> Result<(), String> {
        self.push(json!({"t":"identity","peer":peer}));
        let mut paused = false;
        loop {
            if self.stopped.load(Ordering::Acquire) {
                return Ok(());
            }
            if paused {
                tokio::select! {
                    _ = self.cancel.notified() => return Ok(()),
                    next = commands.recv() => match next {
                        Some(command) => { self.local(command,recovery,workspace,&mut paused)?; },
                        None => return Ok(()),
                    }
                }
                continue;
            }
            let connecting = tokio::time::timeout(
                Duration::from_secs(5),
                connect_async_with_config(&url, Some(self::config()), true),
            );
            tokio::pin!(connecting);
            let connected = loop {
                tokio::select! {
                    _ = self.cancel.notified() => return Ok(()),
                    result = &mut connecting => break Some(result),
                    next = commands.recv() => match next {
                        Some(command) => { self.local(command,recovery,workspace,&mut paused)?; if paused { break None; } },
                        None => return Ok(()),
                    }
                }
            };
            if let Some(Ok(Ok((mut socket, _)))) = connected {
                let hello = Wire::Hello {
                    v: VERSION,
                    token: token.clone(),
                    peer: peer.clone(),
                    name: name.clone(),
                    owner: owner.clone(),
                    workspace: self.workspace,
                };
                if tokio::time::timeout(Duration::from_secs(3), socket.send(packet(&hello)))
                    .await
                    .is_ok_and(|r| r.is_ok())
                {
                    let mut welcomed = false;
                    let handshake = tokio::time::sleep(Duration::from_secs(5));
                    tokio::pin!(handshake);
                    'connection: loop {
                        tokio::select! {
                            biased;
                            _ = self.cancel.notified() => return Ok(()),
                            _ = &mut handshake, if !welcomed => break,
                            next = commands.recv() => match next {
                                Some(command) => {
                                    let message=self.local(command,recovery,workspace,&mut paused)?;
                                    if paused { break; }
                                    if let Some(message)=message && welcomed && !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&message))).await.is_ok_and(|r|r.is_ok()) { break; }
                                },
                                None => return Ok(()),
                            },
                            next = socket.next() => match next {
                                Some(Ok(message)) => match parse(message) {
                                    Ok(Some(Wire::Error {message,..})) => return Err(message),
                                    Ok(Some(Wire::RoomClosed)) => { self.push(json!({"t":"room_closed"})); return Ok(()); },
                                    Ok(Some(message @ Wire::Welcome {v:VERSION,..})) if !welcomed => {
                                        if let Wire::Welcome {workspace,..} = &message && *workspace != self.workspace { return Err("This invitation uses a different Jam sharing mode".into()); }
                                        if let Wire::Welcome {document_id,file,state,..} = &message { recovery.lock().unwrap().adopt(document_id,file,state)?; }
                                        welcomed=true; self.push(serde_json::to_value(message).unwrap());
                                        if let Some(workspace) = workspace {
                                            let snapshots=workspace.lock().unwrap().snapshots();
                                            for snapshot in snapshots {
                                                if let WorkspaceMessage::Document {document,file,state,..} = snapshot {
                                                    let message=if self.host { WorkspaceMessage::Open {document,file,state} } else { WorkspaceMessage::Request {document} };
                                                    if !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&Wire::Workspace {message}))).await.is_ok_and(|r|r.is_ok()) { break 'connection; }
                                                }
                                            }
                                            let desired=self.desired.lock().unwrap().clone();
                                            if let Some(surface)=desired && !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&Wire::Workspace {message:WorkspaceMessage::Activate {surface}}))).await.is_ok_and(|r|r.is_ok()) { break 'connection; }
                                        }
                                    },
                                    Ok(Some(Wire::Welcome {..})) => return Err("Incompatible Jam protocol".into()),
                                    Ok(Some(message @ Wire::Update {..})) if welcomed => {
                                        if let Wire::Update {update,..} = &message { recovery.lock().unwrap().accept(update)?; }
                                        self.push(serde_json::to_value(message).unwrap());
                                    },
                                    Ok(Some(message @ (Wire::Ack {..}|Wire::Peers {..}|Wire::Cursor {..}))) if welcomed => self.push(serde_json::to_value(message).unwrap()),
                                    Ok(Some(message @ Wire::Workspace {..})) if welcomed && self.workspace => {
                                        if let Wire::Workspace { message: operation } = &message {
                                            let mut saved = workspace.as_ref().unwrap().lock().unwrap();
                                            match operation {
                                                WorkspaceMessage::Document { document, file, state, .. } => saved.adopt(document,file,state)?,
                                                WorkspaceMessage::Update { document, update, .. } => saved.accept(document,update)?,
                                                WorkspaceMessage::Active { surface } if surface.valid() => {},
                                                WorkspaceMessage::Frame { frame } if frame.valid() => {},
                                                WorkspaceMessage::Ack { .. } | WorkspaceMessage::Cursor { .. } => {},
                                                _ => return Err("Unexpected Jam workspace event".into()),
                                            }
                                        }
                                        self.push(serde_json::to_value(message).unwrap());
                                    },
                                    Ok(None) => {}, _ => break,
                                }, _ => break,
                            },
                            frame = self.next_frame(), if welcomed => {
                                if !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&frame))).await.is_ok_and(|r|r.is_ok()) { break; }
                            },
                        }
                    }
                }
            }
            self.push(json!({"t":if paused {"paused"} else {"reconnecting"}}));
            if !paused {
                let delay = tokio::time::sleep(Duration::from_secs(1));
                tokio::pin!(delay);
                loop {
                    tokio::select! {
                        _ = self.cancel.notified() => return Ok(()),
                        _ = &mut delay => break,
                        next = commands.recv() => match next {
                            Some(command) => { self.local(command,recovery,workspace,&mut paused)?; if paused { break; } },
                            None => return Ok(()),
                        }
                    }
                }
            }
        }
    }
}

struct Peer {
    info: PeerInfo,
    tx: mpsc::Sender<Wire>,
    cursor: Option<Wire>,
    workspace_cursors: HashMap<String, Wire>,
    visual: watch::Sender<Option<Wire>>,
    known: std::collections::HashSet<String>,
}
struct Room {
    doc: Document,
    token: String,
    file: String,
    peers: HashMap<String, Peer>,
    bytes: usize,
    recovery: Arc<Mutex<Recovery>>,
    fatal: mpsc::Sender<String>,
    owner: String,
    workspace: Option<Arc<Mutex<workspace::Store>>>,
}
impl Room {
    fn document_to(&mut self, peer: &str, document: &str) -> Result<(), String> {
        let message = self
            .workspace
            .as_ref()
            .ok_or("This Jam does not share tabs")?
            .lock()
            .unwrap()
            .snapshot(document)?;
        if let Some(p) = self.peers.get_mut(peer) {
            p.tx.try_send(Wire::Workspace { message })
                .map_err(|_| "Jam participant is too slow")?;
            p.known.insert(document.into());
        }
        Ok(())
    }
    fn broadcast_document(&mut self, document: &str, message: Wire, except: &str) {
        self.peers.retain(|id, p| {
            id == except || !p.known.contains(document) || p.tx.try_send(message.clone()).is_ok()
        });
    }
    fn broadcast(&mut self, message: Wire, except: &str) {
        self.peers
            .retain(|id, peer| id == except || peer.tx.try_send(message.clone()).is_ok());
    }
    fn presence(&mut self) {
        let list = self.peers.values().map(|p| p.info.clone()).collect();
        self.broadcast(Wire::Peers { list }, "");
    }
    #[cfg(test)]
    fn process(&mut self, peer: &str, message: Wire) -> Result<(), String> {
        self.process_owned(peer, message, false)
    }
    fn process_owned(&mut self, peer: &str, message: Wire, owner: bool) -> Result<(), String> {
        match message {
            Wire::Workspace { message } => self.process_workspace(peer, message, owner)?,
            Wire::Sync { id, update } => {
                self.bytes += update.len();
                if self.bytes > MAX_SESSION {
                    return Err("Local Jam room limit reached; start a new room".into());
                }
                self.doc.apply(&update)?;
                if let Err(error) = self.recovery.lock().unwrap().accept(&update) {
                    let _ = self.fatal.try_send(error.clone());
                    return Err(error);
                }
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
            Wire::Presence {
                caret,
                anchor,
                view,
            } if caret.len() <= 256
                && anchor.len() <= 256
                && view.as_ref().is_none_or(Viewport::valid) =>
            {
                self.doc.resolve(&caret)?;
                self.doc.resolve(&anchor)?;
                if let Some(view) = &view {
                    self.doc.resolve(&view.top)?;
                }
                let message = Wire::Cursor {
                    peer: peer.into(),
                    caret,
                    anchor,
                    view,
                };
                if let Some(p) = self.peers.get_mut(peer) {
                    p.cursor = Some(message.clone());
                }
                self.broadcast(message, peer);
            }
            _ => return Err("Unexpected Jam message".into()),
        }
        Ok(())
    }

    fn process_workspace(
        &mut self,
        peer: &str,
        message: WorkspaceMessage,
        owner: bool,
    ) -> Result<(), String> {
        let store = self
            .workspace
            .clone()
            .ok_or("This Jam does not share a workspace")?;
        if !message.client_valid() {
            return Err("Invalid Jam workspace command".into());
        }
        if matches!(
            message,
            WorkspaceMessage::Open { .. }
                | WorkspaceMessage::Activate { .. }
                | WorkspaceMessage::Frame { .. }
        ) && !owner
        {
            return Err("Only the host can share or activate Jam tabs".into());
        }
        let wrap = |message| Wire::Workspace { message };
        let result = match message {
            WorkspaceMessage::Open {
                document,
                file,
                state,
            } => {
                let result = store.lock().unwrap().adopt(&document, &file, &state);
                result.and_then(|_| self.document_to(peer, &document))
            }
            WorkspaceMessage::Request { document } => {
                if !store.lock().unwrap().shared(&document) {
                    return Err("This document has not been presented by the host".into());
                }
                self.document_to(peer, &document)
            }
            WorkspaceMessage::Sync {
                document,
                id,
                update,
            } => {
                if !owner && !store.lock().unwrap().shared(&document) {
                    return Err("This document has not been presented by the host".into());
                }
                self.bytes += update.len();
                if self.bytes > MAX_SESSION * 4 {
                    return Err("Jam workspace session limit reached".into());
                }
                let accepted = store.lock().unwrap().accept(&document, &update);
                accepted.and_then(|_| {
                    self.broadcast_document(
                        &document,
                        wrap(WorkspaceMessage::Update {
                            document: document.clone(),
                            peer: peer.into(),
                            update,
                        }),
                        peer,
                    );
                    if let Some(p) = self.peers.get(peer) {
                        p.tx.try_send(wrap(WorkspaceMessage::Ack { document, id }))
                            .map_err(|_| "Jam participant is too slow")?;
                    }
                    Ok(())
                })
            }
            WorkspaceMessage::Presence {
                document,
                caret,
                anchor,
                view,
            } => {
                if !owner && !store.lock().unwrap().shared(&document) {
                    return Err("This document has not been presented by the host".into());
                }
                store
                    .lock()
                    .unwrap()
                    .presence(&document, &caret, &anchor, &view)?;
                let message = wrap(WorkspaceMessage::Cursor {
                    document: document.clone(),
                    peer: peer.into(),
                    caret,
                    anchor,
                    view,
                });
                if let Some(p) = self.peers.get_mut(peer) {
                    p.workspace_cursors
                        .insert(document.clone(), message.clone());
                }
                self.broadcast_document(&document, message, peer);
                Ok(())
            }
            WorkspaceMessage::Activate { surface } => {
                let activated = store.lock().unwrap().activate(surface.clone());
                if let Err(error) = activated {
                    if store.lock().unwrap().failed {
                        let _ = self.fatal.try_send(error.clone());
                    }
                    return Err(error);
                }
                if let Surface::Code { document } = &surface {
                    let missing: Vec<_> = self
                        .peers
                        .iter()
                        .filter_map(|(id, p)| (!p.known.contains(document)).then_some(id.clone()))
                        .collect();
                    for id in missing {
                        self.document_to(&id, document)?;
                    }
                }
                for p in self.peers.values() {
                    p.visual.send_replace(None);
                }
                self.broadcast(
                    wrap(WorkspaceMessage::Active {
                        surface: surface.clone(),
                    }),
                    "",
                );
                if let Surface::Code { document } = surface {
                    let cursors: Vec<_> = self
                        .peers
                        .values()
                        .filter_map(|p| p.workspace_cursors.get(&document).cloned())
                        .collect();
                    for cursor in cursors {
                        self.broadcast_document(&document, cursor, "");
                    }
                }
                Ok(())
            }
            WorkspaceMessage::Frame { frame } => {
                let mut saved = store.lock().unwrap();
                if !matches!(&saved.active, Surface::Preview { id, .. } if id == &frame.view)
                    || saved
                        .frame
                        .as_ref()
                        .is_some_and(|previous| previous.sequence >= frame.sequence)
                {
                    return Ok(());
                }
                saved.frame(frame.clone())?;
                drop(saved);
                let frame = wrap(WorkspaceMessage::Frame { frame });
                for (id, p) in &self.peers {
                    if id != peer {
                        p.visual.send_replace(Some(frame.clone()));
                    }
                }
                Ok(())
            }
            _ => Err("Unexpected Jam workspace command".into()),
        };
        if let Err(error) = &result
            && store.lock().unwrap().failed
        {
            let _ = self.fatal.try_send(error.clone());
        }
        result
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
        owner,
        workspace,
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
    } else if room.lock().unwrap().workspace.is_some() != workspace {
        Some("This invitation uses a different Jam sharing mode")
    } else if owner
        .as_ref()
        .is_some_and(|owner| owner != &room.lock().unwrap().owner)
    {
        Some("Invalid Jam host credential")
    } else if room.lock().unwrap().peers.contains_key(&peer) {
        Some("This Jam participant is already connected")
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
    let owner = owner
        .as_ref()
        .is_some_and(|owner| owner == &room.lock().unwrap().owner);
    let (tx, mut rx) = mpsc::channel(workspace::MAX_DOCUMENTS + MAX_PEERS * 2 + 8);
    let (visual, mut preview) = watch::channel(None);
    let connection = tx.clone();
    let mut known = std::collections::HashSet::new();
    {
        let mut room = room.lock().unwrap();
        let saved = room.recovery.lock().unwrap();
        let welcome = Wire::Welcome {
            v: VERSION,
            file: room.file.clone(),
            state: room.doc.state(),
            vector: room.doc.vector(),
            document_id: saved.id.clone(),
            durable: saved.durable(),
            workspace: room.workspace.is_some(),
        };
        drop(saved);
        let _ = tx.try_send(welcome);
        if let Some(workspace) = &room.workspace {
            let saved = workspace.lock().unwrap();
            let snapshots = if owner {
                saved.snapshots()
            } else if let Surface::Code { document } = &saved.active {
                vec![saved.snapshot(document).unwrap()]
            } else {
                vec![]
            };
            for message in snapshots {
                if let WorkspaceMessage::Document { document, .. } = &message {
                    known.insert(document.clone());
                }
                let _ = tx.try_send(Wire::Workspace { message });
            }
            let _ = tx.try_send(Wire::Workspace {
                message: WorkspaceMessage::Active {
                    surface: saved.active.clone(),
                },
            });
            if let Some(frame) = &saved.frame {
                visual.send_replace(Some(Wire::Workspace {
                    message: WorkspaceMessage::Frame {
                        frame: frame.clone(),
                    },
                }));
            }
            if let Surface::Code { document } = &saved.active {
                for p in room.peers.values() {
                    if let Some(cursor) = p.workspace_cursors.get(document) {
                        let _ = tx.try_send(cursor.clone());
                    }
                }
            }
        }
        for p in room.peers.values() {
            if let Some(cursor) = &p.cursor {
                let _ = tx.try_send(cursor.clone());
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
                workspace_cursors: HashMap::new(),
                visual,
                known,
            },
        );
        room.presence();
    }
    loop {
        tokio::select! {
            biased;
            next = rx.recv() => match next {
                Some(message) => if !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&message))).await.is_ok_and(|r|r.is_ok()) { break; },
                None => break,
            },
            next = socket.next() => match next {
                Some(Ok(message)) => match parse(message) {
                    Ok(Some(message)) => {
                        let result = {
                            let mut room = room.lock().unwrap();
                            if !room.peers.get(&peer).is_some_and(|p| p.tx.same_channel(&connection)) { break; }
                            room.process_owned(&peer,message,owner)
                        };
                        if let Err(message) = result { let _=socket.send(packet(&Wire::Error {code:"invalid_update".into(),message})).await; break; }
                    }, Ok(None) => {}, _ => break,
                }, _ => break,
            },
            changed = preview.changed() => {
                if changed.is_err() { break; }
                let message = preview.borrow_and_update().clone();
                if let Some(message) = message && !tokio::time::timeout(Duration::from_secs(3),socket.send(packet(&message))).await.is_ok_and(|r|r.is_ok()) { break; }
            },
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
                ..Default::default()
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
                invite: invite.clone(),
                name: "Guest".into(),
                file: String::new(),
                state: String::new(),
                ..Default::default()
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
            json!({"t":"presence","caret":b.position(11).unwrap(),"anchor":b.position(6).unwrap(),"view":{"top":b.position(6).unwrap(),"offset":0.25,"x":2.5}}),
        );
        let cursor = until(&host, &mut ha, |e| e["t"] == "cursor");
        assert_eq!(a.resolve(cursor["caret"].as_str().unwrap()).unwrap(), 11);
        assert_eq!(
            a.resolve(cursor["view"]["top"].as_str().unwrap()).unwrap(),
            6
        );
        assert_eq!(cursor["view"]["offset"], 0.25);
        let late = Session::start(
            Config {
                host: false,
                invite,
                name: "Late".into(),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        let mut events = vec![];
        let replay = until(&late, &mut events, |e| e["t"] == "cursor");
        assert_eq!(replay["view"], cursor["view"]);
        late.close();
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
            recovery: Arc::new(Mutex::new(
                Recovery::open("", "Main.hx", false, &seed.id(), &seed.state()).unwrap(),
            )),
            fatal: mpsc::channel(1).0,
            doc: seed,
            token: "0123456789abcdef".into(),
            file: "Main.hx".into(),
            peers: HashMap::new(),
            bytes: 0,
            owner: String::new(),
            workspace: None,
        }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(serve(listener, room.clone()));
        for (version, token) in [
            (1, "0123456789abcdef"),
            (2, "0123456789abcdef"),
            (VERSION, "bad"),
        ] {
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
                owner: None,
                workspace: false,
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
            owner: None,
            workspace: false,
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
    fn storage_failure_never_acknowledges_or_broadcasts() {
        let root =
            std::env::temp_dir().join(format!("rayde-jam-{}", Document::new("").unwrap().id()));
        let mut seed = Document::new("safe").unwrap();
        let recovery = Recovery::open(
            root.to_str().unwrap(),
            "Main.hx",
            false,
            &seed.id(),
            &seed.state(),
        )
        .unwrap();
        let (fatal, mut errors) = mpsc::channel(1);
        let (tx, mut replies) = mpsc::channel(8);
        let mut room = Room {
            doc: Document::new("").unwrap(),
            token: String::new(),
            file: "Main.hx".into(),
            peers: HashMap::new(),
            bytes: 0,
            recovery: Arc::new(Mutex::new(recovery)),
            fatal,
            owner: String::new(),
            workspace: None,
        };
        room.doc.apply(&seed.state()).unwrap();
        room.peers.insert(
            "peer".into(),
            Peer {
                info: PeerInfo {
                    id: "peer".into(),
                    name: "Peer".into(),
                },
                tx,
                cursor: None,
                workspace_cursors: HashMap::new(),
                visual: watch::channel(None).0,
                known: std::collections::HashSet::new(),
            },
        );
        // Force snapshot compaction to fail after the journal itself has been flushed.
        std::fs::create_dir(root.join("checkpoint.next")).unwrap();
        let update = seed
            .edit(
                "safe",
                &[crate::document::Patch {
                    from: 4,
                    removed: "".into(),
                    inserted: "x".repeat(512 * 1024),
                }],
            )
            .unwrap();
        assert!(room.process("peer", Wire::Sync { id: 7, update }).is_err());
        assert!(replies.try_recv().is_err());
        assert!(errors.try_recv().is_ok());
        drop(room);
        std::fs::remove_dir(root.join("checkpoint.next")).unwrap();
        let recovered = Recovery::open(root.to_str().unwrap(), "Main.hx", true, "", "").unwrap();
        assert_eq!(recovered.doc.text(), seed.text());
        drop(recovered);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn slow_presence_receiver_keeps_latest_position_and_all_edits() {
        let (commands, _) = mpsc::channel(64);
        let session = Session {
            commands,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            events: Mutex::new(Events {
                list: VecDeque::new(),
                bytes: 0,
            }),
            stopped: AtomicBool::new(false),
            cancel: Notify::new(),
            wake: None,
            workspace: false,
            host: false,
            frame: Mutex::new(None),
            frame_ready: Notify::new(),
            desired: Mutex::new(None),
        };
        for index in 0..1000 {
            session.push(json!({"t":"cursor","peer":"peer","caret":index,"anchor":index,"view":{"top":index,"offset":0.5,"x":1.0}}));
            if index == 500 {
                session.push(json!({"t":"update","peer":"peer","update":"keep this edit"}));
            }
        }
        assert!(!session.stopped.load(Ordering::Acquire));
        let events = session.poll();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["update"], "keep this edit");
        assert_eq!(events[1]["view"]["top"], 999);
        assert!(!session.pending());
        assert_eq!(session.events.lock().unwrap().bytes, 0);
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
            workspace: false,
            host: false,
            frame: Mutex::new(None),
            frame_ready: Notify::new(),
            desired: Mutex::new(None),
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
    fn viewport_presence_is_bounded_validated_and_not_persisted() {
        let root =
            std::env::temp_dir().join(format!("rayde-jam-{}", Document::new("").unwrap().id()));
        let seed = Document::new("hello 🦀").unwrap();
        let recovery = Recovery::open(
            root.to_str().unwrap(),
            "Main.hx",
            false,
            &seed.id(),
            &seed.state(),
        )
        .unwrap();
        let (fatal, _) = mpsc::channel(1);
        let (tx, mut rx) = mpsc::channel(8);
        let mut room = Room {
            doc: seed,
            token: String::new(),
            file: "Main.hx".into(),
            peers: HashMap::new(),
            bytes: 0,
            recovery: Arc::new(Mutex::new(recovery)),
            fatal,
            owner: String::new(),
            workspace: None,
        };
        room.peers.insert(
            "other".into(),
            Peer {
                info: PeerInfo {
                    id: "other".into(),
                    name: "Other".into(),
                },
                tx,
                cursor: None,
                workspace_cursors: HashMap::new(),
                visual: watch::channel(None).0,
                known: std::collections::HashSet::new(),
            },
        );
        let top = room.doc.position(0).unwrap();
        let state = std::fs::read(root.join("checkpoint.json")).unwrap();
        for (offset, x) in [
            (1.0, 0.0),
            (-17.0, 0.0),
            (0.0, -1.0),
            (0.0, 1_000_001.0),
            (f64::NAN, 0.0),
            (0.0, f64::INFINITY),
        ] {
            assert!(
                !Viewport {
                    top: top.clone(),
                    offset,
                    x
                }
                .valid()
            );
        }
        let message = |top: String| Wire::Presence {
            caret: room.doc.position(6).unwrap(),
            anchor: room.doc.position(0).unwrap(),
            view: Some(Viewport {
                top,
                offset: 0.5,
                x: 4.0,
            }),
        };
        let wrong = message(Document::new("unrelated").unwrap().position(1).unwrap());
        let valid = message(top);
        assert!(room.process("sender", wrong).is_err());
        assert!(rx.try_recv().is_err());
        room.process("sender", valid).unwrap();
        assert!(matches!(
            rx.try_recv().unwrap(),
            Wire::Cursor {
                view: Some(Viewport {
                    offset: 0.5,
                    x: 4.0,
                    ..
                }),
                ..
            }
        ));
        assert_eq!(
            std::fs::metadata(root.join("updates.log")).unwrap().len(),
            0
        );
        assert_eq!(std::fs::read(root.join("checkpoint.json")).unwrap(), state);
        drop(room);
        std::fs::remove_dir_all(root).unwrap();
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
        assert!(matches!(
            serde_json::from_str::<Wire>(
                r#"{"t":"welcome","v":1,"file":"Main.hx","state":"AA==","vector":"AA=="}"#
            )
            .unwrap(),
            Wire::Welcome { v: 1, .. }
        ));
        assert!(
            serde_json::from_str::<Wire>(r#"{"t":"sync","id":1,"update":"AA==","extra":true}"#)
                .is_err()
        );
    }

    #[test]
    fn workspace_preview_queues_keep_only_latest_frame_and_preserve_document_edits() {
        let (commands, _receiver) = mpsc::channel(64);
        let session = Session {
            commands,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            events: Mutex::new(Events {
                list: VecDeque::new(),
                bytes: 0,
            }),
            stopped: AtomicBool::new(false),
            cancel: Notify::new(),
            wake: None,
            workspace: true,
            host: true,
            frame: Mutex::new(None),
            frame_ready: Notify::new(),
            desired: Mutex::new(None),
        };
        let view = Document::new("").unwrap().id();
        for sequence in 0..1000 {
            let frame = json!({"t":"workspace","message":{"t":"frame","frame":{"view":view,"sequence":sequence,"width":1,"height":1,"png":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII="}}});
            assert!(session.send(frame.clone()));
            session.push(frame);
            if sequence == 500 {
                session.push(json!({"t":"workspace","message":{"t":"update","document":view,"peer":"peer","update":"keep this edit"}}));
            }
        }
        assert_eq!(
            session.frame.lock().unwrap().as_ref().unwrap().sequence,
            999
        );
        assert_eq!(session.queued_bytes.load(Ordering::Relaxed), 0);
        let events = session.poll();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["message"]["update"], "keep this edit");
        assert_eq!(events[1]["message"]["frame"]["sequence"], 999);
        assert!(
            session.send(
                json!({"t":"workspace","message":{"t":"activate","surface":{"kind":"idle"}}})
            )
        );
        assert!(session.frame.lock().unwrap().is_none());
        assert!(!session.stopped.load(Ordering::Acquire));
    }

    #[test]
    fn workspace_storage_failure_never_acknowledges_or_broadcasts() {
        let root = std::env::temp_dir().join(format!(
            "jam-workspace-failure-{}",
            Document::new("").unwrap().id()
        ));
        let mut seed = Document::new("safe").unwrap();
        let id = seed.id();
        let mut saved = workspace::Store::open(root.to_str().unwrap(), false).unwrap();
        saved.adopt(&id, "src/Main.hx", &seed.state()).unwrap();
        saved
            .activate(Surface::Code {
                document: id.clone(),
            })
            .unwrap();
        let saved = Arc::new(Mutex::new(saved));
        let (fatal, mut errors) = mpsc::channel(1);
        let (tx, mut replies) = mpsc::channel(8);
        let mut room = Room {
            doc: Document::new("").unwrap(),
            token: String::new(),
            file: "Workspace".into(),
            peers: HashMap::new(),
            bytes: 0,
            recovery: Arc::new(Mutex::new(
                Recovery::open(
                    "",
                    "Workspace",
                    false,
                    &Document::new("").unwrap().id(),
                    &Document::new("").unwrap().state(),
                )
                .unwrap(),
            )),
            fatal,
            owner: String::new(),
            workspace: Some(saved.clone()),
        };
        room.peers.insert(
            "peer".into(),
            Peer {
                info: PeerInfo {
                    id: "peer".into(),
                    name: "Peer".into(),
                },
                tx,
                cursor: None,
                workspace_cursors: HashMap::new(),
                visual: watch::channel(None).0,
                known: std::collections::HashSet::new(),
            },
        );
        let blocked = root.join("workspace").join(&id).join("checkpoint.next");
        std::fs::create_dir(&blocked).unwrap();
        let update = seed
            .edit(
                "safe",
                &[crate::document::Patch {
                    from: 4,
                    removed: String::new(),
                    inserted: "x".repeat(512 * 1024),
                }],
            )
            .unwrap();
        assert!(
            room.process(
                "peer",
                Wire::Workspace {
                    message: WorkspaceMessage::Sync {
                        document: id.clone(),
                        id: 7,
                        update
                    }
                }
            )
            .is_err()
        );
        assert!(replies.try_recv().is_err());
        assert!(errors.try_recv().is_ok());
        assert!(saved.lock().unwrap().failed);
        drop(room);
        drop(saved);
        std::fs::remove_dir(blocked).unwrap();
        let recovered = workspace::Store::open(root.to_str().unwrap(), true).unwrap();
        if let WorkspaceMessage::Document { state, .. } = recovered.snapshot(&id).unwrap() {
            let mut text = Document::new("").unwrap();
            text.apply(&state).unwrap();
            assert_eq!(text.text(), seed.text());
        } else {
            panic!();
        }
        drop(recovered);
        std::fs::remove_dir_all(root).unwrap();
    }
}
