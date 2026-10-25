use super::*;
use futures_util::StreamExt;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    time::Duration,
};

#[durable_object]
pub struct WorkspaceSession {
    state: State,
    env: Env,
    starting: Rc<Cell<bool>>,
    backends: Rc<RefCell<Vec<(WebSocket, WebSocket)>>>,
}
impl DurableObject for WorkspaceSession {
    fn new(state: State, env: Env) -> Self {
        Self {
            state,
            env,
            starting: Rc::new(Cell::new(false)),
            backends: Rc::new(RefCell::new(Vec::new())),
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
            .find(|(client, _)| *client == ws)
            .map(|(_, server)| server.clone());
        let Some(backend) = backend else {
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
        if data["op"] == "hello" {
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
        self.backends.borrow_mut().retain(|(client, backend)| {
            if client == ws {
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
            self.state.accept_web_socket(&pair.server);
            pair.server.serialize_attachment(&data)?;
            self.backends
                .borrow_mut()
                .push((pair.server.clone(), backend.clone()));
            let client = pair.server.clone();
            let backends = self.backends.clone();
            self.state.wait_until(async move {
                if let Ok(mut events) = backend.events() {
                    while let Some(event) = events.next().await {
                        match event {
                            Ok(WebsocketEvent::Message(message)) => {
                                if let Some(text) = message.text() {
                                    if client.send_with_str(text).is_err() {
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
                backends.borrow_mut().retain(|(ws, _)| *ws != client);
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
