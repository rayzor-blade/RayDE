//! The runner: HTTP and WebSocket on a port, a directory as the workspace, child processes as programs.
use crate::{
    dir_store::DirStore,
    processes::ChildPrograms,
    session::{MAX_MESSAGE, Out, Programs, Workspace},
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
use tokio::{net::TcpListener, sync::{mpsc, oneshot}};

pub struct Options {
    pub root: PathBuf,
    pub address: SocketAddr,
    /// The session's token; `None` opens it to whoever reaches it.
    pub token: Option<String>,
    /// Origins besides the server's own that may open a connection from a page.
    pub origins: Vec<String>,
    /// Whether programs may be run.
    pub exec: bool,
    /// Who may edit; without it every connection may.
    pub authority: Option<Arc<dyn crate::auth::Authority>>,
    /// A directory of files for pages to load, served beside the session.
    pub web: Option<PathBuf>,
    /// How long an edit waits for more before the file is written.
    pub flush_delay: Duration,
}

impl Options {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into(), address: ([127, 0, 0, 1], 0).into(), token: None, origins: Vec::new(), exec: false, authority: None, web: None, flush_delay: Duration::from_millis(150) }
    }
}

pub struct Running {
    pub address: SocketAddr,
    pub token: Option<String>,
    pub workspace: Arc<Workspace<DirStore>>,
    stop: Option<oneshot::Sender<()>>,
    done: tokio::task::JoinHandle<()>,
    unwatch: Option<Box<dyn FnOnce() + Send>>,
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
}

pub async fn start(options: Options) -> std::io::Result<Running> {
    let store = Arc::new(DirStore::new(&options.root)?);
    let programs: Option<Arc<dyn Programs>> = options.exec.then(|| Arc::new(ChildPrograms::new(store.root().to_path_buf(), 16)) as Arc<dyn Programs>);
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

    let shared = Shared { workspace: workspace.clone(), origins: Arc::new(options.origins), web: options.web.map(Arc::new) };
    let app = Router::new().route("/session", get(upgrade)).fallback(get(page)).with_state(shared);
    let listener = TcpListener::bind(options.address).await?;
    let address = listener.local_addr()?;
    let (stop, stopped) = oneshot::channel::<()>();
    let done = tokio::spawn(async move {
        let _ = axum::serve(listener, app).with_graceful_shutdown(async { let _ = stopped.await; }).await;
    });
    Ok(Running { address, token: options.token, workspace, stop: Some(stop), done, unwatch: Some(unwatch) })
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
    socket.max_message_size(MAX_MESSAGE).max_frame_size(MAX_MESSAGE).on_upgrade(move |socket| connection(shared.workspace, socket))
}

async fn connection(workspace: Arc<Workspace<DirStore>>, socket: WebSocket) {
    use futures_util::{SinkExt, StreamExt};
    let (mut sink, mut stream) = socket.split();
    let (queue, mut outgoing) = mpsc::unbounded_channel::<String>();
    let out: Out = Arc::new(move |text| {
        let _ = queue.send(text);
    });
    let writer = tokio::spawn(async move {
        while let Some(text) = outgoing.recv().await {
            if sink.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
    });
    let mut connection = workspace.connect(out);
    while let Some(Ok(message)) = stream.next().await {
        match message {
            Message::Text(text) => connection.handle(&text).await,
            Message::Close(_) => break,
            _ => {}
        }
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
    let name = if requested.is_empty() { "index.html" } else { requested };
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
                _ => "application/octet-stream",
            };
            Response::builder().header(header::CONTENT_TYPE, kind).header(header::CACHE_CONTROL, "no-store").body(Body::from(bytes)).unwrap()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}
