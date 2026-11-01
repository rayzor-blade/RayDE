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
use crate::msb::Msb;
use rayde_sandbox as sb;
use tokio::sync::{Semaphore, oneshot, watch};

/// What the service needs of a sandbox backend.
pub trait Backend: sb::SandboxProvider + 'static {}
impl<T: sb::SandboxProvider + 'static> Backend for T {}

struct Service<P: Backend> {
    config: Config,
    backend: Arc<P>,
    secret: String,
    registry: Registry,
    http: reqwest::Client,
    control: Arc<Semaphore>,
    base: String,
    halt: watch::Sender<bool>,
}
pub struct Running<P: Backend = Msb> {
    pub address: SocketAddr,
    service: Arc<Service<P>>,
    stop: Option<oneshot::Sender<()>>,
    done: tokio::task::JoinHandle<()>,
}
impl<P: Backend> Running<P> {
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
/// Starts the runner on MSB 0.7.11.
pub async fn start(config: Config) -> Result<Running> {
    config.validate()?;
    let backend = Arc::new(Msb::new(config.clone()));
    if backend.version().await? != "msb 0.7.11" {
        return Err(Failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "The runner requires the tested MSB version.",
        ));
    }
    start_with(config, backend).await
}

/// Starts the runner on any sandbox backend; tests use the in-memory one.
pub async fn start_with<P: Backend>(config: Config, backend: Arc<P>) -> Result<Running<P>> {
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
    let owned = backend.list(&sb::Labels::from([("rayde.runner".to_string(), registry.instance.clone())])).await?;
    let records = registry.records.lock().await;
    for item in owned {
        if !records.values().any(|cell| {
            cell.record
                .try_lock()
                .is_ok_and(|record| record.sandbox == item.name)
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
        backend,
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
        .route("/workspaces/open", post(open::<P>))
        .route("/workspaces/delete", post(delete::<P>))
        .route("/workspaces/:id/session", get(socket::<P>))
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
fn authenticate<P: Backend>(service: &Service<P>, headers: &HeaderMap) -> Result<()> {
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
async fn open<P: Backend>(
    State(service): State<Arc<Service<P>>>,
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
        || !binds(request.owner, &request.id, &request.repository)
        || !valid_publish(&request)
    {
        return Err(invalid());
    }
    if request.repository.sync.is_some() && service.config.sync_gateway.is_none() {
        return Err(unavailable());
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
async fn delete<P: Backend>(
    State(service): State<Arc<Service<P>>>,
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
    if let Some(storage) = &record.storage {storage.remove(service.backend.as_ref()).await?;}
    record.phase = "deleted".into();
    record.token = random();
    service.registry.save(&record).await?;
    cell.deactivate();
    let checkout = service.config.state_root.join("checkout").join(&record.id);
    let _ = tokio::fs::remove_dir_all(checkout).await;
    Ok(response(serde_json::json!({"deleted":true})))
}
async fn socket<P: Backend>(
    State(service): State<Arc<Service<P>>>,
    RoutePath(id): RoutePath<String>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Result<Response> {
    authenticate(&service, &headers)?;
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
    if tunnel::probe(service.backend.as_ref(), &record.sandbox, service.config.persistent_disks).await.ok().as_ref() != record.identity.as_ref() {
        return Err(Failure(StatusCode::SERVICE_UNAVAILABLE, "Workspace compute needs to reconnect."));
    }
    let backend = service.backend.clone();
    let relay_record = record.clone();
    let mut response = upgrade
        .max_message_size(rayde_session::session::MAX_MESSAGE)
        .max_frame_size(rayde_session::session::MAX_MESSAGE)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            tunnel::relay(socket, backend, cell, relay_record).await;
        })
        .into_response();
    response.headers_mut().insert("X-RayDE-Token", record.token.parse().map_err(|_| unavailable())?);
    response.headers_mut().insert("X-RayDE-Generation", record.generation.to_string().parse().map_err(|_| unavailable())?);
    Ok(response)
}
impl<P: Backend> Service<P> {
    /// The labels every sandbox of one workspace carries, and what finds them.
    fn workspace_labels(&self, id: &str) -> sb::Labels {
        sb::Labels::from([("rayde.runner".to_string(), self.registry.instance.clone()), ("rayde.workspace".to_string(), id.to_string())])
    }
    async fn cleanup(&self, record: &Record) -> Result<()> {
        let owned = self.backend.list(&self.workspace_labels(&record.id)).await?;
        let ours = owned.iter().any(|item| item.name == record.sandbox);
        let anywhere = self.backend.get(&record.sandbox).await?.is_some();
        if anywhere && !ours {
            return Err(Failure(
                StatusCode::CONFLICT,
                "Unverified sandbox needs reconciliation.",
            ));
        }
        if owned.is_empty() {
            return Ok(());
        }
        for item in &owned {
            if item.state != sb::State::Stopped && self.backend.ping(&item.name).await.is_err() {
                return Err(Failure(
                    StatusCode::CONFLICT,
                    "Sandbox runtime ownership needs reconciliation.",
                ));
            }
        }
        for item in &owned {
            self.backend.remove(&item.name).await?;
        }
        if !self.backend.list(&self.workspace_labels(&record.id)).await?.is_empty() || self.backend.get(&record.sandbox).await?.is_some() {
            return Err(unavailable());
        }
        Ok(())
    }
    /// `sync` is the gateway, workspace, capability and generation a restored session saves back with; it goes into the session's environment only.
    async fn launch_session(&self, record: &Record, sync: Option<(String, String, String, u64)>) -> Result<serde_json::Value> {
        let mut args = vec![
            "--root", "/workspace/project", "--state-root", "/state",
            "--host", "127.0.0.1", "--port", "7070", "--raw-port", "7071",
            "--token", tunnel::GUEST_TOKEN, "--exec",
        ];
        args.extend(toolchain::session_args(&self.config));
        let mut env = std::collections::BTreeMap::new();
        if let Some((gateway, workspace, token, generation)) = sync {
            env.extend([("RAYDE_SYNC_GATEWAY".into(), gateway), ("RAYDE_SYNC_WORKSPACE".into(), workspace), ("RAYDE_SYNC_TOKEN".into(), token), ("RAYDE_SYNC_GENERATION".into(), generation.to_string())]);
        }
        let command = sb::Command { program: "/opt/rayde-session".into(), args: args.into_iter().map(String::from).collect(), env };
        self.backend.detach(&record.sandbox, command).await?;
        for _ in 0..20 {
            if let Ok(identity) = tunnel::probe(self.backend.as_ref(), &record.sandbox, self.config.persistent_disks).await {
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
                    toolchain: toolchain::identity(&self.config),
                    recovery_attempts: Vec::new(),
                    storage: self.config.persistent_disks.then(|| volumes::Storage::new(&self.registry.instance, &request.id)),
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
        if record.phase != "deleted" && record.toolchain != toolchain::identity(&self.config) {
            return Err(Failure(StatusCode::CONFLICT, "This workspace needs a toolchain migration before reopening."));
        }
        if record.phase == "ready" {
            let identity = match tunnel::probe(self.backend.as_ref(), &record.sandbox, self.config.persistent_disks).await {
                Ok(identity) => Some(identity),
                Err(_) => {
                    if self.backend.ping(&record.sandbox).await.is_ok() {
                        self.launch_session(&record, None).await.ok()
                    } else {
                        None
                    }
                }
            };
            if identity.is_none() || identity != record.identity {
                if identity.is_none() && record.storage.is_some() {return self.recover(&cell, &mut record).await;}
                record.phase = "recovery-required".into();
                self.registry.save(&record).await?;
                return Err(Failure(StatusCode::CONFLICT, "The workspace needs recovery; its checkout will not be replaced."));
            }
            self.registry.save(&record).await?;
            return Ok(self.connection(&record));
        }
        if record.phase == "recovering" || record.phase == "recovery-required" && record.storage.is_some() && record.identity.is_some() {return self.recover(&cell, &mut record).await;}
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
            record.recovery_attempts.clear();
            record.toolchain = toolchain::identity(&self.config);
            record.storage = self.config.persistent_disks.then(|| volumes::Storage::new(&self.registry.instance, &record.id));
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
            let cleaned = if self.cleanup(&record).await.is_ok() {
                if let Some(storage) = &record.storage {storage.remove(self.backend.as_ref()).await.is_ok()} else {true}
            } else {false};
            if cleaned {
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
        serde_json::json!({"url":format!("{}/workspaces/{}/session",self.base,record.id),"token":record.token,"project":record.project,"generation":record.generation,"toolchain":record.toolchain,"recoverable":record.storage.is_some()})
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
        let root = self.config.state_root.join("checkout").join(&record.id);
        let (project, restored) = if request.repository.sync.is_some() {
            let (project, generation) = restore::restore(&self.config, &self.http, &root, request).await?;
            (project, Some(generation))
        } else {
            (checkout::prepare(&root, request, local, Some(work)).await?, None)
        };
        for name in ["build.hxml", "rayzor.toml", "haxelib.json"] {
            if tokio::fs::metadata(project.join(name))
                .await
                .is_ok_and(|meta| meta.is_file())
            {
                record.project = Some(name.into());
                break;
            }
        }
        self.boot(record, true).await?;
        self.backend.copy_in(&record.sandbox, project, "/workspace/project").await?;
        let grant = request.publish.as_ref().zip(restored).zip(self.config.sync_gateway.as_ref()).map(|((publish, generation), gateway)| (gateway.url.clone(), publish.workspace.clone(), publish.token.clone(), generation));
        record.identity = Some(self.launch_session(record, grant).await?);
        Ok(())
    }
    async fn boot(&self, record: &Record, initialize: bool) -> Result<()> {
        let labels = self.workspace_labels(&record.id);
        let mounts = match &record.storage {
            Some(storage) => {
                if initialize {
                    storage.prepare(self.backend.as_ref()).await?;
                }
                storage.mounts()
            }
            None => Vec::new(),
        };
        if self.config.toolchain.is_some() {
            toolchain::restore(self.backend.as_ref(), &self.config, &record.sandbox, labels, mounts).await?;
        } else {
            let mounts = if record.storage.is_some() {
                mounts
            } else {
                ["/workspace", "/state"].map(|destination| sb::Mount { source: sb::Source::Owned, destination: destination.into(), read_only: false }).to_vec()
            };
            self.backend
                .create(sb::SandboxSpec {
                    name: record.sandbox.clone(),
                    template: sb::Template::Image(self.config.image.clone()),
                    cpus: self.config.cpus as u32,
                    memory_mib: self.config.memory_mib,
                    security: sb::Security::Restricted,
                    network: sb::Network::None,
                    gpu: None,
                    labels,
                    mounts,
                    max_duration: Some(Duration::from_secs(self.config.max_duration_seconds)),
                })
                .await?;
        }
        self.backend.copy_in(&record.sandbox, self.config.session_binary.clone(), "/opt/rayde-session").await?;
        if let Some(storage) = &record.storage {storage.bind(self.backend.as_ref(), &record.sandbox, initialize).await?;}
        Ok(())
    }

    async fn recover(&self, cell: &Cell, record: &mut Record) -> Result<serde_json::Value> {
        if record.storage.is_none() || record.identity.is_none() {return Err(Failure(StatusCode::CONFLICT, "The workspace needs recovery; its checkout will not be replaced."));}
        let _work = self.registry.work(cell)?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| unavailable())?.as_secs();
        record.recovery_attempts.retain(|at| now.saturating_sub(*at) < 120);
        if record.recovery_attempts.len() >= 3 {return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "Wait before retrying workspace recovery."));}
        record.recovery_attempts.push(now);
        cell.closed.send_modify(|generation| *generation += 1);
        record.phase = "recovering".into();
        self.registry.save(record).await?;
        if let Err(error) = self.cleanup(record).await {
            record.phase = "recovery-required".into();
            self.registry.save(record).await?;
            return Err(error);
        }
        record.generation = record.generation.checked_add(1).ok_or_else(unavailable)?;
        record.token = random();
        record.sandbox = format!("rayde-{}-{}-{}", &self.registry.instance[..16], record.id, record.generation);
        self.registry.save(record).await?;
        let result = async {
            self.boot(record, false).await?;
            let identity = self.launch_session(record, None).await?;
            if Some(identity) != record.identity {return Err(Failure(StatusCode::CONFLICT, "The restored document-state identity does not match this workspace."));}
            Ok(())
        }.await;
        record.phase = if result.is_ok() {"ready"} else {"recovery-required"}.into();
        self.registry.save(record).await?;
        result?;
        Ok(self.connection(record))
    }

}
