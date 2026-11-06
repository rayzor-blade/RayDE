//! Anonymous demo compute only. Dedicated repository workspaces keep their existing runner.
use super::*;
use serde::{Deserialize, Serialize};
use std::{rc::Rc, time::Duration};
use worker::{
    js_sys::{Function, Object, Promise, Reflect},
    wasm_bindgen::{JsCast, JsValue},
    wasm_bindgen_futures::JsFuture,
};

pub(crate) fn enabled(env: &Env) -> bool {
    config(env, "DEMO_COMPUTE").as_deref() == Some("containers")
}

#[derive(Clone, Serialize, Deserialize)]
struct Lease {
    id: String,
    lease: String,
    release: String,
    toolchain: String,
    expires: u64,
    token: String,
    origin: String,
    ready: bool,
    ended: bool,
}
impl Lease {
    fn health(&self) -> Value {
        json!({"version":1,"id":self.id,"release":self.release,"toolchain":self.toolchain,"expires":self.expires,"generation":1})
    }
    fn environment(&self) -> Value {
        json!({
            "RAYDE_DEMO_ID":self.id, "RAYDE_DEMO_LEASE":self.lease, "RAYDE_DEMO_RELEASE":self.release,
            "RAYDE_DEMO_TOOLCHAIN":self.toolchain, "RAYDE_DEMO_EXPIRES":self.expires.to_string(),
            "RAYDE_DEMO_TOKEN":self.token, "RAYDE_DEMO_GENERATION":"1", "RAYDE_DEMO_ORIGIN":self.origin,
        })
    }
    fn connection(&self) -> Value {
        json!({"provider":"demo-container","id":self.id,"token":self.token,
        "project":"build.hxml","generation":1,"toolchain":self.toolchain,"recoverable":false})
    }
    fn live(&self) -> AppResult<()> {
        if self.ended || self.expires * 1000 <= now() {
            Err(bad(410, "The demo session expired."))
        } else {
            Ok(())
        }
    }
}

pub(crate) async fn prepare(env: &Env, value: &Value) -> AppResult<Value> {
    rpc(env, "DEMO_CONTAINERS", text(value, "id")?, "open", value).await
}
pub(crate) async fn delete(env: &Env, id: &str) -> AppResult<()> {
    rpc(env, "DEMO_CONTAINERS", id, "end", &json!({"id":id})).await?;
    Ok(())
}
pub(crate) async fn connect(env: &Env, connection: &Value, data: &Value) -> AppResult<Response> {
    let id = text(connection, "id")?;
    if !workspace_id(id) {
        return Err(bad(502, "Invalid demo connection."));
    }
    let headers = Headers::new();
    headers.set("Upgrade", "websocket")?;
    headers.set(
        "X-RayDE-Container",
        &json!({"id":id,"token":connection["token"],"origin":data["origin"]}).to_string(),
    )?;
    Ok(env
        .durable_object("DEMO_CONTAINERS")?
        .get_by_name(id)?
        .fetch_with_request(Request::new_with_init(
            "https://container/socket",
            RequestInit::new().with_headers(headers),
        )?)
        .await?)
}

#[durable_object]
pub struct DemoContainer {
    state: State,
    env: Env,
    gate: Rc<futures_util::lock::Mutex<()>>,
}
impl DurableObject for DemoContainer {
    fn new(state: State, env: Env) -> Self {
        let value = Self {
            state,
            env,
            gate: Rc::new(futures_util::lock::Mutex::new(())),
        };
        if let Some(container) = value.state.container().filter(|c| c.running()) {
            value.state.wait_until(async move {
                let _ = inactivity(&container).await;
            });
        }
        value
    }
    async fn fetch(&self, req: Request) -> Result<Response> {
        finish(self.handle(req).await)
    }
    async fn alarm(&self) -> Result<Response> {
        let _guard = self.gate.lock().await;
        if let Some(mut lease) = self.state.storage().get::<Lease>("lease").await? {
            if lease.expires * 1000 <= now() || lease.ended {
                lease.ended = true;
                self.state.storage().put("lease", &lease).await?;
                if self.stop(&lease.id).await.is_err() {
                    self.state
                        .storage()
                        .set_alarm(Duration::from_secs(30))
                        .await?;
                }
            } else {
                self.schedule(&lease).await?;
            }
        }
        Response::empty()
    }
}

impl DemoContainer {
    async fn handle(&self, mut req: Request) -> AppResult<Response> {
        // Disabling new starts must never disable cleanup of an existing billable lease.
        if req.path() == "/open" && !enabled(&self.env) {
            return Err(bad(503, "Demo container compute is not enabled."));
        }
        let data: Value = if req.path() == "/socket" {
            serde_json::from_str(&req.headers().get("X-RayDE-Container")?.unwrap_or_default())
                .map_err(|_| bad(403, "Invalid demo connection."))?
        } else {
            req.json().await?
        };
        let id = text(&data, "id")?;
        if !workspace_id(id)
            || self.state.id().to_string()
                != self
                    .env
                    .durable_object("DEMO_CONTAINERS")?
                    .id_from_name(id)?
                    .to_string()
        {
            return Err(bad(403, "Invalid demo container identity."));
        }
        let _guard = self.gate.lock().await;
        let storage = self.state.storage();
        let previous = storage.get::<Lease>("lease").await?;
        if req.path() == "/end" {
            storage.put("ended", true).await?;
            if let Some(mut lease) = previous {
                lease.ended = true;
                storage.put("lease", &lease).await?;
                storage.set_alarm(Duration::from_secs(30)).await?;
            }
            self.stop(id).await?;
            storage.delete_alarm().await?;
            return Ok(reply(&json!({"deleted":true}), 200)?);
        }
        if storage.get::<bool>("ended").await?.unwrap_or(false) {
            return Err(bad(410, "The demo session ended."));
        }
        if req.path() == "/socket" {
            let lease = previous.ok_or_else(|| bad(404, "Start the demo session first."))?;
            lease.live()?;
            if !lease.ready
                || data["token"].as_str() != Some(&lease.token)
                || data["origin"].as_str() != Some(&lease.origin)
                || req
                    .headers()
                    .get("Upgrade")?
                    .is_none_or(|v| !v.eq_ignore_ascii_case("websocket"))
            {
                return Err(bad(403, "Invalid demo connection."));
            }
            if !self.running(id).await? {
                return Err(bad(
                    409,
                    "The demo compute stopped. Its saved changes are retained for recovery.",
                ));
            }
            let headers = Headers::new();
            headers.set("Upgrade", "websocket")?;
            headers.set("Origin", &lease.origin)?;
            return self
                .fetch_port(
                    id,
                    "session",
                    Request::new_with_init(
                        "http://container/session",
                        RequestInit::new().with_headers(headers),
                    )?,
                )
                .await;
        }
        if req.path() != "/open" {
            return Err(bad(404, "Unknown demo container operation."));
        }
        let demo = &data["repository"]["demo"];
        let release = text(demo, "release")?;
        let key = text(demo, "lease")?;
        let expires = demo["expires"]
            .as_u64()
            .filter(|v| *v > now() / 1000 && *v <= now() / 1000 + 900)
            .ok_or_else(|| bad(410, "The demo lease expired."))?;
        let toolchain = config(&self.env, "DEMO_TOOLCHAIN")
            .filter(|v| opaque(v))
            .ok_or_else(|| bad(503, "Demo toolchain is not configured."))?;
        let origin = config(&self.env, "DEMO_ORIGIN")
            .ok_or_else(|| bad(503, "Demo origin is not configured."))?;
        if data["owner"] != format!("demo:{id}")
            || data["repository"]["id"] != 0
            || !workspace_id(key)
            || !opaque(release)
            || config(&self.env, "DEMO_RELEASE").as_deref() != Some(release)
            || hash(&format!("demo:{release}:{key}")) != id
        {
            return Err(bad(403, "Invalid demo container lease."));
        }
        let mut lease = if let Some(previous) = previous {
            if previous.id != id
                || previous.lease != key
                || previous.release != release
                || previous.expires != expires
                || previous.toolchain != toolchain
                || previous.origin != origin
            {
                return Err(bad(
                    409,
                    "The demo container belongs to another lease or image.",
                ));
            }
            previous
        } else {
            Lease {
                id: id.into(),
                lease: key.into(),
                release: release.into(),
                toolchain,
                expires,
                origin,
                token: random()?,
                ready: false,
                ended: false,
            }
        };
        lease.live()?;
        // Persist identity and a kill alarm before starting any billable compute.
        storage.put("lease", &lease).await?;
        self.schedule(&lease).await?;
        if !self.running(id).await? {
            // A new image has no visitor filesystem. Never relabel it as a recovered used session.
            if lease.ready {
                return Err(bad(
                    409,
                    "The demo compute stopped. Its saved changes are retained for recovery.",
                ));
            }
            self.start(&lease).await?;
        }
        let ready = workspace::deadline(
            async {
                for _ in 0..180 {
                    if let Ok(mut response) = self
                        .fetch_port(
                            id,
                            "health",
                            Request::new("http://container/health", Method::Get)?,
                        )
                        .await
                    {
                        if response.status_code() == 200 {
                            let body = response.text().await?;
                            if body.len() > 4096
                                || serde_json::from_str::<Value>(&body).ok().as_ref()
                                    != Some(&lease.health())
                            {
                                return Err(bad(
                                    502,
                                    "The demo container does not match its pinned image and lease.",
                                ));
                            }
                            return Ok(());
                        }
                    }
                    Delay::from(Duration::from_millis(250)).await;
                }
                Err(bad(504, "The demo container did not become ready."))
            },
            50,
        )
        .await
        .map_err(|_| bad(504, "The demo container did not become ready."))?;
        if let Err(error) = ready {
            // No visitor has attached yet. A failed fresh boot may be retried on its original lease.
            self.stop(id).await?;
            return Err(error);
        }
        lease.live()?;
        lease.ready = true;
        storage.put("lease", &lease).await?;
        Ok(reply(&lease.connection(), 200)?)
    }
    async fn schedule(&self, lease: &Lease) -> Result<()> {
        self.state
            .storage()
            .set_alarm(Duration::from_millis(
                (lease.expires * 1000).saturating_sub(now()).max(1),
            ))
            .await
    }
    fn test_runtime(&self) -> Option<Fetcher> {
        if config(&self.env, "LOCAL_DEV").as_deref() == Some("1") {
            self.env.service("DEMO_CONTAINER_RUNTIME").ok()
        } else {
            None
        }
    }
    async fn running(&self, id: &str) -> AppResult<bool> {
        if let Some(runtime) = self.test_runtime() {
            let mut response = runtime
                .fetch_request(request(
                    &format!("https://container/{id}/running"),
                    &json!({}),
                )?)
                .await?;
            if response.status_code() != 200 {
                return Err(bad(503, "Demo container control is unavailable."));
            }
            return Ok(response.json::<Value>().await?["running"] == true);
        }
        Ok(self
            .state
            .container()
            .ok_or_else(|| bad(503, "No demo container image is bound."))?
            .running())
    }
    async fn start(&self, lease: &Lease) -> AppResult<()> {
        if let Some(runtime) = self.test_runtime() {
            let response = runtime
                .fetch_request(request(
                    &format!("https://container/{}/start", lease.id),
                    &json!({"env":lease.environment(),"enableInternet":false,"instance":instance(&self.env)?}),
                )?)
                .await?;
            if response.status_code() != 200 {
                return Err(bad(503, "The demo container could not start."));
            }
            return Ok(());
        }
        let container = self
            .state
            .container()
            .ok_or_else(|| bad(503, "No demo container image is bound."))?;
        // worker 0.8.7's startup wrapper uses Map for env. The platform requires a plain Record.
        let options = Object::new();
        let environment = Object::new();
        for (name, value) in lease.environment().as_object().unwrap() {
            set(
                &environment,
                name,
                &JsValue::from_str(value.as_str().unwrap()),
            )?;
        }
        set(&options, "env", environment.as_ref())?;
        set(&options, "enableInternet", &JsValue::FALSE)?;
        let images = Reflect::get(container.as_ref(), &JsValue::from_str("images"))
            .map_err(|_| bad(503, "Demo container images are unavailable."))?;
        let image = Reflect::get(&images, &JsValue::from_str("base"))
            .ok()
            .and_then(|v| v.as_string())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| bad(503, "The demo base image is missing."))?;
        set(&options, "image", &JsValue::from_str(&image))?;
        // Size comes from reviewed application configuration, never from a visitor's request.
        set(&options, "instance", &JsValue::from_str(instance(&self.env)?))?;
        call(&container, "start", options.as_ref())?;
        inactivity(&container).await.map_err(Failure::from)
    }
    async fn stop(&self, id: &str) -> AppResult<()> {
        if let Some(runtime) = self.test_runtime() {
            let response = runtime
                .fetch_request(request(
                    &format!("https://container/{id}/destroy"),
                    &json!({}),
                )?)
                .await?;
            if response.status_code() != 200 {
                return Err(bad(503, "Demo container cleanup is pending."));
            }
            return Ok(());
        }
        self.state
            .container()
            .ok_or_else(|| bad(503, "No demo container image is bound."))?
            .destroy(Some("Demo lease ended"))
            .await?;
        Ok(())
    }
    async fn fetch_port(&self, id: &str, path: &str, req: Request) -> AppResult<Response> {
        if let Some(runtime) = self.test_runtime() {
            let mut init = RequestInit::new();
            init.with_method(req.method())
                .with_headers(req.headers().clone());
            return Ok(runtime
                .fetch(format!("https://container/{id}/{path}"), Some(init))
                .await?);
        }
        Ok(self
            .state
            .container()
            .ok_or_else(|| bad(503, "No demo container image is bound."))?
            .get_tcp_port(8080)?
            .fetch_request(req)
            .await?)
    }
}
/// The platform's named instance size for a demo container, from `DEMO_INSTANCE`.
fn instance(env: &Env) -> AppResult<&'static str> {
    const SIZES: [&str; 6] = ["lite", "basic", "standard-1", "standard-2", "standard-3", "standard-4"];
    let wanted = config(env, "DEMO_INSTANCE");
    match wanted.as_deref() {
        None => Ok("standard-1"),
        Some(name) => SIZES.iter().copied().find(|size| *size == name).ok_or_else(|| bad(503, "Invalid demo container size.")),
    }
}
fn set(object: &Object, name: &str, value: &JsValue) -> AppResult<()> {
    Reflect::set(object, &JsValue::from_str(name), value)
        .ok()
        .filter(|v| *v)
        .ok_or_else(|| bad(503, "Invalid demo container options."))?;
    Ok(())
}
fn call(container: &Container, name: &str, argument: &JsValue) -> Result<JsValue> {
    let function = Reflect::get(container.as_ref(), &JsValue::from_str(name))?
        .dyn_into::<Function>()
        .map_err(|_| Error::RustError("Container API is unavailable.".into()))?;
    Ok(function.call1(container.as_ref(), argument)?)
}
async fn inactivity(container: &Container) -> Result<()> {
    let promise = call(
        container,
        "setInactivityTimeout",
        &JsValue::from_f64(300_000.),
    )?
    .dyn_into::<Promise>()
    .map_err(|_| Error::RustError("Container inactivity API is unavailable.".into()))?;
    JsFuture::from(promise).await?;
    Ok(())
}
