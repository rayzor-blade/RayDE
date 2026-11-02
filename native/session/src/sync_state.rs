//! Checksummed, bounded common bases and write-ahead intents in session-private storage.
use crate::error::{Result, SessionError};
use rayde_sync::{
    client::Base,
    lifecycle::Limits,
    manifest::{FileKind, Manifest},
    merge::{Action, MAX_TEXT},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Read,
    path::Path,
};

const MAGIC: &[u8] = b"RDSYNC1\0";
const MAX_HEADER: usize = 8 * 1024 * 1024;
const MAX_TEXTS: usize = 32 * 1024 * 1024;
pub const MAX_RECORD: usize = MAGIC.len() + 36 + MAX_HEADER + MAX_TEXTS;
pub const BASE: &str = "sync:base:v1";
pub const PENDING: &str = "sync:pending:v1";
pub const BINDING: &str = "sync:binding:v1";

pub fn invalid() -> SessionError {
    SessionError::new(
        "sync-recovery",
        "Cloud Sync needs recovery. Its common base is missing, incomplete or belongs to another workspace. Local files have been kept.",
    )
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub version: u32,
    pub workspace: String,
    pub gateway: String,
    pub restored: u64,
    pub initialized: bool,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Expected {
    Write {
        path: String,
        hash: String,
        size: u64,
        executable: bool,
    },
    Link {
        path: String,
        target: String,
    },
    Delete {
        path: String,
    },
}
impl Expected {
    pub fn from_action(action: &Action) -> Self {
        match action {
            Action::Write {
                path,
                content,
                executable,
            } => Self::Write {
                path: path.clone(),
                hash: crate::checkpoint::digest(content),
                size: content.len() as u64,
                executable: *executable,
            },
            Action::Link { path, target } => Self::Link {
                path: path.clone(),
                target: target.clone(),
            },
            Action::Delete { path } => Self::Delete { path: path.clone() },
        }
    }
    pub fn path(&self) -> &str {
        match self {
            Self::Write { path, .. } | Self::Link { path, .. } | Self::Delete { path } => path,
        }
    }
    pub fn matches(&self, root: &Path) -> bool {
        let path = root.join(self.path());
        match self {
            Self::Delete { .. } => {
                fs::symlink_metadata(path).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
            }
            Self::Link { target, .. } => fs::read_link(path).ok().is_some_and(|p| {
                rayde_sync::links::manifest_target(&p.to_string_lossy()) == *target
            }),
            Self::Write {
                hash,
                executable,
                size,
                ..
            } => fs::symlink_metadata(&path)
                .ok()
                .filter(|m| m.is_file())
                .is_some_and(|meta| {
                    if meta.len() != *size {
                        return false;
                    }
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        if (meta.permissions().mode() & 0o111 != 0) != *executable {
                            return false;
                        }
                    }
                    #[cfg(not(unix))]
                    let _ = (meta, executable);
                    file_hash(&path).is_ok_and(|digest| digest == *hash)
                }),
        }
    }
}

fn file_hash(path: &Path) -> std::io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Text {
    path: String,
    size: usize,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u32,
    gateway: String,
    operation: Option<String>,
    expected: Vec<Expected>,
    manifest: Manifest,
    texts: Vec<Text>,
}
pub struct Record {
    pub base: Base,
    pub operation: Option<String>,
    pub expected: Vec<Expected>,
}

pub fn pack(
    gateway: &str,
    base: &Base,
    operation: Option<&str>,
    expected: Vec<Expected>,
) -> Result<Vec<u8>> {
    let header = Header {
        version: 1,
        gateway: gateway.into(),
        operation: operation.map(str::to_string),
        expected,
        manifest: base.manifest.clone(),
        texts: base
            .texts
            .iter()
            .map(|(path, bytes)| Text {
                path: path.clone(),
                size: bytes.len(),
            })
            .collect(),
    };
    let json = serde_json::to_vec(&header).map_err(|_| invalid())?;
    if json.len() > MAX_HEADER || base.texts.values().map(Vec::len).sum::<usize>() > MAX_TEXTS {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    bytes.extend_from_slice(MAGIC);
    bytes.extend_from_slice(&[0; 32]);
    bytes.extend_from_slice(&(json.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&json);
    for text in base.texts.values() {
        bytes.extend_from_slice(text);
    }
    let digest = Sha256::digest(&bytes[MAGIC.len() + 32..]);
    bytes[MAGIC.len()..MAGIC.len() + 32].copy_from_slice(&digest);
    Ok(bytes)
}

pub fn unpack(bytes: &[u8], gateway: &str, workspace: &str) -> Result<Record> {
    let start = MAGIC.len() + 32;
    if bytes.len() < start + 4
        || bytes.len() > MAX_RECORD
        || !bytes.starts_with(MAGIC)
        || Sha256::digest(&bytes[start..]).as_slice() != &bytes[MAGIC.len()..start]
    {
        return Err(invalid());
    }
    let size = u32::from_be_bytes(bytes[start..start + 4].try_into().unwrap()) as usize;
    if size > MAX_HEADER || start + 4 + size > bytes.len() {
        return Err(invalid());
    }
    let header: Header =
        serde_json::from_slice(&bytes[start + 4..start + 4 + size]).map_err(|_| invalid())?;
    let limits = Limits::for_allocation(u64::MAX / 4);
    if header.version != 1
        || header.gateway != gateway
        || header.manifest.workspace.as_str() != workspace
        || header.manifest.base_generation.checked_add(1) != Some(header.manifest.generation)
        || header.manifest.files.len() > limits.max_files
        || header
            .manifest
            .files
            .iter()
            .any(|file| file.size > limits.max_file_bytes)
        || header.manifest.buffers.len() > limits.max_buffers
        || header
            .manifest
            .buffers
            .iter()
            .any(|buffer| buffer.size > limits.max_buffer_bytes)
        || header
            .manifest
            .git
            .history
            .as_ref()
            .is_some_and(|history| history.size > limits.max_history_bytes)
        || !header
            .manifest
            .validate(&Limits::for_allocation(u64::MAX / 4))
            .is_empty()
        || !matches!(
            header.operation.as_deref(),
            None | Some("publish" | "merge")
        )
        || header.operation.as_deref() != Some("merge") && !header.expected.is_empty()
    {
        return Err(invalid());
    }
    for expected in &header.expected {
        if rayde_sync::manifest::path_problem(expected.path(), &Limits::default()).is_some() {
            return Err(invalid());
        }
        if let Expected::Link { path, target } = expected {
            if rayde_sync::manifest::link_problem(path, target).is_some() {
                return Err(invalid());
            }
        }
    }
    let mut offset = start + 4 + size;
    if bytes.len() - offset > MAX_TEXTS || header.texts.len() > header.manifest.files.len() {
        return Err(invalid());
    }
    let files = header
        .manifest
        .files
        .iter()
        .map(|file| (file.path.as_str(), file))
        .collect::<BTreeMap<_, _>>();
    let mut texts = BTreeMap::new();
    for text in header.texts {
        if text.size > MAX_TEXT
            || offset
                .checked_add(text.size)
                .is_none_or(|end| end > bytes.len())
            || texts.contains_key(&text.path)
        {
            return Err(invalid());
        }
        let file = files
            .get(text.path.as_str())
            .filter(|file| matches!(file.kind, FileKind::Regular | FileKind::Executable))
            .ok_or_else(invalid)?;
        let data = &bytes[offset..offset + text.size];
        if file.size != text.size as u64 || crate::checkpoint::digest(data) != file.hash {
            return Err(invalid());
        }
        texts.insert(text.path, data.to_vec());
        offset += text.size;
    }
    if offset != bytes.len() || texts.values().map(Vec::len).sum::<usize>() > MAX_TEXTS {
        return Err(invalid());
    }
    Ok(Record {
        base: Base {
            manifest: header.manifest,
            texts,
        },
        operation: header.operation,
        expected: header.expected,
    })
}

/// Flush the completed merge before advancing its durable common base.
pub fn flush(root: &Path, expected: &[Expected]) -> Result<()> {
    let mut directories: BTreeSet<std::path::PathBuf> = BTreeSet::new();
    for change in expected {
        let path = root.join(change.path());
        if fs::symlink_metadata(&path).is_ok_and(|m| m.is_file()) {
            fs::OpenOptions::new()
                .write(true)
                .open(&path)
                .and_then(|f| f.sync_all())
                .map_err(|_| invalid())?;
        }
        #[cfg(unix)]
        {
            let mut parent = path.parent();
            while let Some(dir) = parent {
                directories.insert(dir.to_path_buf());
                if dir == root {
                    break;
                }
                parent = dir.parent();
            }
        }
    }
    for directory in directories {
        fs::File::open(directory)
            .and_then(|f| f.sync_all())
            .map_err(|_| invalid())?;
    }
    Ok(())
}
