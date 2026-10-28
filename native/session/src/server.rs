//! The runner: HTTP and WebSocket on a port, a directory as the workspace, child processes as programs.
use crate::{
    dir_store::DirStore,
    processes::ChildPrograms,
    session::{Connection, MAX_MESSAGE, Out, Programs, Workspace},
    store::FileStore,
};
use axum::{
    Router,
    body::Body,
    extract::{
        State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode, Uri, header},
    response::{IntoResponse, Response},
    routing::get,
};
use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock, Weak},
    time::Duration,
};
use tokio::{net::TcpListener, sync::{Notify, mpsc, oneshot}};

struct OutputState {
    bytes: std::sync::atomic::AtomicUsize,
    closed: std::sync::atomic::AtomicBool,
    wake: Notify,
}

const HELLO_TIMEOUT: Duration = Duration::from_secs(10);

impl OutputState {
    fn stop(&self) {
        self.closed.store(true, std::sync::atomic::Ordering::Release);
        self.wake.notify_one();
    }
    fn closed(&self) -> bool { self.closed.load(std::sync::atomic::Ordering::Acquire) }
}

/// The socket keeps its byte reservation until the write completes or is cancelled.
struct OutputPermit { state: Arc<OutputState>, size: usize }
impl Drop for OutputPermit {
    fn drop(&mut self) { self.state.bytes.fetch_sub(self.size, std::sync::atomic::Ordering::AcqRel); }
}

fn outbox(capacity: usize, limit: usize) -> (Out, mpsc::Receiver<(String, OutputPermit)>, Arc<OutputState>) {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    let (sender, receiver) = mpsc::channel(capacity);
    let state = Arc::new(OutputState {bytes:AtomicUsize::new(0),closed:AtomicBool::new(false),wake:Notify::new()});
    let owner = state.clone();
    let out: Out = Arc::new(move |text| {
        if owner.closed() { return; }
        if owner.bytes.try_update(Ordering::AcqRel,Ordering::Acquire,|size| size.checked_add(text.len()).filter(|size| *size <= limit)).is_err() {
            owner.stop(); return;
        }
        let permit = OutputPermit {state:owner.clone(),size:text.len()};
        if sender.try_send((text,permit)).is_err() { owner.stop(); }
    });
    (out,receiver,state)
}

pub struct Options {
    pub root: PathBuf,
    pub state_root: Option<PathBuf>,
    pub address: SocketAddr,
    /// The session's token; `None` opens it to whoever reaches it.
    pub token: Option<String>,
    /// Origins besides the server's own that may open a connection from a page.
    pub origins: Vec<String>,
    /// Whether programs may be run.
    pub exec: bool,
    /// Host-owned defaults; an explicit process configuration may override them.
    pub environment: HashMap<String,String>,
    /// The trusted installed extension host; its processes still require the session's execution permission.
    pub extension_host: Option<PathBuf>,
    pub extensions: Option<PathBuf>,
    /// Read-only source directories outside the workspace.
    pub read_roots: Vec<PathBuf>,
    /// Who may edit; without it every connection may.
    pub authority: Option<Arc<dyn crate::auth::Authority>>,
    /// A directory of files for pages to load, served beside the session.
    pub web: Option<PathBuf>,
    /// Opt-in loopback development bootstrap; never enable on a public listener.
    pub preview_project: Option<String>,
    /// Host-owned Haxe and browser bridge files for isolated app builds.
    pub preview_tools: Option<PathBuf>,
    /// A second listener that speaks the session protocol as length-prefixed frames over TCP, with no HTTP or WebSocket.
    pub raw: Option<SocketAddr>,
    /// How long an edit waits for more before the file is written.
    pub flush_delay: Duration,
}

impl Options {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into(), state_root: None, address: ([127, 0, 0, 1], 0).into(), token: None, origins: Vec::new(), exec: false, environment:HashMap::new(), extension_host: None, extensions: None, read_roots:Vec::new(), authority: None, web: None, preview_project:None, preview_tools:None, raw: None, flush_delay: Duration::from_millis(150) }
    }
}

pub struct Running {
    pub address: SocketAddr,
    pub raw_address: Option<SocketAddr>,
    pub token: Option<String>,
    pub workspace: Arc<Workspace<DirStore>>,
    stop: Option<oneshot::Sender<()>>,
    done: tokio::task::JoinHandle<()>,
    unwatch: Option<Box<dyn FnOnce() + Send>>,
    _previews:Option<crate::previews::Running>,
}

impl Running {
    pub fn url(&self) -> String {
        format!("http://{}", self.address)
    }

    pub async fn shutdown(mut self) {
        if let Some(unwatch) = self.unwatch.take() {
            unwatch();
        }
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = tokio::time::timeout(Duration::from_secs(2), &mut self.done).await;
        self.workspace.docs.close().await;
    }
}

#[derive(Clone)]
struct Shared {
    workspace: Arc<Workspace<DirStore>>,
    origins: Arc<Vec<String>>,
    web: Option<Arc<PathBuf>>,
    preview: Option<(String,String)>,
}

pub async fn start(options: Options) -> std::io::Result<Running> {
    if options.preview_project.is_some() && (!options.address.ip().is_loopback() || options.web.is_none() || options.token.is_none() || options.authority.is_some()) {
        return Err(std::io::Error::other("Preview bootstrap requires a token-protected loopback web server without account authentication."));
    }
    if let Some(project) = &options.preview_project {
        if !project.is_empty() && std::path::Path::new(project).components().any(|part| !matches!(part,std::path::Component::Normal(_))) {
            return Err(std::io::Error::other("The preview project must be workspace-relative."));
        }
    }
    let store = Arc::new(match &options.state_root { Some(state) => DirStore::with_state_root(&options.root,state)?, None => DirStore::new(&options.root)? });
    let extension_host = options.extension_host.as_ref().map(std::fs::canonicalize).transpose()?;
    let extensions = options.extensions.as_ref().map(std::fs::canonicalize).transpose()?;
    if extension_host.is_some() && !options.exec {
        return Err(std::io::Error::other("The extension host requires --exec."));
    }
    let mut read_roots = options.read_roots.clone();
    if let Some(root) = &extensions { if !root.starts_with(store.root()) { read_roots.push(root.clone()); } }
    let sources = crate::read_roots::ReadRoots::new(read_roots, store.root())?;
    let programs: Option<Arc<dyn Programs>> = options.exec.then(|| {
        let mut programs = ChildPrograms::new(store.root().to_path_buf(), 16).with_environment(options.environment.clone());
        if let Some(host) = extension_host { programs = programs.with_extensions(host, extensions); }
        Arc::new(programs) as Arc<dyn Programs>
    });
    // The workspace needs a way to schedule a flush, and the flush needs the workspace: the weak link breaks the cycle.
    let link: Arc<OnceLock<Weak<Workspace<DirStore>>>> = Arc::new(OnceLock::new());
    let generations: Arc<Mutex<HashMap<String, u64>>> = Arc::new(Mutex::new(HashMap::new()));
    let delay = options.flush_delay;
    // Callbacks may run on a thread of the store's or the document's own, outside the runtime.
    let runtime = tokio::runtime::Handle::current();
    let dirty: Arc<dyn Fn(&str) + Send + Sync> = {
        let (link, generations, runtime) = (link.clone(), generations.clone(), runtime.clone());
        Arc::new(move |path: &str| {
            let generation = {
                let mut map = generations.lock().unwrap();
                let entry = map.entry(path.to_string()).or_insert(0);
                *entry += 1;
                *entry
            };
            let (link, generations, path) = (link.clone(), generations.clone(), path.to_string());
            runtime.spawn(async move {
                tokio::time::sleep(delay).await;
                if generations.lock().unwrap().get(&path) != Some(&generation) {
                    return;
                }
                if let Some(workspace) = link.get().and_then(Weak::upgrade) {
                    let _ = workspace.docs.flush(&path).await;
                }
            });
        })
    };
    let clock: Arc<dyn Fn() -> u64 + Send + Sync> = Arc::new(|| std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs()));
    let workspace = Workspace::with_authority(store.clone(), options.token.clone(), programs, dirty, options.authority, clock);
    let previews = if options.exec {Some(crate::previews::Previews::start(store.root(),options.preview_tools).await?)} else {None};
    if let Some(previews)=&previews {workspace.set_previews(previews.registry.clone());}
    workspace.set_sources(sources);
    workspace.set_syntax(Arc::new(crate::syntax::NativeSyntax::new()));
    if options.exec {workspace.set_terminals(Arc::new(crate::terminal::NativeTerminals::new(store.root().to_path_buf(),options.environment)));}
    let _ = link.set(Arc::downgrade(&workspace));

    // Outside changes arrive in bursts; each path is read once after they settle.
    let pending: Arc<Mutex<HashMap<String, u64>>> = Arc::new(Mutex::new(HashMap::new()));
    let unwatch = {
        let (weak, pending, runtime) = (Arc::downgrade(&workspace), pending, runtime.clone());
        store.watch(Arc::new(move |path, kind| {
            let generation = {
                let mut map = pending.lock().unwrap();
                let entry = map.entry(path.clone()).or_insert(0);
                *entry += 1;
                *entry
            };
            let (weak, pending) = (weak.clone(), pending.clone());
            runtime.spawn(async move {
                tokio::time::sleep(Duration::from_millis(40)).await;
                if pending.lock().unwrap().get(&path) != Some(&generation) {
                    return;
                }
                pending.lock().unwrap().remove(&path);
                if let Some(workspace) = weak.upgrade() {
                    workspace.changed(&path, kind).await;
                }
            });
        }))
    };

    let preview = options.preview_project.map(|project| (project,options.token.clone().unwrap()));
    let shared = Shared { workspace: workspace.clone(), origins: Arc::new(options.origins), web: options.web.map(Arc::new), preview };
    let app = Router::new().route("/session", get(upgrade)).route("/.well-known/rayde-preview",get(preview_connection)).fallback(get(page)).with_state(shared);
    let listener = TcpListener::bind(options.address).await?;
    let address = listener.local_addr()?;
    let (stop, stopped) = oneshot::channel::<()>();
    let raw_address = match options.raw {
        Some(raw) => {
            let raw_listener = TcpListener::bind(raw).await?;
            let bound = raw_listener.local_addr()?;
            let workspace = workspace.clone();
            tokio::spawn(async move {
                while let Ok((stream, _)) = raw_listener.accept().await {
                    tokio::spawn(framed(workspace.clone(), stream));
                }
            });
            Some(bound)
        }
        None => None,
    };
    let done = tokio::spawn(async move {
        let _ = axum::serve(listener, app).with_graceful_shutdown(async { let _ = stopped.await; }).await;
    });
    Ok(Running { address, raw_address, token: options.token, workspace, stop: Some(stop), done, unwatch: Some(unwatch), _previews:previews })
}

async fn preview_connection(State(shared):State<Shared>, headers:HeaderMap) -> Response {
    let Some((project,token)) = shared.preview else { return StatusCode::NO_CONTENT.into_response() };
    let host = headers.get(header::HOST).and_then(|value|value.to_str().ok()).unwrap_or("");
    let loopback = ["127.0.0.1:","localhost:","[::1]:"].iter().any(|prefix|host.strip_prefix(prefix).is_some_and(|port|port.parse::<u16>().is_ok()));
    if !loopback || headers.get("Sec-Fetch-Site").and_then(|value|value.to_str().ok()) != Some("same-origin") {
        return StatusCode::FORBIDDEN.into_response();
    }
    let mut response = axum::Json(serde_json::json!({"version":1,"endpoint":format!("ws://{host}/session"),"project":project,"token":token,"environment":[]})).into_response();
    response.headers_mut().insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    response
}

/// A page may reach the session only from the server's own origin or one it was told of: a token alone does not stop another site's page that holds it.
fn origin_allowed(headers: &HeaderMap, allowed: &[String]) -> bool {
    let Some(origin) = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) else { return true };
    let own = headers.get(header::HOST).and_then(|v| v.to_str().ok()).map(|host| format!("http://{host}"));
    own.as_deref() == Some(origin) || allowed.iter().any(|a| a == origin)
}

async fn upgrade(State(shared): State<Shared>, headers: HeaderMap, socket: WebSocketUpgrade) -> Response {
    if !origin_allowed(&headers, &shared.origins) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let (out, outgoing, output) = outbox(512, 32 * 1024 * 1024);
    let connection = match shared.workspace.connect(out) {
        Ok(connection) => connection,
        Err(error) => return (StatusCode::TOO_MANY_REQUESTS, error.message).into_response(),
    };
    socket.max_message_size(MAX_MESSAGE).max_frame_size(MAX_MESSAGE).on_upgrade(move |socket| connection_socket(shared.workspace, connection, socket, outgoing, output))
}

async fn connection_socket(workspace: Arc<Workspace<DirStore>>, mut connection: Connection<DirStore>, socket: WebSocket, mut outgoing: mpsc::Receiver<(String, OutputPermit)>, output: Arc<OutputState>) {
    use futures_util::{SinkExt, StreamExt};
    let (mut sink, mut stream) = socket.split();
    // A client that sends binary messages (a program with only a byte stream to the session) is answered in the same form.
    let binary = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let answers = binary.clone();
    let written = output.clone();
    let writer = tokio::spawn(async move {
        while let Some((text, _permit)) = outgoing.recv().await {
            let message = if answers.load(std::sync::atomic::Ordering::Relaxed) { Message::Binary(frame(&text)) } else { Message::Text(text) };
            if sink.send(message).await.is_err() {
                break;
            }
        }
        written.stop();
    });
    let hello_deadline = tokio::time::Instant::now() + HELLO_TIMEOUT;
    let mut frames = Frames::default();
    'read: loop {
        let message = tokio::select! {
            _ = output.wake.notified() => break,
            _ = tokio::time::sleep_until(hello_deadline), if !connection.ready() => break,
            message = stream.next() => message,
        };
        let Some(Ok(message)) = message else { break };
        match message {
            Message::Text(text) => connection.handle(&text).await,
            Message::Binary(bytes) => {
                binary.store(true, std::sync::atomic::Ordering::Relaxed);
                match frames.push(&bytes) {
                    Ok(texts) => {
                        for text in texts {
                            connection.handle(&text).await;
                            if output.closed() { break 'read; }
                        }
                    }
                    Err(_) => break,
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
        if output.closed() { break; }
    }
    connection.close();
    writer.abort();
    // A document nobody has open is kept briefly, so a reload does not read its file again.
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5)).await;
        for path in workspace.docs.idle() {
            let _ = workspace.docs.release(&path).await;
        }
    });
}

async fn page(State(shared): State<Shared>, uri: Uri) -> Response {
    let Some(web) = shared.web else { return StatusCode::NOT_FOUND.into_response() };
    let requested = uri.path().trim_start_matches('/');
    let name = if requested.is_empty() || requested.ends_with('/') { format!("{requested}index.html") } else { requested.into() };
    if name.split('/').any(|part| part == ".." || part.contains('\\')) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let file = web.join(name);
    match tokio::fs::read(&file).await {
        Ok(bytes) => {
            let kind = match file.extension().and_then(|e| e.to_str()) {
                Some("html") => "text/html; charset=utf-8",
                Some("js" | "mjs") => "text/javascript; charset=utf-8",
                Some("css") => "text/css",
                Some("wasm") => "application/wasm",
                Some("json" | "map") => "application/json",
                Some("svg") => "image/svg+xml",
                Some("png") => "image/png",
                Some("webp") => "image/webp",
                Some("jpg" | "jpeg") => "image/jpeg",
                Some("ico") => "image/x-icon",
                Some("woff2") => "font/woff2",
                Some("woff") => "font/woff",
                Some("ttf") => "font/ttf",
                _ => "application/octet-stream",
            };
            Response::builder().header(header::CONTENT_TYPE, kind).header(header::CACHE_CONTROL, "no-store")
                .header("Cross-Origin-Opener-Policy", "same-origin").header("Cross-Origin-Embedder-Policy", "require-corp")
                .body(Body::from(bytes)).unwrap()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

/// A message as a frame: its length in four bytes, big-endian, then its UTF-8 text.
pub use crate::framing::{frame, Frames};

/// A private command channel: closing stdin half-closes TCP and lets the session release its resources.
pub async fn bridge(address: SocketAddr) -> std::io::Result<()> {
    use tokio::io::{copy,AsyncWriteExt};
    if !address.ip().is_loopback() {return Err(std::io::Error::other("Bridge requires loopback."));}
    let stream=tokio::net::TcpStream::connect(address).await?;
    let (mut reader,mut writer)=stream.into_split();
    let (mut input,mut output)=(tokio::io::stdin(),tokio::io::stdout());
    tokio::try_join!(async {copy(&mut input,&mut writer).await?;writer.shutdown().await},async {copy(&mut reader,&mut output).await?;output.flush().await})?;
    Ok(())
}

/// One TCP connection speaking frames.
async fn framed(workspace: Arc<Workspace<DirStore>>, mut stream: tokio::net::TcpStream) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (out, mut outgoing, output) = outbox(512, 32 * 1024 * 1024);
    let mut connection = match workspace.connect(out) {
        Ok(connection) => connection,
        Err(error) => {
            let message = serde_json::json!({"ok":false,"code":error.code,"message":error.message}).to_string();
            let _ = tokio::time::timeout(Duration::from_secs(1), stream.write_all(&frame(&message))).await;
            return;
        }
    };
    let (mut reader, mut writer) = stream.into_split();
    let written = output.clone();
    let sender = tokio::spawn(async move {
        while let Some((text, _permit)) = outgoing.recv().await {
            if writer.write_all(&frame(&text)).await.is_err() {
                break;
            }
        }
        written.stop();
    });
    let hello_deadline = tokio::time::Instant::now() + HELLO_TIMEOUT;
    let (mut frames, mut buffer) = (Frames::default(), vec![0u8; 64 * 1024]);
    'read: loop {
        let count = tokio::select! {
            _ = output.wake.notified() => break,
            _ = tokio::time::sleep_until(hello_deadline), if !connection.ready() => break,
            count = reader.read(&mut buffer) => count,
        };
        let Ok(count) = count else { break };
        if count == 0 {
            break;
        }
        match frames.push(&buffer[..count]) {
            Ok(texts) => {
                for text in texts {
                    connection.handle(&text).await;
                    if output.closed() { break 'read; }
                }
            }
            Err(_) => break 'read,
        }
    }
    connection.close();
    sender.abort();
}

#[cfg(test)]
mod output_tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[tokio::test]
    async fn output_bytes_include_inflight_writes_and_release_when_dropped() {
        let (out,mut queue,state) = outbox(8,8);
        out("123456".into());
        let message = queue.recv().await.unwrap();
        assert_eq!(state.bytes.load(Ordering::Acquire),6);
        out("789".into());
        assert!(state.closed());
        tokio::time::timeout(Duration::from_secs(1),state.wake.notified()).await.unwrap();
        drop(message);
        assert_eq!(state.bytes.load(Ordering::Acquire),0);
        out("ignored".into());
        assert!(queue.try_recv().is_err());
    }

    #[tokio::test]
    async fn a_full_message_queue_closes_the_connection_without_retaining_failed_sends() {
        let (out,mut queue,state) = outbox(1,100);
        out("first".into()); out("second".into());
        assert!(state.closed());
        assert_eq!(state.bytes.load(Ordering::Acquire),5);
        drop(queue.recv().await.unwrap());
        assert_eq!(state.bytes.load(Ordering::Acquire),0);
        drop(queue);
        let (out,queue,state) = outbox(1,100); drop(queue); out("closed".into());
        assert!(state.closed()); assert_eq!(state.bytes.load(Ordering::Acquire),0);
    }
}
