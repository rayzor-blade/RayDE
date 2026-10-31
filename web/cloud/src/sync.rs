//! Cloud Sync's gateway: one Durable Object per synced workspace holds `SyncWorkspace` (the rules live in `rayde-sync`), chunks and generations live in private R2,
//! and a small per-account ledger gives the account total that quota is checked against. Every route runs for an authenticated account and is refused for
//! anyone else, so a workspace's existence is not revealed to another account.
use super::*;
use rayde_sync::{
    chunk::{MAX_CHUNK, sha256_hex},
    gateway::{LEASE_MS, SyncError, SyncWorkspace},
    ids::{AccountId, WorkspaceId},
    lifecycle::{Entitlement, Limits},
    manifest::{ChunkRef, Manifest},
};
use std::{collections::BTreeSet, time::Duration};

const MAX_MANIFEST: usize = 16 * 1024 * 1024;

fn prefix(workspace: &str) -> String {
    format!("sync/{workspace}/")
}

fn refusal(error: &SyncError) -> AppResult<Response> {
    let detail = match error {
        SyncError::BadChunk(hash) | SyncError::UndeclaredChunk(hash) | SyncError::ChunkMissing(hash) => json!({"chunk": hash}),
        SyncError::StaleGeneration { current } => json!({"current": current}),
        SyncError::ManifestInvalid(codes) => json!({"problems": codes}),
        SyncError::OverLimit(limit) => json!({"limit": format!("{limit:?}")}),
        _ => json!({}),
    };
    let mut body = detail;
    body["code"] = json!(error.code());
    body["message"] = json!(match error {
        SyncError::Expired => "This cloud copy has expired.",
        SyncError::TooManyUploads => "Too many uploads are in progress for this workspace.",
        SyncError::BadChunk(_) => "A chunk does not match what was declared.",
        SyncError::OverLimit(_) => "This would exceed the storage allowance.",
        SyncError::UnknownLease | SyncError::LeaseExpired => "That upload is no longer open. Begin again.",
        SyncError::AclChanged => "Access to this workspace changed. Begin again.",
        SyncError::StaleGeneration { .. } => "The cloud copy changed since this upload began.",
        SyncError::WrongWorkspace => "That snapshot belongs to another workspace.",
        SyncError::ManifestInvalid(_) => "The snapshot manifest is not valid.",
        SyncError::UndeclaredChunk(_) => "The snapshot names a chunk the upload did not declare.",
        SyncError::ChunkMissing(_) => "A chunk of the snapshot has not been uploaded.",
    });
    Ok(reply(&body, error.status())?)
}

fn status_body(id: &str, workspace: &SyncWorkspace, origin: &str) -> Value {
    json!({
        "id": id,
        "url": format!("{}/{}", origin.trim_end_matches('/'), id),
        "generation": workspace.generation,
        "allocation": workspace.allocation_bytes,
        "usage": {"referenced": workspace.usage.referenced_bytes, "reserved": workspace.usage.reserved_bytes},
        "expiresAt": workspace.expiry.expires_at,
        "firstPublished": workspace.expiry.first_published,
        "uploads": workspace.uploads.len(),
    })
}

// ---- the account the request is for ----

async fn owner_of(req: &Request, env: &Env) -> AppResult<String> {
    // A development account, only where the gateway runs locally: there is no GitHub App to sign in with on a laptop.
    if config(env, "LOCAL_DEV").as_deref() == Some("1") {
        if let Some(name) = req.headers().get("X-Dev-Account")? {
            let owner = format!("dev:{name}");
            AccountId::parse(&owner).map_err(|_| bad(400, "That development account name is not valid."))?;
            return Ok(owner);
        }
    }
    let (_, session) = auth(req, env).await?;
    if req.method() != Method::Get && req.headers().get("X-RayDE-CSRF")?.as_deref() != session["csrf"].as_str() {
        return Err(bad(403, "The request could not be verified."));
    }
    let owner = format!("github:{}", session["user"]["id"]);
    AccountId::parse(&owner).map_err(|_| bad(401, "Sign in to continue."))?;
    Ok(owner)
}

fn workspace_request(op: &str, owner: &str, method: Method, headers: &[(&str, &str)], body: Option<Vec<u8>>) -> AppResult<Request> {
    let h = Headers::new();
    h.set("X-Sync-Owner", owner)?;
    for (name, value) in headers {
        h.set(name, value)?;
    }
    let mut init = RequestInit::new();
    init.with_method(method).with_headers(h);
    if let Some(bytes) = body {
        init.with_body(Some(worker::js_sys::Uint8Array::from(bytes.as_slice()).into()));
    }
    Ok(Request::new_with_init(&format!("https://internal{op}"), &init)?)
}

async fn forward(env: &Env, id: &str, request: Request) -> AppResult<Response> {
    if !workspace_id(id) {
        return Err(bad(404, "No such synced workspace."));
    }
    let stub = env.durable_object("SYNC_WORKSPACES")?.get_by_name(id)?;
    Ok(stub.fetch_with_request(request).await?)
}

async fn limited(req: &mut Request, limit: usize) -> AppResult<Vec<u8>> {
    if req.headers().get("Content-Length")?.and_then(|v| v.parse::<usize>().ok()).is_some_and(|n| n > limit) {
        return Err(bad(413, "The request is too large."));
    }
    let bytes = req.bytes().await?;
    if bytes.len() > limit {
        return Err(bad(413, "The request is too large."));
    }
    Ok(bytes)
}

/// The id a browser session gives the same account: a GitHub user's own id, and for a development account a number made from its name.
fn browser_owner(owner: &str) -> Value {
    match owner.split_once(':') {
        Some(("github", id)) => id.parse::<u64>().map(Value::from).unwrap_or(Value::Null),
        Some(("dev", name)) => json!(dev_user_id(name)),
        _ => Value::Null,
    }
}

pub(crate) fn dev_user_id(name: &str) -> u64 {
    // FNV-1a, kept above the range of real GitHub ids' low values so a development account never collides with a small id.
    name.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3)) % 1_000_000_000 + 2_000_000_000
}

/// What the compute that restores a snapshot may read: the manifest and chunks of a workspace, with the runner's secret and no account.
async fn runner_route(req: &Request, env: &Env, parts: &[&str]) -> AppResult<Response> {
    let secret = config(env, "RUNNER_SECRET").ok_or_else(|| bad(503, "Workspace compute is not configured."))?;
    if req.headers().get("Authorization")?.as_deref() != Some(&format!("Bearer {secret}")) {
        return Err(bad(403, "The request could not be verified."));
    }
    match parts {
        [id, "manifest"] => forward(env, id, workspace_request("/manifest", RUNNER, Method::Get, &[], None)?).await,
        [id, "chunks", hash] => forward(env, id, workspace_request("/chunk-read", RUNNER, Method::Get, &[("X-Sync-Hash", hash)], None)?).await,
        _ => Err(bad(404, "There is no such sync route.")),
    }
}

const RUNNER: &str = "@runner";

/// `/api/sync/...` for an authenticated account.
pub(crate) async fn route(req: &mut Request, env: &Env, rest: &str) -> AppResult<Response> {
    if let Some(runner) = rest.trim_matches('/').strip_prefix("runner/") {
        let parts: Vec<&str> = runner.split('/').collect();
        return runner_route(req, env, &parts).await;
    }
    let owner = owner_of(req, env).await?;
    let method = req.method();
    let parts: Vec<&str> = rest.trim_matches('/').split('/').collect();
    let origin = config(env, "APP_ORIGIN").unwrap_or_default();
    match (method, parts.as_slice()) {
        (Method::Post, ["workspaces"]) => {
            let body: Value = req.json().await.unwrap_or(json!({}));
            let mut random = [0u8; 32];
            getrandom::getrandom(&mut random).map_err(|_| bad(500, "A workspace could not be created."))?;
            let id = WorkspaceId::from_random(&random);
            let data = json!({"id": id.as_str(), "allocation": body["allocation"], "durationMs": body["durationMs"], "origin": origin});
            let request = workspace_request("/create", &owner, Method::Post, &[("Content-Type", "application/json")], Some(data.to_string().into_bytes()))?;
            forward(env, id.as_str(), request).await
        }
        (Method::Get, ["workspaces", id]) => forward(env, id, workspace_request(&format!("/status?origin={}", urlencode(&origin)), &owner, Method::Get, &[], None)?).await,
        (Method::Post, ["workspaces", id, "open"]) => {
            let status = forward(env, id, workspace_request(&format!("/status?origin={}", urlencode(&origin)), &owner, Method::Get, &[], None)?).await?;
            let mut status = status;
            let body: Value = status.json().await?;
            if status.status_code() >= 400 {
                return Ok(reply(&body, status.status_code())?);
            }
            let generation = body["generation"].as_u64().unwrap_or(0);
            if generation == 0 {
                return Err(bad(409, "Nothing has been published yet."));
            }
            let owner_id = browser_owner(&owner);
            if owner_id.is_null() {
                return Err(bad(400, "This account cannot open a browser workspace."));
            }
            let repository = json!({"id": 0, "name": "synced", "full_name": format!("sync/{id}"), "private": true, "sync": {"workspace": id, "generation": generation, "opened": now()}});
            rpc(env, "WORKSPACES", id, "open", &json!({"id": id, "owner": owner_id, "repository": repository, "access": Value::Null})).await?;
            Ok(reply(&json!({"id": id, "url": body["url"], "generation": generation}), 200)?)
        }
        (Method::Post, ["workspaces", id, "uploads"]) => {
            let bytes = limited(req, 4 * 1024 * 1024).await?;
            forward(env, id, workspace_request("/begin", &owner, Method::Post, &[("Content-Type", "application/json")], Some(bytes))?).await
        }
        (Method::Get, ["workspaces", id, "uploads", lease]) => forward(env, id, workspace_request("/pending", &owner, Method::Get, &[("X-Sync-Lease", lease)], None)?).await,
        (Method::Put, ["workspaces", id, "uploads", lease, "chunks", hash]) => {
            let bytes = limited(req, MAX_CHUNK).await?;
            forward(env, id, workspace_request("/chunk", &owner, Method::Put, &[("X-Sync-Lease", lease), ("X-Sync-Hash", hash)], Some(bytes))?).await
        }
        (Method::Post, ["workspaces", id, "uploads", lease, "publish"]) => {
            let bytes = limited(req, MAX_MANIFEST).await?;
            let path = format!("/publish?origin={}", urlencode(&origin));
            forward(env, id, workspace_request(&path, &owner, Method::Post, &[("X-Sync-Lease", lease)], Some(bytes))?).await
        }
        (Method::Delete, ["workspaces", id, "uploads", lease]) => forward(env, id, workspace_request("/cancel", &owner, Method::Post, &[("X-Sync-Lease", lease)], None)?).await,
        (Method::Get, ["workspaces", id, "export", "manifest"]) => forward(env, id, workspace_request("/manifest", &owner, Method::Get, &[], None)?).await,
        (Method::Get, ["workspaces", id, "export", "chunks", hash]) => forward(env, id, workspace_request("/chunk-read", &owner, Method::Get, &[("X-Sync-Hash", hash)], None)?).await,
        _ => Err(bad(404, "There is no such sync route.")),
    }
}

fn urlencode(value: &str) -> String {
    value.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

// ---- the workspace ----

#[durable_object]
pub struct SyncWorkspaceSession {
    state: State,
    env: Env,
    gate: futures_util::lock::Mutex<()>,
}

impl DurableObject for SyncWorkspaceSession {
    fn new(state: State, env: Env) -> Self {
        Self { state, env, gate: futures_util::lock::Mutex::new(()) }
    }
    async fn fetch(&self, req: Request) -> Result<Response> {
        let _guard = self.gate.lock().await;
        finish(self.handle(req).await)
    }
    /// Abandons the uploads that sat past their lease, returns their reservations and deletes what they stored.
    async fn alarm(&self) -> Result<Response> {
        let _guard = self.gate.lock().await;
        let storage = self.state.storage();
        if let Some(mut workspace) = storage.get::<SyncWorkspace>("ws").await? {
            let garbage = workspace.sweep(now());
            storage.put("ws", &workspace).await?;
            self.delete_chunks(workspace.id.as_str(), &garbage).await;
            self.report(&workspace).await;
            let _ = self.schedule(&workspace).await;
        }
        Response::empty()
    }
}

impl SyncWorkspaceSession {
    fn bucket(&self) -> AppResult<Bucket> {
        self.env.bucket("WORKSPACE_FILES").map_err(|_| bad(503, "Cloud Sync storage is not configured."))
    }

    async fn schedule(&self, workspace: &SyncWorkspace) -> AppResult<()> {
        if let Some(first) = workspace.uploads.values().map(|u| u.started_at).min() {
            let due = (first + LEASE_MS + 1_000).saturating_sub(now()).max(1_000);
            self.state.storage().set_alarm(Duration::from_millis(due)).await?;
        }
        Ok(())
    }

    /// What the account's other workspaces hold, for the account quota. Best effort: a ledger that cannot be reached counts as nothing here, not as a refusal.
    async fn others(&self, owner: &str, workspace: &str) -> u64 {
        rpc(&self.env, "SYNC_ACCOUNTS", owner, "others", &json!({"workspace": workspace})).await.ok().and_then(|v| v["bytes"].as_u64()).unwrap_or(0)
    }

    async fn report(&self, workspace: &SyncWorkspace) {
        let _ = rpc(&self.env, "SYNC_ACCOUNTS", workspace.owner.as_str(), "set", &json!({"workspace": workspace.id.as_str(), "bytes": workspace.usage.total()})).await;
    }

    async fn delete_chunks(&self, workspace: &str, hashes: &[String]) {
        if let Ok(bucket) = self.bucket() {
            for hash in hashes {
                let _ = bucket.delete(format!("{}chunks/{hash}", prefix(workspace))).await;
            }
        }
    }

    async fn handle(&self, mut req: Request) -> AppResult<Response> {
        let op = req.path();
        let owner = req.headers().get("X-Sync-Owner")?.ok_or_else(|| bad(401, "Sign in to continue."))?;
        let lease = req.headers().get("X-Sync-Lease")?.unwrap_or_default();
        let url = req.url()?;
        let origin = url.query_pairs().find(|(k, _)| k == "origin").map(|(_, v)| v.into_owned()).unwrap_or_default();
        let storage = self.state.storage();
        let stored = storage.get::<SyncWorkspace>("ws").await?;
        let plan = Entitlement::free();

        if op == "/create" {
            let data: Value = req.json().await?;
            let origin = data["origin"].as_str().unwrap_or_default().to_string();
            if let Some(existing) = stored {
                if existing.owner.as_str() != owner {
                    return Err(bad(404, "No such synced workspace."));
                }
                return Ok(reply(&status_body(existing.id.as_str(), &existing, &origin), 200)?);
            }
            let id = WorkspaceId::parse(text(&data, "id")?).map_err(|_| bad(400, "The workspace id is not valid."))?;
            let owner_id = AccountId::parse(&owner).map_err(|_| bad(401, "Sign in to continue."))?;
            let workspace = SyncWorkspace::create(id.clone(), owner_id, &plan, data["allocation"].as_u64().unwrap_or(plan.max_allocation_bytes), data["durationMs"].as_u64().unwrap_or(plan.max_expiry_ms));
            storage.put("ws", &workspace).await?;
            self.report(&workspace).await;
            return Ok(reply(&status_body(id.as_str(), &workspace, &origin), 201)?);
        }

        // Anything else is for the owner of an existing workspace; to anyone else it does not exist.
        let reads_only = owner == RUNNER && matches!(op.as_str(), "/manifest" | "/chunk-read");
        let mut workspace = stored.filter(|w| reads_only || w.owner.as_str() == owner).ok_or_else(|| bad(404, "No such synced workspace."))?;
        let id = workspace.id.as_str().to_string();
        match op.as_str() {
            "/status" => Ok(reply(&status_body(&id, &workspace, &origin), 200)?),
            "/begin" => {
                let data: Value = req.json().await?;
                let chunks: Vec<ChunkRef> = serde_json::from_value(data["chunks"].clone()).map_err(|_| bad(400, "The chunk list is not valid."))?;
                let others = self.others(&owner, &id).await;
                let lease = random()?;
                match workspace.begin(now(), &plan, others, &chunks, &lease) {
                    Ok(info) => {
                        storage.put("ws", &workspace).await?;
                        self.report(&workspace).await;
                        self.schedule(&workspace).await?;
                        Ok(reply(&json!({"lease": lease, "baseGeneration": info.base_generation, "aclVersion": info.acl_version, "missing": info.missing, "reserved": info.reserved}), 200)?)
                    }
                    Err(error) => {
                        // `begin` sweeps stale uploads before it refuses; keep what it released.
                        storage.put("ws", &workspace).await?;
                        refusal(&error)
                    }
                }
            }
            "/pending" => match workspace.pending(now(), &lease) {
                Ok(missing) => {
                    storage.put("ws", &workspace).await?;
                    Ok(reply(&json!({"missing": missing}), 200)?)
                }
                Err(error) => {
                    storage.put("ws", &workspace).await?;
                    refusal(&error)
                }
            },
            "/chunk" => {
                let hash = req.headers().get("X-Sync-Hash")?.unwrap_or_default();
                let bytes = req.bytes().await?;
                if bytes.len() > MAX_CHUNK || sha256_hex(&bytes) != hash {
                    return refusal(&SyncError::BadChunk(hash));
                }
                // The lease and the declared size are checked before anything is stored, on a copy: nothing is recorded until the bytes are durable.
                let mut probe = workspace.clone();
                if let Err(error) = probe.record_chunk(now(), &lease, &hash, bytes.len() as u32) {
                    storage.put("ws", &probe).await?;
                    return refusal(&error);
                }
                self.bucket()?.put(format!("{}chunks/{hash}", prefix(&id)), bytes).execute().await?;
                storage.put("ws", &probe).await?;
                Ok(reply(&json!({"stored": hash}), 200)?)
            }
            "/publish" => {
                let bytes = req.bytes().await?;
                let manifest = match Manifest::from_bytes(&bytes) {
                    Ok(manifest) => manifest,
                    Err(_) => return refusal(&SyncError::ManifestInvalid(vec!["unreadable".into()])),
                };
                let bucket = self.bucket()?;
                let mut present = BTreeSet::new();
                for hash in manifest.chunk_set().keys().filter(|h| !workspace.held.contains_key(*h)) {
                    if bucket.head(format!("{}chunks/{hash}", prefix(&id))).await?.is_some() {
                        present.insert(hash.clone());
                    }
                }
                let mut next = workspace.clone();
                let limits = Limits::for_allocation(workspace.allocation_bytes);
                match next.publish(now(), &lease, &manifest, &limits, &|h| present.contains(h)) {
                    Ok(done) => {
                        // The manifest is stored before the generation advances, so a failure here leaves the last valid generation as it was.
                        bucket.put(format!("{}generations/{:012}.json", prefix(&id), done.generation), manifest.to_bytes()).execute().await?;
                        storage.put("ws", &next).await?;
                        self.delete_chunks(&id, &done.garbage).await;
                        self.report(&next).await;
                        let mut body = status_body(&id, &next, &origin);
                        body["stored"] = json!(done.stored_bytes);
                        Ok(reply(&body, 200)?)
                    }
                    Err(error) => {
                        // A lease found void or stale is dropped by the attempt; anything else leaves the workspace as it was.
                        if matches!(error, SyncError::LeaseExpired | SyncError::AclChanged | SyncError::UnknownLease) {
                            storage.put("ws", &next).await?;
                        }
                        refusal(&error)
                    }
                }
            }
            "/cancel" => match workspace.cancel(&lease) {
                Ok(garbage) => {
                    storage.put("ws", &workspace).await?;
                    self.delete_chunks(&id, &garbage).await;
                    self.report(&workspace).await;
                    Ok(reply(&json!({"cancelled": true}), 200)?)
                }
                Err(error) => refusal(&error),
            },
            "/manifest" => {
                if workspace.generation == 0 {
                    return Err(bad(404, "Nothing has been published yet."));
                }
                let object = self.bucket()?.get(format!("{}generations/{:012}.json", prefix(&id), workspace.generation)).execute().await?.ok_or_else(|| bad(404, "The snapshot is not available."))?;
                let bytes = object.body().ok_or_else(|| bad(404, "The snapshot is not available."))?.bytes().await?;
                let mut response = Response::from_bytes(bytes)?;
                response.headers_mut().set("Content-Type", "application/json")?;
                response.headers_mut().set("Cache-Control", "no-store")?;
                Ok(response)
            }
            "/chunk-read" => {
                let hash = req.headers().get("X-Sync-Hash")?.unwrap_or_default();
                if !workspace.held.contains_key(&hash) {
                    return Err(bad(404, "No such chunk in this workspace."));
                }
                let object = self.bucket()?.get(format!("{}chunks/{hash}", prefix(&id))).execute().await?.ok_or_else(|| bad(404, "The chunk is not available."))?;
                let bytes = object.body().ok_or_else(|| bad(404, "The chunk is not available."))?.bytes().await?;
                let mut response = Response::from_bytes(bytes)?;
                response.headers_mut().set("Content-Type", "application/octet-stream")?;
                response.headers_mut().set("Cache-Control", "no-store")?;
                Ok(response)
            }
            _ => Err(bad(404, "There is no such sync operation.")),
        }
    }
}

// ---- the account's total ----

#[durable_object]
pub struct SyncAccountLedger {
    state: State,
}

impl DurableObject for SyncAccountLedger {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }
    async fn fetch(&self, mut req: Request) -> Result<Response> {
        let op = req.path();
        let data: Value = req.json().await?;
        let storage = self.state.storage();
        let mut held: std::collections::BTreeMap<String, u64> = storage.get("usage").await?.unwrap_or_default();
        let workspace = data["workspace"].as_str().unwrap_or_default().to_string();
        match op.as_str() {
            "/set" => {
                held.insert(workspace, data["bytes"].as_u64().unwrap_or(0));
                storage.put("usage", &held).await?;
                reply(&json!({}), 200)
            }
            _ => reply(&json!({"bytes": held.iter().filter(|(id, _)| **id != workspace).map(|(_, bytes)| *bytes).sum::<u64>()}), 200),
        }
    }
}
