//! Connection-owned browser build artifacts, served on a separate loopback origin.
use crate::{
    error::{Result, SessionError},
    store::clean,
};
use axum::{
    Router,
    body::Body,
    extract::{Path as RoutePath, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use rand::RngCore;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt},
    net::TcpListener,
    sync::oneshot,
};

const MAX_FILE: u64 = 64 * 1024 * 1024;
const MAX_TOTAL: u64 = 256 * 1024 * 1024;
const CHUNK: usize = 512 * 1024;
struct Entry {
    owner: u64,
    root: PathBuf,
}
struct Build {
    owner: u64,
    plan: Option<crate::preview_cache::Plan>,
}
pub(crate) struct Previews {
    root: PathBuf,
    base: String,
    tools: Option<PathBuf>,
    entries: Mutex<HashMap<String, Entry>>,
    builds: Mutex<HashMap<String, Build>>,
    cache: Option<crate::preview_cache::Cache>,
}
pub(crate) struct Running {
    pub registry: Arc<Previews>,
    stop: Option<oneshot::Sender<()>>,
}
impl Drop for Running {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}
fn failure(message: &str) -> SessionError {
    SessionError::new("preview", message)
}
fn io_error(error: std::io::Error) -> SessionError {
    failure(&error.to_string())
}
impl Previews {
    pub async fn start(
        root: &Path,
        tools: Option<PathBuf>,
        environment: &HashMap<String, String>,
    ) -> std::io::Result<Running> {
        let tools = tools.map(std::fs::canonicalize).transpose()?;
        if let Some(tools) = &tools {
            for name in [
                "haxe/rayde/preview/Files.hx",
                "ash_channel.wasm",
                "channel-agent.mjs",
                "rayde_preview_files.mjs",
                "preview-frames.mjs",
            ] {
                if !tools.join(name).is_file() {
                    return Err(std::io::Error::other(
                        "The app preview tooling is incomplete.",
                    ));
                }
            }
        }
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
        let registry = Arc::new(Self {
            root: root.into(),
            base: format!("http://{}", listener.local_addr()?),
            cache: tools
                .as_ref()
                .map(|tools| crate::preview_cache::Cache::new(root, tools, environment)),
            tools,
            entries: Mutex::new(HashMap::new()),
            builds: Mutex::new(HashMap::new()),
        });
        let app = Router::new()
            .route("/:id/*path", get(resource))
            .with_state(registry.clone());
        let (stop, stopped) = oneshot::channel();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = stopped.await;
                })
                .await;
        });
        Ok(Running {
            registry,
            stop: Some(stop),
        })
    }
    pub fn ready(&self) -> bool {
        self.tools.is_some()
    }
    pub fn release(&self, owner: u64) {
        self.entries
            .lock()
            .unwrap()
            .retain(|_, entry| entry.owner != owner);
        let mut builds = self.builds.lock().unwrap();
        let paths = builds
            .iter()
            .filter(|(_, build)| build.owner == owner)
            .map(|(path, _)| path.clone())
            .collect::<Vec<_>>();
        for path in paths {
            builds.remove(&path);
            let path = self.root.join(path);
            tokio::spawn(async move {
                let _ = tokio::fs::remove_dir_all(path).await;
            });
        }
    }
    pub async fn request(&self, owner: u64, op: &str, request: &Value) -> Result<Value> {
        if op == "preview.prepare" {
            let tools = self
                .tools
                .as_ref()
                .ok_or_else(|| failure("Install app preview tooling on this session host."))?;
            let mut random = [0u8; 16];
            rand::rngs::OsRng.fill_bytes(&mut random);
            let name = random
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            let path = format!(".rayde/previews/{name}");
            {
                let mut builds = self.builds.lock().unwrap();
                if builds.len() >= 8
                    || builds.values().filter(|build| build.owner == owner).count() >= 4
                {
                    return Err(failure("Close another app preview before building one."));
                }
                builds.insert(path.clone(), Build { owner, plan: None });
            }
            let directory = self.root.join(&path);
            let result=async {
                tokio::fs::create_dir_all(&directory).await.map_err(io_error)?;
                let resolved=tokio::fs::canonicalize(&directory).await.map_err(io_error)?;
                if !resolved.starts_with(&self.root){return Err(failure("The preview build leaves the workspace."));}
                for name in ["ash_channel.wasm","channel-agent.mjs","rayde_preview_files.mjs","preview-frames.mjs"] {
                    tokio::fs::copy(tools.join(name),directory.join(name)).await.map_err(io_error)?;
                }
                let mut cached="miss";let mut note=String::new();
                if let (Some(cache),Some(recipe))=(&self.cache,request.get("recipe")) {
                    let recipe=serde_json::from_value::<crate::preview_cache::Recipe>(recipe.clone()).map_err(|_|failure("Invalid preview compiler configuration."))?;
                    if request["force"]==true {if let Err(error)=cache.clear().await{note=error}}
                    match cache.plan(recipe).await {
                        Ok(plan)=>{
                            if request["force"]!=true {match cache.restore(&plan,&directory).await{Ok(stage)=>cached=stage,Err(error)=>note=error}}
                            if let Some(build)=self.builds.lock().unwrap().get_mut(&path).filter(|build|build.owner==owner){build.plan=Some(plan);}
                            else {let _=tokio::fs::remove_dir_all(&directory).await;return Err(failure("The preview build was closed."));}
                        }
                        Err(error)=>note=error,
                    }
                }
                Ok(json!({"path":path,"directory":directory,"support":tools.join("haxe"),"runtime":tools.join("ash_runtime.o").is_file().then(||tools.join("ash_runtime.o")),"cached":cached,"cacheNote":note}))
            }.await;
            if result.is_err() {
                self.builds.lock().unwrap().remove(&path);
            }
            return result;
        }
        if op == "preview.cache" {
            let path = clean(request["path"].as_str().unwrap_or(""))?;
            let plan = {
                let builds = self.builds.lock().unwrap();
                builds
                    .get(&path)
                    .filter(|build| build.owner == owner)
                    .ok_or_else(|| failure("This preview build is closed."))?
                    .plan
                    .clone()
            };
            let stage = request["stage"]
                .as_str()
                .filter(|stage| ["bytecode", "wasm"].contains(stage))
                .ok_or_else(|| failure("Unknown compiler cache stage."))?;
            if let (Some(cache), Some(plan)) = (&self.cache, plan) {
                return Ok(
                    match cache.publish(&plan, &self.root.join(path), stage).await {
                        Ok(saved) => {
                            json!({"cached":saved,"cacheNote":if saved{""}else{"Build inputs changed during compilation; cache not published."}})
                        }
                        Err(note) => json!({"cached":false,"cacheNote":note}),
                    },
                );
            }
            return Ok(json!({"cached":false}));
        }
        if op == "preview.discard" {
            let path = clean(request["path"].as_str().unwrap_or(""))?;
            {
                let mut builds = self.builds.lock().unwrap();
                if !builds.get(&path).is_some_and(|build| build.owner == owner) {
                    return Err(failure("This preview build is closed."));
                }
                builds.remove(&path);
            }
            let directory = self.root.join(&path);
            self.entries
                .lock()
                .unwrap()
                .retain(|_, entry| entry.root != directory);
            tokio::fs::remove_dir_all(directory)
                .await
                .map_err(io_error)?;
            return Ok(json!({}));
        }
        if op == "preview.open" {
            let path = clean(
                request["path"]
                    .as_str()
                    .ok_or_else(|| failure("Choose a preview build directory."))?,
            )?;
            if !path.starts_with(".rayde/previews/") {
                return Err(failure("Preview builds must use .rayde/previews/."));
            }
            let root = tokio::fs::canonicalize(self.root.join(&path))
                .await
                .map_err(io_error)?;
            if !root.starts_with(&self.root) || !root.is_dir() {
                return Err(failure("The preview build leaves the workspace."));
            }
            let mut directories = vec![root.clone()];
            let mut count = 0;
            let mut bytes = 0u64;
            while let Some(directory) = directories.pop() {
                let mut entries = tokio::fs::read_dir(directory).await.map_err(io_error)?;
                while let Some(entry) = entries.next_entry().await.map_err(io_error)? {
                    count += 1;
                    if count > 2048 {
                        return Err(failure("The preview contains too many files."));
                    }
                    let metadata = entry.metadata().await.map_err(io_error)?;
                    if entry.file_type().await.map_err(io_error)?.is_symlink() {
                        return Err(failure("Preview artifacts must not contain symlinks."));
                    }
                    if metadata.is_dir() {
                        directories.push(entry.path());
                        continue;
                    }
                    if !metadata.is_file() || metadata.len() > MAX_FILE {
                        return Err(failure("A preview artifact is unsupported or too large."));
                    }
                    bytes = bytes
                        .checked_add(metadata.len())
                        .ok_or_else(|| failure("The preview is too large."))?;
                    if bytes > MAX_TOTAL {
                        return Err(failure("The preview is too large."));
                    }
                }
            }
            if !root.join("index.html").is_file() {
                return Err(failure("The build did not produce index.html."));
            }
            let mut entries = self.entries.lock().unwrap();
            if entries.len() >= 8
                || entries
                    .values()
                    .filter(|entry| entry.owner == owner)
                    .count()
                    >= 4
            {
                return Err(failure("Close another app preview before opening one."));
            }
            let mut random = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut random);
            let id = random
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            entries.insert(id.clone(), Entry { owner, root });
            return Ok(
                json!({"preview":id,"url":format!("{}/{id}/index.html",self.base),"entry":"index.html"}),
            );
        }
        let id = request["preview"]
            .as_str()
            .ok_or_else(|| failure("The preview is missing."))?;
        if !self
            .entries
            .lock()
            .unwrap()
            .get(id)
            .is_some_and(|entry| entry.owner == owner)
        {
            return Err(failure("This preview is closed."));
        }
        if op == "preview.close" {
            self.entries.lock().unwrap().remove(id);
            return Ok(json!({}));
        }
        if op != "preview.read" {
            return Err(failure("Unknown preview operation."));
        }
        let name = request["path"]
            .as_str()
            .ok_or_else(|| failure("The artifact path is missing."))?;
        let (path, size) = self.file(id, name).await?;
        let offset = request["offset"].as_u64().unwrap_or(0).min(size);
        let length = request["length"]
            .as_u64()
            .unwrap_or(CHUNK as u64)
            .min(CHUNK as u64);
        let mut file = tokio::fs::File::open(path).await.map_err(io_error)?;
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(io_error)?;
        let mut bytes = Vec::new();
        file.take(length)
            .read_to_end(&mut bytes)
            .await
            .map_err(io_error)?;
        Ok(
            json!({"data":B64.encode(&bytes),"offset":offset,"size":size,"mime":mime(name),"eof":offset+bytes.len() as u64>=size}),
        )
    }
    async fn file(&self, id: &str, name: &str) -> Result<(PathBuf, u64)> {
        let root = self
            .entries
            .lock()
            .unwrap()
            .get(id)
            .map(|entry| entry.root.clone())
            .ok_or_else(|| failure("This preview is closed."))?;
        let relative = clean(name)?;
        if relative.is_empty() {
            return Err(failure("The artifact path is missing."));
        }
        let path = tokio::fs::canonicalize(root.join(relative))
            .await
            .map_err(io_error)?;
        if !path.starts_with(&root) {
            return Err(failure("The path leaves the preview."));
        }
        let metadata = tokio::fs::metadata(&path).await.map_err(io_error)?;
        if !metadata.is_file() || metadata.len() > MAX_FILE {
            return Err(failure("The preview artifact is unavailable."));
        }
        Ok((path, metadata.len()))
    }
}
fn mime(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "wasm" => "application/wasm",
        "css" => "text/css",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "webp" => "image/webp",
        "jpg" | "jpeg" => "image/jpeg",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        _ => "application/octet-stream",
    }
}
async fn resource(
    State(previews): State<Arc<Previews>>,
    RoutePath((id, path)): RoutePath<(String, String)>,
) -> Response {
    let Ok((file, size)) = previews.file(&id, &path).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Ok(file) = tokio::fs::File::open(file).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let stream = futures_util::stream::try_unfold(file.take(size), |mut file| async move {
        let mut bytes = vec![0u8; 64 * 1024];
        let length = file.read(&mut bytes).await?;
        if length == 0 {
            Ok::<_, std::io::Error>(None)
        } else {
            bytes.truncate(length);
            Ok(Some((bytes, file)))
        }
    });
    let mut headers = HeaderMap::new();
    for (name, value) in [
        (header::CONTENT_TYPE, mime(&path)),
        (header::CACHE_CONTROL, "no-store"),
        (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
    ] {
        headers.insert(name, value.parse().unwrap());
    }
    headers.insert(header::CONTENT_LENGTH, size.into());
    headers.insert("Cross-Origin-Opener-Policy", "same-origin".parse().unwrap());
    headers.insert(
        "Cross-Origin-Embedder-Policy",
        "require-corp".parse().unwrap(),
    );
    headers.insert(
        "Cross-Origin-Resource-Policy",
        "cross-origin".parse().unwrap(),
    );
    (headers, Body::from_stream(stream)).into_response()
}
