//! The desktop side of an upload: scans a folder, sends the chunks the gateway lacks and publishes. A `Push` runs on its own thread and reports
//! progress as JSON events that the caller polls, so a UI never waits on the network.
use crate::{
    chunk::MAX_CHUNK,
    exclude::Selection,
    ids::WorkspaceId,
    lifecycle::{DEFAULT_ALLOCATION_BYTES, Limits},
    manifest::ChunkRef,
    scan::{Options, scan},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    fs,
    path::PathBuf,
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
    agent: ureq::Agent,
}

impl Gateway {
    fn call(&self, method: &str, path: &str, body: Option<&[u8]>) -> Result<Vec<u8>, Failure> {
        let mut request = self.agent.request(method, &format!("{}/api/sync{path}", self.base));
        if let Some(account) = &self.account {
            request = request.set("X-Dev-Account", account);
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

/// Runs one upload to completion, reporting through `emit`. `cancelled` is asked between chunks; a cancelled upload is dropped at the gateway.
pub fn run(config: &Config, emit: &mut dyn FnMut(Value), cancelled: &dyn Fn() -> bool) -> Result<(), Failure> {
    let gateway = Gateway {
        base: config.gateway.trim_end_matches('/').to_string(),
        account: config.account.clone(),
        agent: ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(10)).timeout(Duration::from_secs(300)).build(),
    };
    let git_dir = std::process::Command::new("git").arg("-C").arg(&config.root).args(["rev-parse", "--absolute-git-dir"]).output().map_err(|e| Failure::new("git", e.to_string()))?;
    if !git_dir.status.success() {
        return Err(Failure::new("not-a-repository", "This folder is not a Git repository."));
    }
    // The folder remembers its workspace per gateway, inside `.git`, which is never uploaded.
    let state_path = PathBuf::from(String::from_utf8_lossy(&git_dir.stdout).trim()).join("rayde-sync.json");
    let remembered: Value = fs::read(&state_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(json!({}));
    let key = gateway.base.clone();

    let status = match remembered[&key]["workspace"].as_str() {
        Some(id) => match gateway.json("GET", &format!("/workspaces/{id}"), None) {
            Ok(status) => status,
            Err(failure) if failure.message.contains("No such") => gateway.json("POST", "/workspaces", Some(&json!({})))?,
            Err(failure) => return Err(failure),
        },
        None => gateway.json("POST", "/workspaces", Some(&json!({})))?,
    };
    let id = status["id"].as_str().ok_or_else(|| Failure::new("protocol", "The gateway did not name a workspace."))?.to_string();
    let mut saved = remembered.clone();
    saved[&key] = json!({"workspace": id});
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
            Ok(())
        }
        Err(failure) => {
            let _ = gateway.call("DELETE", &format!("/workspaces/{id}/uploads/{lease}"), None);
            Err(failure)
        }
    }
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
