//! The session protocol: JSON requests in, JSON responses and events out. A workspace is shared by every connection to it.
use crate::{
    auth::{Authority, Identity},
    docs::DocHub,
    error::{Result, SessionError},
    store::{Change, FileStore, clean},
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}},
};
use subtle::ConstantTimeEq;

pub const PROTOCOL: u32 = 1;
/// The largest message a connection may send, in bytes.
pub const MAX_MESSAGE: usize = 16 * 1024 * 1024;
/// The largest file `fs.read` returns in one message, in bytes.
pub const MAX_READ: u64 = 8 * 1024 * 1024;

/// Where a connection's responses and events go: the runner's socket, or a test's queue.
pub type Out = Arc<dyn Fn(String) + Send + Sync>;

/// Programs a session runs, in directories of its workspace. A session that must not run programs has none.
pub trait Programs: Send + Sync + 'static {
    /// Trusted extension-host installation on the session machine, when configured by its runner.
    fn extensions(&self) -> Option<Value> { None }
    fn spawn(&self, command: &str, args: &[String], cwd: &str, env: &HashMap<String, String>, emit: Out) -> Result<u64>;
    fn write(&self, id: u64, data: &[u8]) -> Result<()>;
    fn close_input(&self, id: u64) -> Result<()>;
    fn kill(&self, id: u64, signal: &str) -> Result<()>;
}

pub struct Workspace<S: FileStore> {
    pub store: Arc<S>,
    pub docs: DocHub<S>,
    pub programs: Option<Arc<dyn Programs>>,
    /// When set, a connection may look at the workspace but changes nothing until it has signed in.
    authority: Option<Arc<dyn Authority>>,
    /// Seconds since the epoch; the runner supplies it, because a Durable Object has no `SystemTime`.
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    token: Option<String>,
    connections: Mutex<HashMap<u64, Out>>,
    next: AtomicU64,
}

impl<S: FileStore> Workspace<S> {
    pub fn new(store: Arc<S>, token: Option<String>, programs: Option<Arc<dyn Programs>>, dirty: Arc<dyn Fn(&str) + Send + Sync>) -> Arc<Self> {
        Self::with_authority(store, token, programs, dirty, None, Arc::new(|| 0))
    }

    pub fn with_authority(store: Arc<S>, token: Option<String>, programs: Option<Arc<dyn Programs>>, dirty: Arc<dyn Fn(&str) + Send + Sync>, authority: Option<Arc<dyn Authority>>, clock: Arc<dyn Fn() -> u64 + Send + Sync>) -> Arc<Self> {
        Arc::new(Self { docs: DocHub::new(store.clone(), dirty), store, programs, authority, clock, token, connections: Mutex::new(HashMap::new()), next: AtomicU64::new(1) })
    }

    /// A session with no token is open to whoever reaches it.
    fn accepts(&self, token: Option<&str>) -> bool {
        match (&self.token, token) {
            (None, _) => true,
            (Some(want), Some(got)) => want.as_bytes().ct_eq(got.as_bytes()).into(),
            _ => false,
        }
    }

    pub fn connect(self: &Arc<Self>, out: Out) -> Connection<S> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.connections.lock().unwrap().insert(id, out.clone());
        Connection { workspace: self.clone(), id, name: format!("c{id}"), out, ready: false, identity: None, docs: Vec::new(), programs: Vec::new() }
    }

    /// A path changed in the workspace: open documents take it as an edit, and every connection hears of it.
    pub async fn changed(&self, path: &str, kind: &str) {
        self.docs.changed(path).await;
        let message = json!({"ev": "fs.changed", "path": path, "kind": kind}).to_string();
        for out in self.connections.lock().unwrap().values() {
            out(message.clone());
        }
    }

    /// The change callback a runner gives its store's `watch`.
    pub fn watcher(self: &Arc<Self>, runtime: impl Fn(std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) + Send + Sync + 'static) -> Change {
        let workspace = self.clone();
        Arc::new(move |path, kind| {
            let workspace = workspace.clone();
            runtime(Box::pin(async move { workspace.changed(&path, kind).await }));
        })
    }
}

/// One client's connection. Requests are handled one at a time, in the order they arrive.
pub struct Connection<S: FileStore> {
    workspace: Arc<Workspace<S>>,
    id: u64,
    name: String,
    out: Out,
    ready: bool,
    identity: Option<Identity>,
    docs: Vec<String>,
    programs: Vec<u64>,
}

fn text<'a>(request: &'a Value, key: &str) -> Result<&'a str> {
    request.get(key).and_then(Value::as_str).ok_or_else(|| SessionError::new("bad-request", format!("`{key}` is missing or not text.")))
}

fn bytes(request: &Value, key: &str) -> Result<Vec<u8>> {
    B64.decode(text(request, key)?).map_err(|_| SessionError::new("bad-request", format!("`{key}` is not base64.")))
}

impl<S: FileStore> Connection<S> {
    pub async fn handle(&mut self, raw: &str) {
        let request: Value = match serde_json::from_str(raw) {
            Ok(value @ Value::Object(_)) => value,
            _ => {
                (self.out)(json!({"ok": false, "code": "bad-request", "message": "The message is not a request."}).to_string());
                return;
            }
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let response = match self.dispatch(&request).await {
            Ok(Value::Object(mut fields)) => {
                fields.insert("id".into(), id);
                fields.insert("ok".into(), Value::Bool(true));
                Value::Object(fields)
            }
            Ok(_) => json!({"id": id, "ok": true}),
            Err(error) => {
                let mut response = json!({"id": id, "ok": false, "code": error.code, "message": error.message});
                if error.code == "auth-required" {
                    response["login"] = json!(self.workspace.authority.as_ref().map(|a| a.login_url()));
                }
                response
            }
        };
        (self.out)(response.to_string());
    }

    async fn dispatch(&mut self, request: &Value) -> Result<Value> {
        let op = text(request, "op")?;
        if !self.ready && op != "hello" {
            return Err(SessionError::new("unauthorised", "Say hello with the session's token first."));
        }
        let workspace = self.workspace.clone();
        let store = &workspace.store;
        // Looking is open; changing, saving and running are for someone who has signed in.
        let changes = matches!(op, "fs.write" | "fs.mkdir" | "fs.remove" | "fs.rename" | "doc.update" | "doc.save" | "proc.spawn" | "proc.write" | "proc.close-input" | "proc.kill");
        if changes && workspace.authority.is_some() && self.identity.is_none() {
            return Err(SessionError::new("auth-required", "Sign in with GitHub to make changes."));
        }
        match op {
            "hello" => {
                if !self.ready {
                    if !workspace.accepts(request.get("token").and_then(Value::as_str)) {
                        return Err(SessionError::new("unauthorised", "The token is not the session's."));
                    }
                    self.ready = true;
                }
                Ok(json!({"protocol": PROTOCOL, "name": store.name(), "client": self.name, "root": store.root(), "exec": workspace.programs.is_some(), "extensions": workspace.programs.as_ref().and_then(|programs| programs.extensions()), "signin": workspace.authority.as_ref().map(|a| a.login_url()), "identity": self.identity.as_ref().map(|i| i.login.clone())}))
            }
            "auth.login" => {
                let authority = workspace.authority.as_ref().ok_or_else(|| SessionError::new("bad-request", "This session does not ask for a sign-in."))?;
                let identity = authority.verify(text(request, "credential")?, (workspace.clock)()).ok_or_else(|| SessionError::new("unauthorised", "The credential is not genuine or has expired."))?;
                let reply = json!({"login": identity.login, "id": identity.id});
                self.identity = Some(identity);
                Ok(reply)
            }
            "fs.list" => Ok(json!({"entries": store.list(request.get("path").and_then(Value::as_str).unwrap_or("")).await?})),
            "fs.stat" => Ok(json!({"entry": store.stat(request.get("path").and_then(Value::as_str).unwrap_or("")).await?})),
            "fs.read" => {
                let path = text(request, "path")?;
                if store.stat(path).await?.is_some_and(|entry| entry.size > MAX_READ) {
                    return Err(SessionError::new("too-large", "The file is too large to read in one message."));
                }
                let mut data = store.read(path).await?;
                // `offset` and `length` read a slice, so a log read as it grows is not sent whole each time.
                let offset = request.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
                if offset > 0 || request.get("length").is_some() {
                    let start = offset.min(data.len());
                    let end = request.get("length").and_then(Value::as_u64).map_or(data.len(), |n| start.saturating_add(n as usize).min(data.len()));
                    data = data[start..end].to_vec();
                }
                if request.get("encoding").and_then(Value::as_str) == Some("base64") {
                    Ok(json!({"data": B64.encode(&data), "encoding": "base64"}))
                } else {
                    Ok(json!({"data": String::from_utf8_lossy(&data), "encoding": "utf8"}))
                }
            }
            "fs.write" => {
                let path = text(request, "path")?;
                let data = if request.get("encoding").and_then(Value::as_str) == Some("base64") { bytes(request, "data")? } else { text(request, "data")?.as_bytes().to_vec() };
                store.write(path, &data).await?;
                Ok(json!({"mtime": store.stat(path).await?.map_or(0, |entry| entry.mtime)}))
            }
            "fs.mkdir" => store.mkdir(text(request, "path")?).await.map(|_| json!({})),
            "fs.remove" => store.remove(text(request, "path")?, request.get("recursive").and_then(Value::as_bool).unwrap_or(false)).await.map(|_| json!({})),
            "fs.rename" => store.rename(text(request, "from")?, text(request, "to")?).await.map(|_| json!({})),
            "doc.open" => {
                let path = clean(text(request, "path")?)?;
                let vector = match request.get("vector").and_then(Value::as_str) {
                    Some(encoded) => Some(B64.decode(encoded).map_err(|_| SessionError::new("bad-request", "`vector` is not base64."))?),
                    None => None,
                };
                let out = self.out.clone();
                let event_path = path.clone();
                let send = Arc::new(move |update: Vec<u8>| out(json!({"ev": "doc.update", "path": event_path, "update": B64.encode(update)}).to_string()));
                let opened = workspace.docs.attach(&path, &self.name, vector.as_deref(), send).await?;
                if !self.docs.contains(&path) {
                    self.docs.push(path);
                }
                Ok(json!({"update": B64.encode(&opened.update), "vector": B64.encode(&opened.vector), "text": opened.text}))
            }
            "doc.update" => workspace.docs.receive(&clean(text(request, "path")?)?, &self.name, &bytes(request, "update")?).map(|_| json!({})),
            "doc.save" => {
                let (written, mtime) = workspace.docs.flush(&clean(text(request, "path")?)?).await?;
                Ok(json!({"written": written, "mtime": mtime}))
            }
            "doc.close" => {
                let path = clean(text(request, "path")?)?;
                workspace.docs.detach(&path, &self.name);
                self.docs.retain(|open| *open != path);
                Ok(json!({}))
            }
            "proc.spawn" => {
                let programs = workspace.programs.clone().ok_or_else(|| SessionError::new("no-exec", "This session does not run programs."))?;
                let args: Vec<String> = request.get("args").and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
                let env: HashMap<String, String> = request.get("env").and_then(Value::as_object).map(|o| o.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string()))).collect()).unwrap_or_default();
                let cwd = clean(request.get("cwd").and_then(Value::as_str).unwrap_or(""))?;
                let id = programs.spawn(text(request, "command")?, &args, &cwd, &env, self.out.clone())?;
                self.programs.push(id);
                Ok(json!({"pid": id}))
            }
            "proc.write" => self.program(request)?.write(self.pid(request)?, &bytes(request, "data")?).map(|_| json!({})),
            "proc.close-input" => self.program(request)?.close_input(self.pid(request)?).map(|_| json!({})),
            "proc.kill" => self.program(request)?.kill(self.pid(request)?, request.get("signal").and_then(Value::as_str).unwrap_or("TERM")).map(|_| json!({})),
            other => Err(SessionError::new("bad-request", format!("Unknown operation: {other}"))),
        }
    }

    fn program(&self, _request: &Value) -> Result<Arc<dyn Programs>> {
        self.workspace.programs.clone().ok_or_else(|| SessionError::new("no-exec", "This session does not run programs."))
    }

    /// A program id the request names, if this connection started it.
    fn pid(&self, request: &Value) -> Result<u64> {
        let pid = request.get("pid").and_then(Value::as_u64).ok_or_else(|| SessionError::new("bad-request", "`pid` is missing."))?;
        if self.programs.contains(&pid) { Ok(pid) } else { Err(SessionError::new("not-found", "No such program.")) }
    }

    /// The connection is gone: its documents lose their subscriber, and the programs it started are stopped.
    pub fn close(&mut self) {
        self.workspace.connections.lock().unwrap().remove(&self.id);
        for path in self.docs.drain(..) {
            self.workspace.docs.detach(&path, &self.name);
        }
        if let Some(programs) = self.workspace.programs.clone() {
            for pid in self.programs.drain(..) {
                let _ = programs.kill(pid, "KILL");
            }
        }
    }
}
