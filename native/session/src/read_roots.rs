//! Operator-selected library and extension sources. These mounts never create shared documents.
use crate::{error::{Result, SessionError}, session::MAX_READ, store::{Entry, clean}};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{io, path::{Path, PathBuf}, time::UNIX_EPOCH};
use tokio::io::AsyncReadExt;

pub struct ReadRoots(Vec<(String, PathBuf)>);
impl ReadRoots {
    pub fn new(paths: Vec<PathBuf>, workspace: &Path) -> io::Result<Self> {
        if paths.len() > 32 { return Err(io::Error::other("Too many read-only source roots.")); }
        let mut roots = Vec::new();
        for path in paths {
            let path = std::fs::canonicalize(path)?;
            if !path.is_dir() || path.parent().is_none() || workspace.starts_with(&path) || path.starts_with(workspace) {
                return Err(io::Error::other("Read-only sources must be directories outside the workspace."));
            }
            if roots.iter().any(|(_, existing)| existing == &path) { continue; }
            let id = format!("{:x}", Sha256::digest(path.as_os_str().as_encoded_bytes()));
            roots.push((id, path));
        }
        Ok(Self(roots))
    }
    pub fn describe(&self) -> Value {
        json!(self.0.iter().map(|(id,path)| json!({"id":id,"path":path.to_string_lossy()})).collect::<Vec<_>>())
    }
    pub async fn request(&self, op: &str, request: &Value) -> Result<Value> {
        if !matches!(op, "fs.list" | "fs.stat" | "fs.read") {
            return Err(SessionError::new("read-only", "Library and installed extension sources are read-only."));
        }
        let id = request["mount"].as_str().ok_or_else(|| SessionError::new("bad-request", "The source mount is missing."))?;
        let root = &self.0.iter().find(|(key,_)| key == id).ok_or_else(|| SessionError::new("outside", "The source mount is not available."))?.1;
        let relative = clean(request.get("path").and_then(Value::as_str).unwrap_or(""))?;
        let absolute = root.join(relative);
        let actual = match tokio::fs::canonicalize(&absolute).await {
            Ok(path) if path.starts_with(root) => path,
            Ok(_) => return Err(SessionError::new("outside", "The path leaves the source mount.")),
            Err(error) if error.kind() == io::ErrorKind::NotFound && op == "fs.stat" => return Ok(json!({"entry":null})),
            Err(error) => return Err(failed(error)),
        };
        let metadata = tokio::fs::metadata(&actual).await.map_err(failed)?;
        if op == "fs.stat" { return Ok(json!({"entry":entry(absolute.file_name().map_or_else(String::new, |s|s.to_string_lossy().into()), &metadata)})); }
        if op == "fs.list" {
            let mut directory = tokio::fs::read_dir(&actual).await.map_err(failed)?;
            let mut entries = Vec::new();
            while let Some(item) = directory.next_entry().await.map_err(failed)? {
                if entries.len() >= 16_384 { return Err(SessionError::new("too-large", "The source directory contains too many entries.")); }
                let Ok(path) = tokio::fs::canonicalize(item.path()).await else { continue; };
                if !path.starts_with(root) { continue; }
                let metadata = tokio::fs::metadata(path).await.map_err(failed)?;
                entries.push(entry(item.file_name().to_string_lossy().into(), &metadata));
            }
            entries.sort_by(|a,b| (a.kind != "dir",a.name.to_lowercase()).cmp(&(b.kind != "dir",b.name.to_lowercase())));
            return Ok(json!({"entries":entries}));
        }
        if !metadata.is_file() { return Err(SessionError::new("wrong-kind", "The source is not a file.")); }
        if metadata.len() > MAX_READ { return Err(SessionError::new("too-large", "The source file is too large to read in one message.")); }
        let mut bytes = Vec::new();
        tokio::fs::File::open(actual).await.map_err(failed)?.take(MAX_READ + 1).read_to_end(&mut bytes).await.map_err(failed)?;
        if bytes.len() as u64 > MAX_READ { return Err(SessionError::new("too-large", "The source file is too large to read in one message.")); }
        let offset = request["offset"].as_u64().unwrap_or(0).min(bytes.len() as u64) as usize;
        let end = request["length"].as_u64().map_or(bytes.len(), |n| offset.saturating_add(n.min(MAX_READ) as usize).min(bytes.len()));
        let bytes = &bytes[offset..end];
        Ok(if request["encoding"] == "base64" { json!({"data":B64.encode(bytes),"encoding":"base64"}) }
           else { json!({"data":String::from_utf8_lossy(bytes),"encoding":"utf8"}) })
    }
}
fn failed(error: io::Error) -> SessionError {
    SessionError::new(if error.kind() == io::ErrorKind::NotFound {"not-found"} else {"failed"}, error.to_string())
}
fn entry(name: String, meta: &std::fs::Metadata) -> Entry {
    Entry { name, kind:if meta.is_dir() {"dir"} else if meta.is_file() {"file"} else {"other"}, size:meta.len(),
        mtime:meta.modified().ok().and_then(|time|time.duration_since(UNIX_EPOCH).ok()).map_or(0, |time|time.as_millis() as u64) }
}
