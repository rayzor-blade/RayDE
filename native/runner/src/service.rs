use super::*;
use crate::registry::{Cell, Record, Registry};
use axum::{
    Router,
    extract::{DefaultBodyLimit, Path as RoutePath, State, ws::WebSocketUpgrade},
    http::{HeaderMap, header},
    routing::{get, post},
};
use std::{
    net::SocketAddr,
    sync::{Arc, atomic::Ordering},
    time::Duration,
};
use tokio::sync::{Semaphore, oneshot, watch};

struct Service {
    config: Config,
    secret: String,
    registry: Registry,
    http: reqwest::Client,
    control: Arc<Semaphore>,
    base: String,
    halt: watch::Sender<bool>,
}
pub struct Running {
    pub address: SocketAddr,
    service: Arc<Service>,
    stop: Option<oneshot::Sender<()>>,
    done: tokio::task::JoinHandle<()>,
}
impl Running {
    pub async fn shutdown(mut self) {
        self.service.halt.send_replace(true);
        for cell in self.service.registry.records.lock().await.values() {
            cell.closed.send_modify(|generation| *generation += 1);
        }
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if self
                    .service
                    .registry
                    .records
                    .lock()
                    .await
                    .values()
                    .all(|cell| cell.connections.available_permits() == 8)
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        if tokio::time::timeout(Duration::from_secs(4), &mut self.done)
            .await
            .is_err()
        {
            self.done.abort();
        }
    }
}
pub async fn start(config: Config) -> Result<Running> {
    config.validate()?;
    {
        use tokio::io::AsyncReadExt;
        let mut binary = tokio::fs::File::open(&config.session_binary).await?;
        let mut magic = [0u8; 4];
        binary.read_exact(&mut magic).await?;
        if magic != *b"\x7fELF" {
            return Err(Failure(
                StatusCode::BAD_REQUEST,
                "The guest session binary must be a Linux ELF executable.",
            ));
        }
    }
    let metadata = tokio::fs::symlink_metadata(&config.secret_file).await?;
    if !metadata.file_type().is_file() || metadata.len() > 4096 {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(invalid());
        }
    }
    let secret = tokio::fs::read_to_string(&config.secret_file)
        .await?
        .trim()
        .to_owned();
    if secret.len() < 32 || secret.len() > 512 || secret.contains(['\r', '\n', '\0']) {
        return Err(invalid());
    }
    let registry = Registry::load(&config.state_root).await?;
    #[cfg(target_os = "linux")]
    {
        let boot = tokio::fs::read("/proc/sys/kernel/random/boot_id").await?;
        match tokio::fs::read(config.state_root.join("boot-id")).await {
            Ok(old) if old != boot => {
                if registry
                    .records
                    .lock()
                    .await
                    .values()
                    .any(|cell| cell.active.load(Ordering::Acquire))
                {
                    return Err(Failure(
                        StatusCode::CONFLICT,
                        "The host restarted. Reconcile compute before starting this runner.",
                    ));
                }
                private_write(&config.state_root.join("boot-id"), &boot).await?;
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                private_write(&config.state_root.join("boot-id"), &boot).await?
            }
            Err(_) => return Err(unavailable()),
        }
    }
    let version = command::call(&config, ["--version"], 5).await?;
    if String::from_utf8_lossy(&version).trim() != "msb 0.7.11" {
        return Err(Failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "The runner requires the tested MSB version.",
        ));
    }
    let label = format!("rayde.runner={}", registry.instance);
    let inventory = command::call(
        &config,
        ["status", "--all", "--label", &label, "--format", "json"],
        5,
    )
    .await?;
    let inventory: Vec<serde_json::Value> =
        serde_json::from_slice(&inventory).map_err(|_| unavailable())?;
    let records = registry.records.lock().await;
    for item in inventory {
        if !records.values().any(|cell| {
            cell.record
                .try_lock()
                .is_ok_and(|record| Some(record.sandbox.as_str()) == item["name"].as_str())
        }) {
            return Err(Failure(
                StatusCode::CONFLICT,
                "Unregistered compute needs reconciliation.",
            ));
        }
    }
    drop(records);
    let listener = tokio::net::TcpListener::bind(config.listen).await?;
    let address = listener.local_addr()?;
    let base = config
        .public_url
        .clone()
        .unwrap_or_else(|| format!("ws://{address}"));
    let endpoint = reqwest::Url::parse(&base).map_err(|_| invalid())?;
    if endpoint.scheme() != "ws"
        || endpoint
            .host_str()
            .is_none_or(|host| !matches!(host, "127.0.0.1" | "localhost" | "[::1]" | "::1"))
        || endpoint.path() != "/"
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
    {
        return Err(invalid());
    }
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| unavailable())?;
    let (halt, _) = watch::channel(false);
    let service = Arc::new(Service {
        config,
        secret,
        registry,
        http,
        control: Arc::new(Semaphore::new(4)),
        base: base.trim_end_matches('/').into(),
        halt,
    });
    let router = Router::new()
        .route("/health", get(|| async { "ready" }))
        .route("/workspaces/open", post(open))
        .route("/workspaces/delete", post(delete))
        .route("/workspaces/:id/session", get(socket))
        .layer(DefaultBodyLimit::max(32 * 1024))
        .with_state(service.clone());
    let (stop, stopped) = oneshot::channel();
    let done = tokio::spawn(async move {
        let _ = axum::serve(listener, router)
            .with_graceful_shutdown(async {
                let _ = stopped.await;
            })
            .await;
    });
    Ok(Running {
        address,
        service,
        stop: Some(stop),
        done,
    })
}
fn authenticate(service: &Service, headers: &HeaderMap) -> Result<()> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if !token.is_some_and(|token| matches_secret(token, &service.secret)) {
        return Err(Failure(
            StatusCode::UNAUTHORIZED,
            "The provisioning credential is invalid.",
        ));
    }
    Ok(())
}
fn response(value: serde_json::Value) -> Response {
    let mut response = Json(value).into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        header::HeaderValue::from_static("no-store"),
    );
    response
}
async fn open(
    State(service): State<Arc<Service>>,
    headers: HeaderMap,
    Json(request): Json<Open>,
) -> Result<Response> {
    authenticate(&service, &headers)?;
    let _permit = service.control.clone().try_acquire_owned().map_err(|_| {
        Failure(
            StatusCode::TOO_MANY_REQUESTS,
            "The provisioning queue is busy.",
        )
    })?;
    if request.owner == 0
        || !valid_id(&request.id)
        || request.id != workspace_id(request.owner, request.repository.id)
        || !valid_repository(&request.repository)
    {
        return Err(invalid());
    }
    let mut halt = service.halt.subscribe();
    if *halt.borrow() {
        return Err(unavailable());
    }
    let work = async {
        let local = checkout::authorize(&service.config, &request, &service.http).await?;
        service.open(request, local).await
    };
    let result = tokio::select! {
        _ = halt.changed() => return Err(unavailable()),
        result = tokio::time::timeout(Duration::from_secs(180), work) => {
            result.map_err(|_| unavailable())??
        }
    };
    Ok(response(result))
}
async fn delete(
    State(service): State<Arc<Service>>,
    headers: HeaderMap,
    Json(request): Json<Delete>,
) -> Result<Response> {
    authenticate(&service, &headers)?;
    if *service.halt.borrow() {
        return Err(unavailable());
    }
    if !valid_id(&request.id) || request.owner == 0 {
        return Err(invalid());
    }
    let _permit = service.control.clone().try_acquire_owned().map_err(|_| {
        Failure(
            StatusCode::TOO_MANY_REQUESTS,
            "The provisioning queue is busy.",
        )
    })?;
    let cell = service
        .registry
        .records
        .lock()
        .await
        .get(&request.id)
        .cloned()
        .ok_or(Failure(StatusCode::NOT_FOUND, "Workspace not found."))?;
    let mut record = cell.record.lock().await;
    if record.owner != request.owner {
        return Err(Failure(
            StatusCode::FORBIDDEN,
            "This workspace belongs to another account.",
        ));
    }
    let _work = service.registry.work(&cell)?;
    record.phase = "deleting".into();
    service.registry.save(&record).await?;
    cell.closed.send_modify(|generation| *generation += 1);
    service.cleanup(&record).await?;
    record.phase = "deleted".into();
    record.token = random();
    service.registry.save(&record).await?;
    cell.deactivate();
    let checkout = service.config.state_root.join("checkout").join(&record.id);
    let _ = tokio::fs::remove_dir_all(checkout).await;
    Ok(response(serde_json::json!({"deleted":true})))
}
async fn socket(
    State(service): State<Arc<Service>>,
    RoutePath(id): RoutePath<String>,
    upgrade: WebSocketUpgrade,
) -> Result<Response> {
    if !valid_id(&id) {
        return Err(invalid());
    }
    let cell = service
        .registry
        .records
        .lock()
        .await
        .get(&id)
        .cloned()
        .ok_or(Failure(StatusCode::NOT_FOUND, "Workspace not found."))?;
    let permit = cell.connections.clone().try_acquire_owned().map_err(|_| {
        Failure(
            StatusCode::TOO_MANY_REQUESTS,
            "The workspace has too many connections.",
        )
    })?;
    let record = cell
        .record
        .try_lock()
        .map_err(|_| Failure(StatusCode::CONFLICT, "The workspace is busy."))?
        .clone();
    if record.phase != "ready" {
        return Err(Failure(StatusCode::CONFLICT, "The workspace is not ready."));
    }
    let config = service.config.clone();
    Ok(upgrade
        .max_message_size(rayde_session::session::MAX_MESSAGE)
        .max_frame_size(rayde_session::session::MAX_MESSAGE)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            tunnel::relay(socket, config, cell, record).await;
        })
        .into_response())
}
impl Service {
    async fn inventory(&self, id: Option<&str>) -> Result<Vec<serde_json::Value>> {
        let mut args = vec![
            "status".to_owned(),
            "--all".into(),
            "--format".into(),
            "json".into(),
        ];
        if let Some(id) = id {
            args.extend([
                "--label".into(),
                format!("rayde.runner={}", self.registry.instance),
                "--label".into(),
                format!("rayde.workspace={id}"),
            ]);
        }
        let bytes = command::call(&self.config, args, 5).await?;
        serde_json::from_slice(&bytes).map_err(|_| unavailable())
    }
    async fn cleanup(&self, record: &Record) -> Result<()> {
        let inventory = self.inventory(Some(&record.id)).await?;
        let expected =
            |items: &[serde_json::Value]| items.iter().any(|item| item["name"] == record.sandbox);
        if expected(&self.inventory(None).await?) && !expected(&inventory) {
            return Err(Failure(
                StatusCode::CONFLICT,
                "Unverified sandbox needs reconciliation.",
            ));
        }
        if inventory.is_empty() {
            return Ok(());
        }
        for item in inventory {
            let name = item["name"].as_str().ok_or_else(unavailable)?;
            if item["status"] != "Stopped"
                && command::call(&self.config, ["ping", name], 5)
                    .await
                    .is_err()
            {
                return Err(Failure(
                    StatusCode::CONFLICT,
                    "Sandbox runtime ownership needs reconciliation.",
                ));
            }
        }
        let runner = format!("rayde.runner={}", self.registry.instance);
        let workspace = format!("rayde.workspace={}", record.id);
        command::call(
            &self.config,
            [
                "remove", "--force", "--label", &runner, "--label", &workspace,
            ],
            30,
        )
        .await?;
        if !self.inventory(Some(&record.id)).await?.is_empty()
            || expected(&self.inventory(None).await?)
        {
            return Err(unavailable());
        }
        Ok(())
    }
    async fn launch_session(&self, record: &Record) -> Result<serde_json::Value> {
        command::call(
            &self.config,
            [
                "exec",
                &record.sandbox,
                "--detach",
                "--no-stdin",
                "--",
                "/opt/rayde-session",
                "--root",
                "/workspace/project",
                "--state-root",
                "/state",
                "--host",
                "127.0.0.1",
                "--port",
                "7070",
                "--raw-port",
                "7071",
                "--token",
                tunnel::GUEST_TOKEN,
                "--exec",
            ],
            10,
        )
        .await?;
        for _ in 0..20 {
            if let Ok(identity) = tunnel::probe(&self.config, &record.sandbox).await {
                return Ok(identity);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        Err(unavailable())
    }
    async fn open(&self, request: Open, local: Option<PathBuf>) -> Result<serde_json::Value> {
        let cell = {
            let mut records = self.registry.records.lock().await;
            if let Some(cell) = records.get(&request.id) {
                cell.clone()
            } else {
                if records.len() >= 256
                    || records
                        .values()
                        .filter(|cell| cell.active.load(Ordering::Acquire))
                        .count()
                        >= self.config.max_workspaces
                {
                    return Err(Failure(
                        StatusCode::TOO_MANY_REQUESTS,
                        "The runner workspace limit was reached.",
                    ));
                }
                let record = Record {
                    version: 1,
                    id: request.id.clone(),
                    owner: request.owner,
                    repository: request.repository.clone(),
                    sandbox: format!("rayde-{}-{}-1", &self.registry.instance[..16], request.id),
                    token: random(),
                    phase: "preparing".into(),
                    generation: 1,
                    project: None,
                    identity: None,
                };
                self.registry.save(&record).await?;
                let cell = Arc::new(Cell::new(record));
                records.insert(request.id.clone(), cell.clone());
                cell
            }
        };
        let mut record = cell.record.lock().await;
        if record.owner != request.owner || record.repository != request.repository {
            return Err(Failure(
                StatusCode::FORBIDDEN,
                "Workspace ownership or repository binding changed.",
            ));
        }
        if record.phase == "ready" {
            let identity = match tunnel::probe(&self.config, &record.sandbox).await {
                Ok(identity) => Some(identity),
                Err(_) => {
                    if command::call(&self.config, ["ping", &record.sandbox], 5)
                        .await
                        .is_ok()
                    {
                        self.launch_session(&record).await.ok()
                    } else {
                        None
                    }
                }
            };
            if identity.is_none() || identity != record.identity {
                record.phase = "recovery-required".into();
                self.registry.save(&record).await?;
                return Err(Failure(
                    StatusCode::CONFLICT,
                    "The workspace needs recovery; its checkout will not be replaced.",
                ));
            }
            self.registry.save(&record).await?;
            return Ok(self.connection(&record));
        }
        if record.phase == "recovery-required" {
            return Err(Failure(
                StatusCode::CONFLICT,
                "The workspace needs recovery; its checkout will not be replaced.",
            ));
        }
        if record.phase == "deleting" {
            return Err(Failure(
                StatusCode::CONFLICT,
                "Complete workspace cleanup before reopening.",
            ));
        }
        let work = self.registry.work(&cell)?;
        if !cell.active.load(Ordering::Acquire) {
            let records = self.registry.records.lock().await;
            if records
                .values()
                .filter(|cell| cell.active.load(Ordering::Acquire))
                .count()
                >= self.config.max_workspaces
            {
                return Err(Failure(
                    StatusCode::TOO_MANY_REQUESTS,
                    "The runner workspace limit was reached.",
                ));
            }
            cell.active.store(true, Ordering::Release);
        }
        if record.phase == "deleted" {
            record.generation = record.generation.checked_add(1).ok_or_else(unavailable)?;
            record.token = random();
            record.sandbox = format!(
                "rayde-{}-{}-{}",
                &self.registry.instance[..16],
                record.id,
                record.generation
            );
        }
        record.phase = "preparing".into();
        self.registry.save(&record).await?;
        let result = self
            .provision(&request, &mut record, local, work.clone())
            .await;
        let checkout = self.config.state_root.join("checkout").join(&record.id);
        let _ = tokio::fs::remove_dir_all(checkout).await;
        if let Err(error) = result {
            if self.cleanup(&record).await.is_ok() {
                record.phase = "failed".into();
                cell.deactivate();
            } else {
                record.phase = "recovery-required".into();
            }
            self.registry.save(&record).await?;
            return Err(error);
        }
        record.phase = "ready".into();
        self.registry.save(&record).await?;
        Ok(self.connection(&record))
    }
    fn connection(&self, record: &Record) -> serde_json::Value {
        serde_json::json!({"url":format!("{}/workspaces/{}/session",self.base,record.id),"token":record.token,"project":record.project,"generation":record.generation})
    }
    async fn provision(
        &self,
        request: &Open,
        record: &mut Record,
        local: Option<PathBuf>,
        work: Arc<registry::Work>,
    ) -> Result<()> {
        record.project = None;
        record.identity = None;
        self.cleanup(&record).await?;
        let project = checkout::prepare(
            &self.config.state_root.join("checkout").join(&record.id),
            request,
            local,
            Some(work),
        )
        .await?;
        for name in ["build.hxml", "rayzor.toml", "haxelib.json"] {
            if tokio::fs::metadata(project.join(name))
                .await
                .is_ok_and(|meta| meta.is_file())
            {
                record.project = Some(name.into());
                break;
            }
        }
        let cpus = self.config.cpus.to_string();
        let memory = format!("{}M", self.config.memory_mib);
        let lifetime = format!("{}s", self.config.max_duration_seconds);
        let runner = format!("rayde.runner={}", self.registry.instance);
        let workspace = format!("rayde.workspace={}", record.id);
        let binary = format!(
            "{}:/opt/rayde-session",
            self.config.session_binary.display()
        );
        command::call(
            &self.config,
            [
                "create",
                &self.config.image,
                "--name",
                &record.sandbox,
                "--cpus",
                &cpus,
                "--memory",
                &memory,
                "--security",
                "restricted",
                "--deployment-profile",
                "multi-tenant",
                "--no-net",
                "--mount-owned",
                "/workspace",
                "--mount-owned",
                "/state",
                "--copy-file",
                &binary,
                "--label",
                &runner,
                "--label",
                &workspace,
                "--max-duration",
                &lifetime,
            ],
            30,
        )
        .await?;
        let destination = format!("{}:/workspace/project", record.sandbox);
        command::call(
            &self.config,
            [
                std::ffi::OsString::from("copy"),
                project.into_os_string(),
                destination.into(),
            ],
            30,
        )
        .await?;
        record.identity = Some(self.launch_session(record).await?);
        Ok(())
    }
}
