//! The desktop side of an upload: scans a folder, sends the chunks the gateway lacks and publishes. A `Push` runs on its own thread and reports
//! progress as JSON events that the caller polls, so a UI never waits on the network.
use crate::{
    chunk::{MAX_CHUNK, sha256_hex},
    exclude::Selection,
    ids::WorkspaceId,
    lifecycle::{DEFAULT_ALLOCATION_BYTES, Limits},
    manifest::{ChunkRef, FileEntry, FileKind, Manifest},
    merge::{self, Action, Entry, MAX_TEXT, Side},
    scan::{Options, Snapshot, scan, scan_tree},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, VecDeque},
    fs,
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Deserialize)]
pub struct Config {
    pub root: PathBuf,
    pub gateway: String,
    /// A development account, honoured only by a gateway running locally.
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub device: Option<String>,
    #[serde(default)]
    pub history: bool,
    /// "push" (the default), "open", "pull" or "writeback".
    #[serde(default)]
    pub action: String,
    /// Publish over a cloud copy that has moved on since this folder last synced. Nothing merges the two yet, so this replaces the other device's changes.
    #[serde(default)]
    pub force: bool,
    /// For `pull` and for a session's merge: which side wins a file both sides edited in the same place, `mine` or `theirs`, by path.
    #[serde(default)]
    pub choices: BTreeMap<String, String>,
    /// Write-back publishes into this existing workspace, as the holder of `token`, against the generation the tree was restored from.
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub base_generation: Option<u64>,
}

#[derive(Debug)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

impl Failure {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Failure { code: code.into(), message: message.into() }
    }
}

struct Gateway {
    base: String,
    account: Option<String>,
    token: Option<String>,
    agent: ureq::Agent,
}

impl Gateway {
    fn call(&self, method: &str, path: &str, body: Option<&[u8]>) -> Result<Vec<u8>, Failure> {
        let mut request = self.agent.request(method, &format!("{}/api/sync{path}", self.base));
        if let Some(account) = &self.account {
            request = request.set("X-Dev-Account", account);
        }
        if let Some(token) = &self.token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
        let response = match body {
            Some(bytes) => request.set("Content-Type", "application/octet-stream").send_bytes(bytes),
            None => request.call(),
        };
        match response {
            Ok(response) => {
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(&mut response.into_reader(), &mut bytes).map_err(|e| Failure::new("network", e.to_string()))?;
                Ok(bytes)
            }
            Err(ureq::Error::Status(_, response)) => {
                let body: Value = response.into_json().unwrap_or(json!({}));
                Err(Failure::new(body["code"].as_str().unwrap_or("refused"), body["message"].as_str().unwrap_or("The gateway refused the request.")))
            }
            Err(error) => Err(Failure::new("network", format!("The gateway could not be reached: {error}"))),
        }
    }

    fn json(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value, Failure> {
        let bytes = body.map(|v| v.to_string().into_bytes());
        serde_json::from_slice(&self.call(method, path, bytes.as_deref())?).map_err(|_| Failure::new("protocol", "The gateway's answer was not understood."))
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn strings(value: &Value) -> Vec<String> {
    value.as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default()
}

fn gateway_of(config: &Config) -> Gateway {
    Gateway {
        base: config.gateway.trim_end_matches('/').to_string(),
        account: config.account.clone(),
        token: config.token.clone(),
        agent: ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(10)).timeout(Duration::from_secs(300)).build(),
    }
}

/// The folder remembers its workspace per gateway, inside `.git`, which is never uploaded. Returns the file and what it held.
fn remembered(config: &Config) -> Result<(PathBuf, Value), Failure> {
    let git_dir = std::process::Command::new("git").arg("-C").arg(&config.root).args(["rev-parse", "--absolute-git-dir"]).output().map_err(|e| Failure::new("git", e.to_string()))?;
    if !git_dir.status.success() {
        return Err(Failure::new("not-a-repository", "This folder is not a Git repository."));
    }
    let path = PathBuf::from(String::from_utf8_lossy(&git_dir.stdout).trim()).join("rayde-sync.json");
    let held = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(json!({}));
    Ok((path, held))
}

/// Runs the job the config names, reporting through `emit`. `cancelled` is asked between chunks of an upload.
pub fn run(config: &Config, emit: &mut dyn FnMut(Value), cancelled: &dyn Fn() -> bool) -> Result<(), Failure> {
    match config.action.as_str() {
        "" | "push" => push(config, emit, cancelled),
        "open" => open(config, emit),
        "writeback" => writeback(config, emit, cancelled),
        "pull" => pull(config, emit),
        other => Err(Failure::new("usage", format!("unknown action {other}"))),
    }
}

/// Asks the gateway to start a browser session on the folder's published copy, and reports its link.
fn open(config: &Config, emit: &mut dyn FnMut(Value)) -> Result<(), Failure> {
    let gateway = gateway_of(config);
    let (_, held) = remembered(config)?;
    let id = held[&gateway.base]["workspace"].as_str().ok_or_else(|| Failure::new("not-synced", "This folder has not been synced to this gateway."))?.to_string();
    let opened = gateway.json("POST", &format!("/workspaces/{id}/open"), None)?;
    emit(json!({"event": "opened", "id": id, "url": opened["url"], "generation": opened["generation"]}));
    Ok(())
}

/// Runs one upload to completion. A cancelled upload is dropped at the gateway.
fn push(config: &Config, emit: &mut dyn FnMut(Value), cancelled: &dyn Fn() -> bool) -> Result<(), Failure> {
    let gateway = gateway_of(config);
    let (state_path, remembered) = remembered(config)?;
    let key = gateway.base.clone();

    // The generation this folder last synced, when it is still talking to the workspace it synced.
    let mut known = None;
    let status = match remembered[&key]["workspace"].as_str() {
        Some(id) => match gateway.json("GET", &format!("/workspaces/{id}"), None) {
            Ok(status) => {
                known = remembered[&key]["generation"].as_u64();
                status
            }
            Err(failure) if failure.message.contains("No such") => gateway.json("POST", "/workspaces", Some(&json!({})))?,
            Err(failure) => return Err(failure),
        },
        None => gateway.json("POST", "/workspaces", Some(&json!({})))?,
    };
    let id = status["id"].as_str().ok_or_else(|| Failure::new("protocol", "The gateway did not name a workspace."))?.to_string();
    let current = status["generation"].as_u64().unwrap_or(0);
    if let Some(known) = known.filter(|known| *known != current && !config.force) {
        return Err(Failure::new("conflict", format!("The cloud copy is at generation {current}, but this folder last synced generation {known}: another device has saved since, and syncing now would replace those changes. Nothing was sent.")));
    }
    let mut saved = remembered.clone();
    saved[&key] = json!({"workspace": id, "generation": known});
    let _ = fs::write(&state_path, saved.to_string());
    emit(json!({"event": "workspace", "id": id, "url": status["url"]}));

    let snapshot = scan(
        &config.root,
        &Options {
            workspace: WorkspaceId::parse(&id).map_err(|_| Failure::new("protocol", "The gateway's workspace id is not valid."))?,
            base_generation: status["generation"].as_u64().unwrap_or(0),
            device: config.device.clone().unwrap_or_else(|| "this computer".into()),
            now_ms: now_ms(),
            limits: Limits::for_allocation(status["allocation"].as_u64().unwrap_or(DEFAULT_ALLOCATION_BYTES)),
            selection: Selection::default(),
            history: config.history,
            buffers: vec![],
        },
    )
    .map_err(|e| Failure::new("scan", e.to_string()))?;
    let generation = upload(&gateway, &id, &snapshot, emit, cancelled)?;
    // The folder now stands at what it published, so the next sync can tell when another device has saved after it, and a pull has the version to merge from.
    saved[&key] = json!({"workspace": id, "generation": generation});
    let _ = fs::write(&state_path, saved.to_string());
    if let Ok(base) = base_from(&snapshot) {
        let _ = store_base(&base_dir(&state_path, &id), &base);
    }
    Ok(())
}

/// Sends the chunks the gateway lacks and publishes the snapshot's manifest, dropping the upload if anything fails.
fn upload(gateway: &Gateway, id: &str, snapshot: &Snapshot, emit: &mut dyn FnMut(Value), cancelled: &dyn Fn() -> bool) -> Result<u64, Failure> {
    let declared: Vec<ChunkRef> = snapshot.chunks().map(|(hash, size)| ChunkRef { hash: hash.to_string(), size }).collect();
    emit(json!({"event": "scanned", "files": snapshot.manifest.files.len(), "bytes": snapshot.manifest.totals.bytes, "chunks": declared.len(), "omitted": snapshot.manifest.omissions.len()}));

    let begun = gateway.json("POST", &format!("/workspaces/{id}/uploads"), Some(&json!({"chunks": declared})))?;
    let lease = begun["lease"].as_str().ok_or_else(|| Failure::new("protocol", "The gateway did not open an upload."))?.to_string();
    let result = (|| {
        let mut missing = strings(&begun["missing"]);
        let total = missing.len();
        let bytes_total: u64 = declared.iter().filter(|c| missing.contains(&c.hash)).map(|c| c.size as u64).sum();
        let (mut sent, mut bytes_sent, mut retried) = (0usize, 0u64, false);
        while let Some(hash) = missing.pop() {
            if cancelled() {
                return Err(Failure::new("cancelled", "The upload was cancelled."));
            }
            let bytes = snapshot.read_chunk(&hash).map_err(|e| Failure::new("changed", format!("A file changed while it was being uploaded: {e}")))?;
            debug_assert!(bytes.len() <= MAX_CHUNK);
            match gateway.call("PUT", &format!("/workspaces/{id}/uploads/{lease}/chunks/{hash}"), Some(&bytes)) {
                Ok(_) => {
                    sent += 1;
                    bytes_sent += bytes.len() as u64;
                    emit(json!({"event": "upload", "sent": sent, "total": total, "bytes": bytes_sent, "bytesTotal": bytes_total}));
                }
                // One dropped connection is asked about, so only what the gateway lacks is sent again.
                Err(failure) if failure.code == "network" && !retried => {
                    retried = true;
                    missing = strings(&gateway.json("GET", &format!("/workspaces/{id}/uploads/{lease}"), None)?["missing"]);
                }
                Err(failure) => return Err(failure),
            }
        }
        let published = gateway.call("POST", &format!("/workspaces/{id}/uploads/{lease}/publish"), Some(&snapshot.manifest.to_bytes()))?;
        serde_json::from_slice::<Value>(&published).map_err(|_| Failure::new("protocol", "The gateway's answer was not understood."))
    })();
    match result {
        Ok(done) => {
            emit(json!({"event": "published", "id": id, "url": done["url"], "generation": done["generation"], "expiresAt": done["expiresAt"], "stored": done["stored"]}));
            Ok(done["generation"].as_u64().unwrap_or(0))
        }
        Err(failure) => {
            let _ = gateway.call("DELETE", &format!("/workspaces/{id}/uploads/{lease}"), None);
            Err(failure)
        }
    }
}

/// What a restored tree is a copy of: the cloud manifest of its generation, and the text of its small files, kept so that a merge later has the version
/// both sides started from. The cloud forgets a generation's chunks once it moves on, so this is the only place that version survives.
#[derive(Clone)]
pub struct Base {
    pub manifest: Manifest,
    pub texts: BTreeMap<String, Vec<u8>>,
}

impl Base {
    pub fn generation(&self) -> u64 {
        self.manifest.generation
    }
}

/// What a merge did, or found it could not decide.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct MergeReport {
    pub generation: u64,
    pub written: Vec<String>,
    pub deleted: Vec<String>,
    pub conflicts: Vec<(String, String)>,
}

const MAX_BASE_BYTES: u64 = 32 * 1024 * 1024;

fn mergeable(file: &FileEntry) -> bool {
    matches!(file.kind, FileKind::Regular | FileKind::Executable)
}

/// The text of the small files in `manifest` that are on disk under `root` exactly as the manifest says.
fn read_texts(root: &Path, manifest: &Manifest) -> BTreeMap<String, Vec<u8>> {
    let (mut texts, mut total) = (BTreeMap::new(), 0u64);
    for file in manifest.files.iter().filter(|file| mergeable(file) && file.size as usize <= MAX_TEXT) {
        if total + file.size > MAX_BASE_BYTES {
            break;
        }
        if let Ok(bytes) = fs::read(root.join(&file.path)) {
            if sha256_hex(&bytes) == file.hash {
                total += file.size;
                texts.insert(file.path.clone(), bytes);
            }
        }
    }
    texts
}

fn existing_workspace(config: &Config) -> Result<(Gateway, String), Failure> {
    let id = config.workspace.clone().ok_or_else(|| Failure::new("usage", "This needs the workspace the tree came from."))?;
    Ok((gateway_of(config), id))
}

fn cloud_manifest(gateway: &Gateway, id: &str) -> Result<Manifest, Failure> {
    Manifest::from_bytes(&gateway.call("GET", &format!("/workspaces/{id}/export/manifest"), None)?).map_err(|_| Failure::new("protocol", "The gateway's manifest was not understood."))
}

/// Records what the tree at `config.root` is a copy of. Call it as soon as the tree is restored, before anything edits it.
pub fn capture(config: &Config) -> Result<Base, Failure> {
    let (gateway, id) = existing_workspace(config)?;
    let manifest = cloud_manifest(&gateway, &id)?;
    if config.base_generation.is_some_and(|expected| expected != manifest.generation) {
        return Err(Failure::new("conflict", format!("The cloud copy is at generation {}, not the one this workspace was restored from.", manifest.generation)));
    }
    let texts = read_texts(&config.root, &manifest);
    Ok(Base { manifest, texts })
}

/// Publishes a restored tree, which has no Git directory, into the workspace it came from, as the next generation after `base`. Refuses when the cloud
/// copy has moved on, so nothing is overwritten; the gateway's compare-and-swap catches a push that lands in between. Returns what the tree now is a copy of.
pub fn save(config: &Config, base: &Base, emit: &mut dyn FnMut(Value), cancelled: &dyn Fn() -> bool) -> Result<Base, Failure> {
    let (gateway, id) = existing_workspace(config)?;
    let status = gateway.json("GET", &format!("/workspaces/{id}"), None)?;
    let current = status["generation"].as_u64().unwrap_or(0);
    if current != base.generation() {
        return Err(Failure::new("conflict", format!("The cloud copy is at generation {current} and this workspace is based on generation {}; nothing was saved.", base.generation())));
    }
    emit(json!({"event": "workspace", "id": id, "url": status["url"]}));
    let snapshot = scan_tree(
        &config.root,
        &base.manifest,
        &Options {
            workspace: WorkspaceId::parse(&id).map_err(|_| Failure::new("protocol", "The workspace id is not valid."))?,
            base_generation: base.generation(),
            device: config.device.clone().unwrap_or_else(|| "browser session".into()),
            now_ms: now_ms(),
            limits: Limits::for_allocation(status["allocation"].as_u64().unwrap_or(DEFAULT_ALLOCATION_BYTES)),
            selection: Selection::default(),
            history: false,
            buffers: vec![],
        },
    )
    .map_err(|e| Failure::new("scan", e.to_string()))?;
    upload(&gateway, &id, &snapshot, emit, cancelled)?;
    base_from(&snapshot)
}

/// What a published snapshot is a copy of: its manifest and the text of its small files, read back from where the scan found them.
fn base_from(snapshot: &Snapshot) -> Result<Base, Failure> {
    let (mut texts, mut total) = (BTreeMap::new(), 0u64);
    for file in snapshot.manifest.files.iter().filter(|file| mergeable(file) && file.size as usize <= MAX_TEXT) {
        let mut bytes = Vec::with_capacity(file.size as usize);
        for chunk in &file.chunks {
            bytes.extend(snapshot.read_chunk(&chunk.hash).map_err(|e| Failure::new("changed", e.to_string()))?);
        }
        if total + file.size <= MAX_BASE_BYTES && sha256_hex(&bytes) == file.hash {
            total += file.size;
            texts.insert(file.path.clone(), bytes);
        }
    }
    Ok(Base { manifest: snapshot.manifest.clone(), texts })
}

/// Where a folder keeps what it last synced: inside `.git`, which is never uploaded.
fn base_dir(state_path: &Path, workspace: &str) -> PathBuf {
    state_path.parent().unwrap_or(Path::new(".")).join("rayde-sync-base").join(workspace)
}

/// Keeps `base` on disk: the manifest, an index of the text files, and their content named by hash so an unchanged file is written once.
fn store_base(dir: &Path, base: &Base) -> std::io::Result<()> {
    fs::create_dir_all(dir.join("blobs"))?;
    let mut index = serde_json::Map::new();
    for (path, bytes) in &base.texts {
        let hash = sha256_hex(bytes);
        let blob = dir.join("blobs").join(&hash);
        if !blob.exists() {
            fs::write(&blob, bytes)?;
        }
        index.insert(path.clone(), json!(hash));
    }
    for entry in fs::read_dir(dir.join("blobs"))?.flatten() {
        if !index.values().any(|hash| hash.as_str().is_some_and(|hash| entry.file_name() == hash)) {
            let _ = fs::remove_file(entry.path());
        }
    }
    fs::write(dir.join("texts.json"), Value::Object(index).to_string())?;
    fs::write(dir.join("manifest.json"), base.manifest.to_bytes())
}

fn load_base(dir: &Path) -> Option<Base> {
    let manifest = Manifest::from_bytes(&fs::read(dir.join("manifest.json")).ok()?).ok()?;
    let index: Value = serde_json::from_slice(&fs::read(dir.join("texts.json")).ok()?).ok()?;
    let mut texts = BTreeMap::new();
    for (path, hash) in index.as_object()? {
        let hash = hash.as_str()?;
        let bytes = fs::read(dir.join("blobs").join(hash)).ok()?;
        if sha256_hex(&bytes) == hash {
            texts.insert(path.clone(), bytes);
        }
    }
    Some(Base { manifest, texts })
}

/// Brings the cloud copy's newer generation into this folder, merging it with the folder's own changes since it last synced. With files both sides
/// edited in the same place, and no `choices` for them, nothing is changed and they are reported.
fn pull(config: &Config, emit: &mut dyn FnMut(Value)) -> Result<(), Failure> {
    let (state_path, remembered) = remembered(config)?;
    let key = gateway_of(config).base;
    let id = remembered[&key]["workspace"].as_str().ok_or_else(|| Failure::new("not-synced", "This folder has not been synced to this gateway."))?.to_string();
    let dir = base_dir(&state_path, &id);
    let known = remembered[&key]["generation"].as_u64();
    let base = load_base(&dir).filter(|base| known.is_none_or(|known| known == base.generation())).ok_or_else(|| Failure::new("no-base", "This folder has no record of what it last synced, so the cloud's changes cannot be merged with its own. Sync it once with the cloud copy replaced to start one."))?;
    let mut with_workspace = config.clone();
    with_workspace.workspace = Some(id.clone());
    let (next, report) = merge_with(&with_workspace, &base, &config.choices)?;
    if report.conflicts.is_empty() {
        if next.generation() != base.generation() {
            let _ = store_base(&dir, &next);
            let mut saved = remembered.clone();
            saved[&key] = json!({"workspace": id, "generation": next.generation()});
            let _ = fs::write(&state_path, saved.to_string());
        }
    }
    emit(json!({
        "event": "merged",
        "generation": report.generation,
        "written": report.written,
        "deleted": report.deleted,
        "conflicts": report.conflicts.iter().map(|(path, reason)| json!({"path": path, "reason": reason})).collect::<Vec<_>>(),
    }));
    Ok(())
}

/// The CLI's write-back: the tree's base is whatever generation the config says it was restored from.
fn writeback(config: &Config, emit: &mut dyn FnMut(Value), cancelled: &dyn Fn() -> bool) -> Result<(), Failure> {
    let base = config.base_generation.ok_or_else(|| Failure::new("usage", "Write-back needs the generation the tree was restored from."))?;
    let (gateway, id) = existing_workspace(config)?;
    let manifest = cloud_manifest(&gateway, &id)?;
    if manifest.generation != base {
        return Err(Failure::new("conflict", format!("The cloud copy is at generation {} and this workspace was restored from generation {base}; nothing was saved.", manifest.generation)));
    }
    save(config, &Base { manifest, texts: BTreeMap::new() }, emit, cancelled).map(|_| ())
}

fn entries(files: &[FileEntry]) -> BTreeMap<String, Entry> {
    files.iter().filter(|file| mergeable(file)).map(|file| (file.path.clone(), Entry { hash: file.hash.clone(), executable: file.kind == FileKind::Executable })).collect()
}

fn safe_path(path: &str) -> bool {
    let path = Path::new(path);
    !path.as_os_str().is_empty()
        && path.components().all(|part| matches!(part, Component::Normal(_)))
        && !path.components().any(|part| part.as_os_str().eq_ignore_ascii_case(".git"))
}

/// The content of one of the cloud copy's files, with every chunk and the whole checked against its hash.
fn fetch_file(gateway: &Gateway, id: &str, file: &FileEntry) -> Option<Vec<u8>> {
    let mut bytes = Vec::with_capacity(file.size as usize);
    for chunk in &file.chunks {
        let part = gateway.call("GET", &format!("/workspaces/{id}/export/chunks/{}", chunk.hash), None).ok()?;
        if sha256_hex(&part) != chunk.hash {
            return None;
        }
        bytes.extend(part);
    }
    (sha256_hex(&bytes) == file.hash).then_some(bytes)
}

/// Brings the cloud copy's newer generation into the tree. Files changed only there move over, files changed only here stay, and text changed on both
/// sides in different places is merged. If anything cannot be decided for the person, nothing at all is changed and the files are reported.
pub fn merge_cloud(config: &Config, base: &Base) -> Result<(Base, MergeReport), Failure> {
    merge_with(config, base, &config.choices)
}

/// `merge_cloud`, where `choices` says which side wins each file both sides edited in the same place. With a choice for every such file the merge goes
/// through; without, nothing is changed and they are listed.
pub fn merge_with(config: &Config, base: &Base, choices: &BTreeMap<String, String>) -> Result<(Base, MergeReport), Failure> {
    let (gateway, id) = existing_workspace(config)?;
    let status = gateway.json("GET", &format!("/workspaces/{id}"), None)?;
    let current = status["generation"].as_u64().unwrap_or(0);
    if current == base.generation() {
        return Ok((base.clone(), MergeReport { generation: current, ..Default::default() }));
    }
    let theirs = cloud_manifest(&gateway, &id)?;
    let ours = scan_tree(
        &config.root,
        &base.manifest,
        &Options { workspace: WorkspaceId::parse(&id).map_err(|_| Failure::new("protocol", "The workspace id is not valid."))?, base_generation: base.generation(), device: "browser session".into(), now_ms: now_ms(), limits: Limits::for_allocation(status["allocation"].as_u64().unwrap_or(DEFAULT_ALLOCATION_BYTES)), selection: Selection::default(), history: false, buffers: vec![] },
    )
    .map_err(|e| Failure::new("scan", e.to_string()))?;
    let mut fetched: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let plan = {
        let mut content = |side: Side, path: &str| -> Option<Vec<u8>> {
            match side {
                Side::Base => base.texts.get(path).cloned(),
                Side::Ours => fs::read(config.root.join(path)).ok(),
                Side::Theirs => {
                    let file = theirs.files.iter().find(|file| file.path == path && mergeable(file))?;
                    let bytes = fetch_file(&gateway, &id, file)?;
                    fetched.insert(path.to_string(), bytes.clone());
                    Some(bytes)
                }
            }
        };
        merge::plan(&entries(&base.manifest.files), &entries(&ours.manifest.files), &entries(&theirs.files), &mut content)
    };
    if plan.conflicts.iter().any(|conflict| !matches!(choices.get(&conflict.path).map(String::as_str), Some("mine" | "theirs"))) {
        let conflicts = plan.conflicts.iter().map(|c| (c.path.clone(), c.reason.to_string())).collect();
        return Ok((base.clone(), MergeReport { generation: current, conflicts, ..Default::default() }));
    }
    let mut actions = plan.actions;
    for conflict in &plan.conflicts {
        let theirs_file = theirs.files.iter().find(|file| file.path == conflict.path && mergeable(file));
        match (choices[&conflict.path].as_str(), theirs_file) {
            // Keeping our version leaves the tree as it is; the cloud's text is still kept for the next merge when it is small enough to merge.
            ("mine", Some(file)) if file.size as usize <= MAX_TEXT => {
                if let Some(bytes) = fetch_file(&gateway, &id, file) {
                    fetched.insert(conflict.path.clone(), bytes);
                }
            }
            ("theirs", Some(file)) => match fetch_file(&gateway, &id, file) {
                Some(content) => {
                    fetched.insert(conflict.path.clone(), content.clone());
                    actions.push(Action::Write { path: conflict.path.clone(), content, executable: file.kind == FileKind::Executable });
                }
                None => return Err(Failure::new("network", "The cloud's version could not be read.")),
            },
            ("theirs", None) => actions.push(Action::Delete { path: conflict.path.clone() }),
            _ => {}
        }
    }
    let mut report = MergeReport { generation: current, ..Default::default() };
    for action in &actions {
        let path = match action {
            Action::Write { path, .. } | Action::Delete { path } => path,
        };
        if !safe_path(path) {
            return Err(Failure::new("protocol", "The cloud copy names a path this tree cannot hold."));
        }
    }
    for action in actions {
        match action {
            Action::Write { path, content, executable } => {
                let target = config.root.join(&path);
                if let Some(parent) = target.parent() {
                    fs::create_dir_all(parent).map_err(|e| Failure::new("write", e.to_string()))?;
                }
                let temporary = target.with_extension(format!("rayde-merge-{}", std::process::id()));
                fs::write(&temporary, &content).map_err(|e| Failure::new("write", e.to_string()))?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = fs::set_permissions(&temporary, fs::Permissions::from_mode(if executable { 0o755 } else { 0o644 }));
                }
                #[cfg(not(unix))]
                let _ = executable;
                fs::rename(&temporary, &target).map_err(|e| Failure::new("write", e.to_string()))?;
                report.written.push(path);
            }
            Action::Delete { path } => {
                match fs::remove_file(config.root.join(&path)) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(Failure::new("write", e.to_string())),
                }
                report.deleted.push(path);
            }
        }
    }
    // From here the tree is based on the cloud's current generation, and what the next merge starts from is that generation's text.
    let mut texts = BTreeMap::new();
    for file in theirs.files.iter().filter(|file| mergeable(file) && file.size as usize <= MAX_TEXT) {
        let kept = fetched.get(&file.path).cloned().or_else(|| base.manifest.files.iter().find(|b| b.path == file.path && b.hash == file.hash).and_then(|_| base.texts.get(&file.path).cloned()));
        if let Some(bytes) = kept {
            texts.insert(file.path.clone(), bytes);
        }
    }
    Ok((Base { manifest: theirs, texts }, report))
}

/// An upload running on its own thread. Events are read with `poll`; the last one is `published` or `error`.
pub struct Push {
    events: Arc<Mutex<VecDeque<Value>>>,
    cancel: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
}

impl Push {
    pub fn start(config: Config) -> Push {
        let push = Push { events: Arc::default(), cancel: Arc::default(), finished: Arc::default() };
        let (events, cancel, finished) = (push.events.clone(), push.cancel.clone(), push.finished.clone());
        std::thread::spawn(move || {
            let outcome = run(&config, &mut |event| events.lock().unwrap().push_back(event), &|| cancel.load(Ordering::Relaxed));
            if let Err(failure) = outcome {
                events.lock().unwrap().push_back(json!({"event": "error", "code": failure.code, "message": failure.message}));
            }
            finished.store(true, Ordering::Release);
        });
        push
    }

    pub fn poll(&self) -> Vec<Value> {
        self.events.lock().unwrap().drain(..).collect()
    }

    /// Whether the job still runs or has events to read.
    pub fn pending(&self) -> bool {
        !self.finished.load(Ordering::Acquire) || !self.events.lock().unwrap().is_empty()
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}
