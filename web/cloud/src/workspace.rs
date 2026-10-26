use super::*;
use futures_util::StreamExt;
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
    time::Duration,
};

#[derive(Default)]
struct Pending {
    closed: bool,
    hello: BTreeSet<String>,
    source: Option<String>,
    checkpoints: bool,
    saves: BTreeMap<String, PendingSave>,
}
struct PendingSave {
    path: String,
    source: String,
    reply: futures_channel::oneshot::Sender<Value>,
}
impl PendingSave {
    async fn finish(self, checkpoints: &crate::checkpoints::Checkpoints, mut reply: Value) {
        if reply["ok"] == true {
            let checkpoint = serde_json::from_value(
                reply
                    .as_object_mut()
                    .and_then(|object| object.remove("checkpoint"))
                    .unwrap_or(Value::Null),
            );
            let stored = match checkpoint {
                Ok(checkpoint) => checkpoints.save(&self.path, &self.source, checkpoint).await,
                Err(_) => Err(bad(502, "The workspace host returned no valid checkpoint.")),
            };
            reply = match stored {
                Ok(manifest) => {
                    reply["durable"] = json!({"id":manifest.id,"sha256":manifest.sha256});
                    reply
                }
                Err(error) => save_failure(
                    reply["id"].clone(),
                    &format!(
                        "The workspace file was saved, but durable recovery could not be recorded. {}",
                        error.message
                    ),
                ),
            };
        }
        let _ = self.reply.send(reply);
    }
}
type Backend = (WebSocket, WebSocket, Rc<RefCell<Pending>>);
struct SaveAdmission(Rc<Cell<usize>>);
impl Drop for SaveAdmission {
    fn drop(&mut self) {
        self.0.set(self.0.get() - 1);
    }
}

async fn deadline<F: std::future::Future>(
    future: F,
    seconds: u64,
) -> std::result::Result<F::Output, ()> {
    match futures_util::future::select(
        Box::pin(future),
        Box::pin(Delay::from(Duration::from_secs(seconds))),
    )
    .await
    {
        futures_util::future::Either::Left((value, _)) => Ok(value),
        _ => Err(()),
    }
}
fn save_failure(id: Value, message: &str) -> Value {
    json!({"id":id,"ok":false,"code":"checkpoint-failed","message":message})
}

async fn forward_save(
    gate: Rc<futures_util::lock::Mutex<()>>,
    backend: WebSocket,
    pending: Rc<RefCell<Pending>>,
    id: Value,
    path: String,
    expires: u64,
) -> Value {
    let Ok(_guard) = deadline(gate.lock(), 20).await else {
        return save_failure(id, "The recovery queue is busy. Try saving again.");
    };
    if pending.borrow().closed {
        return save_failure(
            id,
            "The workspace disconnected before saving. Reconnect and try again.",
        );
    }
    if expires < now() {
        return save_failure(id, "Sign in again before saving.");
    }
    let Some(source) = pending
        .borrow()
        .source
        .clone()
        .filter(|_| pending.borrow().checkpoints)
    else {
        return save_failure(
            id,
            "Update or reconnect the workspace host before saving durable recovery.",
        );
    };
    let key = id.to_string();
    let (sender, receiver) = futures_channel::oneshot::channel();
    pending.borrow_mut().saves.insert(
        key.clone(),
        PendingSave {
            path: path.clone(),
            source,
            reply: sender,
        },
    );
    if backend
        .send(&json!({"id":id,"op":"doc.save","path":path,"checkpoint":true}))
        .is_err()
    {
        pending.borrow_mut().saves.remove(&key);
        return save_failure(
            id,
            "The workspace disconnected before saving. Reconnect and try again.",
        );
    }
    let result = deadline(receiver, 25).await;
    pending.borrow_mut().saves.remove(&key);
    match result {
        Ok(Ok(reply)) => reply,
        _ => save_failure(
            id,
            "The workspace did not confirm durable recovery. Try saving again.",
        ),
    }
}

#[durable_object]
pub struct WorkspaceSession {
    state: State,
    env: Env,
    starting: Rc<Cell<bool>>,
    backends: Rc<RefCell<Vec<Backend>>>,
    checkpoints: Rc<crate::checkpoints::Checkpoints>,
    saving: Rc<futures_util::lock::Mutex<()>>,
    save_waiting: Rc<Cell<usize>>,
}
impl DurableObject for WorkspaceSession {
    fn new(state: State, env: Env) -> Self {
        let checkpoints = Rc::new(crate::checkpoints::Checkpoints::new(state.storage()));
        Self {
            state,
            env,
            starting: Rc::new(Cell::new(false)),
            backends: Rc::new(RefCell::new(Vec::new())),
            checkpoints,
            saving: Rc::new(futures_util::lock::Mutex::new(())),
            save_waiting: Rc::new(Cell::new(0)),
        }
    }
    async fn fetch(&self, req: Request) -> Result<Response> {
        finish(self.handle(req).await)
    }
    async fn websocket_message(
        &self,
        ws: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let attachment = ws.deserialize_attachment::<Value>()?.unwrap_or_default();
        let backend = self
            .backends
            .borrow()
            .iter()
            .find(|(client, _, _)| *client == ws)
            .map(|(_, server, handshakes)| (server.clone(), handshakes.clone()));
        let Some((backend, handshakes)) = backend else {
            return ws.close(Some(1011), Some("Reconnect to the workspace"));
        };
        if attachment["expires"].as_u64().unwrap_or(0) < now() {
            return ws.close(Some(1008), Some("Sign in again"));
        }
        let WebSocketIncomingMessage::String(message) = message else {
            return ws.close(Some(1008), Some("Invalid session message"));
        };
        if message.len() > 16 * 1024 * 1024 {
            return ws.close(Some(1009), Some("Message too large"));
        }
        let Ok(mut data) = serde_json::from_str::<Value>(&message) else {
            return ws.close(Some(1008), Some("Invalid session message"));
        };
        if data["op"] == "doc.restore" {
            return ws.send(&json!({"id":data["id"],"ok":false,"code":"denied","message":"Document restoration belongs to the workspace service."}));
        }
        if data["op"] == "doc.save" {
            let id = data["id"].clone();
            let path = data["path"]
                .as_str()
                .and_then(|path| rayde_session::store::clean(path).ok())
                .filter(|path| !path.is_empty() && path.len() <= 4096);
            if id.to_string().len() > 128 || path.is_none() {
                return ws.send(&save_failure(id, "The Save request is invalid."));
            }
            if self.save_waiting.get() >= 256 {
                return ws.send(&save_failure(
                    id,
                    "Too many saves are waiting. Try saving again.",
                ));
            }
            self.save_waiting.set(self.save_waiting.get() + 1);
            let admission = SaveAdmission(self.save_waiting.clone());
            let gate = self.saving.clone();
            let expires = attachment["expires"].as_u64().unwrap_or(0);
            drop(data);
            drop(message);
            self.state.wait_until(async move {
                let reply =
                    forward_save(gate, backend, handshakes, id, path.unwrap(), expires).await;
                let _ = ws.send(&reply);
                drop(admission);
            });
            return Ok(());
        }
        if data["op"] == "hello" {
            {
                let mut pending = handshakes.borrow_mut();
                if pending.hello.len() >= 64 {
                    return ws.close(Some(1008), Some("Too many session handshakes"));
                }
                let id = data["id"].to_string();
                if id.len() > 128 {
                    return ws.close(Some(1008), Some("Invalid session request ID"));
                }
                pending.hello.insert(id);
            }
            let value = self
                .state
                .storage()
                .get::<Value>("workspace")
                .await?
                .unwrap_or_default();
            data["token"] = value["connection"]["token"].clone();
        }
        backend.send(&data)
    }
    async fn websocket_close(
        &self,
        ws: WebSocket,
        _code: usize,
        _reason: String,
        _clean: bool,
    ) -> Result<()> {
        self.disconnect(&ws);
        Ok(())
    }
    async fn websocket_error(&self, ws: WebSocket, _error: Error) -> Result<()> {
        self.disconnect(&ws);
        Ok(())
    }
    async fn alarm(&self) -> Result<Response> {
        let mut next = u64::MAX;
        for ws in self.state.get_websockets() {
            let value = ws.deserialize_attachment::<Value>()?.unwrap_or_default();
            let expires = value["expires"].as_u64().unwrap_or(0);
            if expires <= now() {
                self.disconnect(&ws);
                let _ = ws.close(Some(1008), Some("Sign in again"));
            } else {
                next = next.min(expires);
            }
        }
        if next != u64::MAX {
            self.state
                .storage()
                .set_alarm(Duration::from_millis(next.saturating_sub(now())))
                .await?;
        }
        Response::empty()
    }
}
impl WorkspaceSession {
    fn disconnect(&self, ws: &WebSocket) {
        self.backends
            .borrow_mut()
            .retain(|(client, backend, pending)| {
                if client == ws {
                    pending.borrow_mut().closed = true;
                    pending.borrow_mut().saves.clear();
                    let _ = backend.close(Some(1000), Some("Closed"));
                    false
                } else {
                    true
                }
            });
    }
    async fn handle(&self, mut req: Request) -> AppResult<Response> {
        let data: Value = if req.path() == "/socket" {
            serde_json::from_str(&req.headers().get("X-RayDE-Identity")?.unwrap_or_default())
                .map_err(|_| bad(403, "The request could not be verified."))?
        } else {
            req.json().await?
        };
        let storage = self.state.storage();
        let mut value = storage.get::<Value>("workspace").await?;
        if req.path() == "/disconnect" {
            for ws in self.state.get_websockets() {
                if ws
                    .deserialize_attachment::<Value>()?
                    .is_some_and(|v| v["sid"] == data["sid"])
                {
                    self.disconnect(&ws);
                    let _ = ws.close(Some(1008), Some("Signed out"));
                }
            }
            return Ok(reply(&json!({}), 200)?);
        }
        if value.as_ref().is_some_and(|v| v["owner"] != data["owner"]) {
            return Err(bad(403, "This workspace belongs to another account."));
        }
        if req.path() == "/checkpoint"
            || req.path() == "/checkpoints"
            || req.path() == "/checkpoint/import"
        {
            if value.is_none() {
                return Err(bad(404, "Workspace not found."));
            }
            let result = if req.path() == "/checkpoints" {
                self.checkpoints.list().await?
            } else if req.path() == "/checkpoint/import" {
                let checkpoint = serde_json::from_value(data["checkpoint"].clone())
                    .map_err(|_| bad(400, "The checkpoint is invalid."))?;
                json!(
                    self.checkpoints
                        .save(text(&data, "path")?, text(&data, "source")?, checkpoint)
                        .await?
                )
            } else {
                self.checkpoints.get(text(&data, "id")?).await?
            };
            return Ok(reply(&result, 200)?);
        }
        if req.path() == "/socket" {
            let record = value.ok_or_else(|| bad(404, "Workspace not found."))?;
            if record["status"] != "ready" {
                return Err(bad(409, "The workspace is still starting."));
            }
            let mut endpoint = Url::parse(text(&record["connection"], "url")?)
                .map_err(|_| bad(502, "Invalid workspace endpoint."))?;
            let scheme = if endpoint.scheme() == "wss" {
                "https"
            } else {
                "http"
            };
            endpoint
                .set_scheme(scheme)
                .map_err(|_| bad(502, "Invalid workspace endpoint."))?;
            let headers = Headers::new();
            headers.set("Upgrade", "websocket")?;
            headers.set("Origin", text(&data, "origin")?)?;
            let response = Fetch::Request(Request::new_with_init(
                endpoint.as_str(),
                RequestInit::new().with_headers(headers),
            )?)
            .send()
            .await?;
            let backend = response
                .websocket()
                .ok_or_else(|| bad(502, "The workspace could not be reached."))?;
            backend.accept()?;
            let pair = WebSocketPair::new()?;
            let handshakes = Rc::new(RefCell::new(Pending::default()));
            let authority = format!("cloud:{}", self.state.id());
            let workspace = record["id"].clone();
            let principal = format!("account:{}", data["owner"]);
            self.state.accept_web_socket(&pair.server);
            pair.server.serialize_attachment(&data)?;
            self.backends.borrow_mut().push((
                pair.server.clone(),
                backend.clone(),
                handshakes.clone(),
            ));
            let client = pair.server.clone();
            let backends = self.backends.clone();
            let checkpoints = self.checkpoints.clone();
            self.state.wait_until(async move {
                if let Ok(mut events) = backend.events() {
                    while let Some(event) = events.next().await {
                        match event {
                            Ok(WebsocketEvent::Message(message)) => {
                                if let Some(text) = message.text() {
                                    let mut text = text;
                                    if let Ok(mut reply) = serde_json::from_str::<Value>(&text) {
                                        let pending_save = handshakes.borrow_mut().saves.remove(&reply["id"].to_string());
                                        if let Some(save) = pending_save {
                                            save.finish(&checkpoints,reply).await;
                                            continue;
                                        }
                                        // Late checkpoint replies are internal payloads, including after a Save timeout.
                                        if reply.get("checkpoint").is_some() {continue;}
                                        if reply.get("id").is_some()
                                            && handshakes.borrow_mut().hello.remove(&reply["id"].to_string())
                                            && reply["ok"] == true
                                        {
                                            // Compute still owns CRDT state: a fresh disk must not replay an older replica's baseline.
                                            let backend = reply["cacheIdentity"].clone();
                                            let valid = backend["version"] == 1
                                                && ["authority", "workspace"].iter().all(|field|
                                                    backend[field].as_str().is_some_and(|value|
                                                        !value.is_empty() && value.len() <= 128));
                                            {
                                                let mut pending = handshakes.borrow_mut();
                                                pending.source = valid.then(||hash(&json!([backend["authority"],backend["workspace"]]).to_string()));
                                                pending.checkpoints = reply["checkpoints"]==1;
                                            }
                                            reply["durableCheckpoints"] = json!(valid && reply["checkpoints"]==1);
                                            reply["cacheIdentity"] = if valid {
                                                json!({
                                                    "version": 1,
                                                    "authority": json!([authority, backend["authority"], backend["workspace"]]).to_string(),
                                                    "workspace": workspace,
                                                    "principal": principal
                                                })
                                            } else { Value::Null };
                                            text = reply.to_string();
                                        }
                                    }
                                    if client.send_with_str(&text).is_err() {
                                        break;
                                    }
                                } else if let Some(bytes) = message.bytes() {
                                    if client.send_with_bytes(bytes).is_err() {
                                        break;
                                    }
                                }
                            }
                            _ => break,
                        }
                    }
                }
                handshakes.borrow_mut().closed=true;
                handshakes.borrow_mut().saves.clear();
                backends.borrow_mut().retain(|(ws, _, _)| *ws != client);
                let _ = client.close(Some(1011), Some("Workspace disconnected"));
                let _ = backend.close(Some(1000), Some("Closed"));
            });
            let earliest = self
                .state
                .get_websockets()
                .iter()
                .filter_map(|ws| {
                    ws.deserialize_attachment::<Value>()
                        .ok()
                        .flatten()
                        .and_then(|v| v["expires"].as_u64())
                })
                .min()
                .unwrap_or(now());
            let duration = data["expires"]
                .as_u64()
                .unwrap_or(now())
                .min(earliest)
                .saturating_sub(now());
            storage.set_alarm(Duration::from_millis(duration)).await?;
            return Ok(Response::from_websocket(pair.client)?);
        }
        if req.path() == "/open" {
            if value.is_none() {
                let record = json!({"id":data["id"],"owner":data["owner"],"repository":data["repository"],"status":"preparing","created":now()});
                storage.put("workspace", &record).await?;
                value = Some(record);
            }
            let mut record = value.unwrap();
            if record["status"] == "failed" {
                record["status"] = json!("preparing");
                record["message"] = Value::Null;
                storage.put("workspace", &record).await?;
            }
            if record["status"] != "ready" && !self.starting.replace(true) {
                // A provider reuses this workspace ID if an interrupted request is retried.
                let starting = self.starting.clone();
                let env = self.env.clone();
                let storage = self.state.storage();
                let mut next = record.clone();
                let access = data["access"].clone();
                self.state.wait_until(async move {
                    match prepare(&env, &next, access).await {
                        Ok(connection) => {
                            next["connection"] = connection;
                            next["status"] = json!("ready");
                            next["message"] = Value::Null;
                        }
                        Err(error) => {
                            next["status"] = json!("failed");
                            next["message"] = json!(error.message);
                        }
                    }
                    let _ = storage.put("workspace", next).await;
                    starting.set(false);
                });
            }
            return Ok(reply(&public_workspace(&record), 200)?);
        }
        if req.path() == "/state" {
            let record = value.ok_or_else(|| bad(404, "Workspace not found."))?;
            return Ok(reply(&public_workspace(&record), 200)?);
        }
        Err(bad(404, "Unknown workspace operation."))
    }
}
async fn prepare(env: &Env, value: &Value, access: Value) -> AppResult<Value> {
    let url = config(env, "RUNNER_URL").unwrap_or_else(|| "https://runner.internal".into());
    let endpoint = Url::parse(&url).map_err(|_| bad(503, "Invalid runner configuration."))?;
    if endpoint.scheme() != "https" && config(env, "LOCAL_DEV").as_deref() != Some("1") {
        return Err(bad(503, "The runner requires HTTPS."));
    }
    let mut req = request(
        &format!("{}/workspaces/open", url.trim_end_matches('/')),
        &json!({"id":value["id"],"owner":value["owner"],"repository":value["repository"],"checkout":{"accessToken":access}}),
    )?;
    req.headers_mut()?.set(
        "Authorization",
        &format!(
            "Bearer {}",
            config(env, "RUNNER_SECRET")
                .ok_or_else(|| bad(503, "Workspace compute is not configured."))?
        ),
    )?;
    let mut response = if let Ok(binding) = env.service("RUNNER") {
        binding.fetch_request(req).await?
    } else {
        Fetch::Request(req).send().await?
    };
    if response.status_code() >= 400 {
        return Err(bad(502, "The workspace could not be prepared."));
    }
    let connection: Value = response.json().await?;
    let endpoint = Url::parse(text(&connection, "url")?)
        .map_err(|_| bad(502, "Invalid workspace endpoint."))?;
    if endpoint.scheme() != "wss"
        && !(config(env, "LOCAL_DEV").as_deref() == Some("1") && endpoint.scheme() == "ws")
    {
        return Err(bad(502, "The workspace requires a secure connection."));
    }
    let token =
        text(&connection, "token").map_err(|_| bad(502, "The workspace credential is missing."))?;
    if token.is_empty() || token.len() > 4096 {
        return Err(bad(502, "Invalid workspace credential."));
    }
    let project = connection["project"]
        .as_str()
        .filter(|p| !p.starts_with('/') && !p.split('/').any(|part| part == ".."));
    Ok(json!({"url":endpoint.as_str(),"token":token,"project":project}))
}
