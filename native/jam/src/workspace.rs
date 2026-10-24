//! Independently recoverable documents and ephemeral active views in a Jam room.
use crate::{
    document::{Document, MAX_UPDATE},
    recovery::{self, Recovery},
    transport::Viewport,
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Write,
    path::PathBuf,
};

pub const MAX_DOCUMENTS: usize = 64;
pub const MAX_STATE: usize = 4 * 1024 * 1024;
pub const MAX_FRAME: usize = 512 * 1024;
const STORAGE_ERROR: &str = "Cannot save Jam workspace recovery";
const CORRUPT: &str =
    "Jam workspace recovery is damaged; preserve its folder before starting fresh";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Surface {
    Code { document: String },
    Preview { id: String, title: String },
    Idle,
}
impl Default for Surface {
    fn default() -> Self {
        Self::Idle
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Frame {
    pub view: String,
    pub sequence: u64,
    pub width: u32,
    pub height: u32,
    pub png: String,
}
impl Frame {
    pub fn valid(&self) -> bool {
        if !recovery::valid_id(&self.view)
            || self.width == 0
            || self.height == 0
            || self.width > 1280
            || self.height > 720
            || self.png.len() > MAX_FRAME * 4 / 3 + 8
        {
            return false;
        }
        let Ok(bytes) = B64.decode(&self.png) else {
            return false;
        };
        let header = bytes.len() >= 33
            && bytes.len() <= MAX_FRAME
            && &bytes[..8] == b"\x89PNG\r\n\x1a\n"
            && &bytes[8..16] == b"\0\0\0\rIHDR"
            && u32::from_be_bytes(bytes[16..20].try_into().unwrap()) == self.width
            && u32::from_be_bytes(bytes[20..24].try_into().unwrap()) == self.height
            && bytes[24] == 8
            && [0, 2, 3, 4, 6].contains(&bytes[25])
            && bytes[26..29] == [0, 0, 0];
        if !header {
            return false;
        }
        let mut at = 8usize;
        let mut data = false;
        while let Some(end) = at.checked_add(12).filter(|end| *end <= bytes.len()) {
            let size = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
            let Some(end) = end.checked_add(size).filter(|end| *end <= bytes.len()) else {
                return false;
            };
            let kind = &bytes[at + 4..at + 8];
            if crc32fast::hash(&bytes[at + 4..end - 4])
                != u32::from_be_bytes(bytes[end - 4..end].try_into().unwrap())
            {
                return false;
            }
            if kind == b"IEND" {
                return data && size == 0 && end == bytes.len();
            }
            if kind == b"IDAT" {
                data = true;
            } else if kind == b"IHDR" {
                if at != 8 || size != 13 {
                    return false;
                }
            } else if kind == b"acTL" || kind == b"fcTL" || kind == b"fdAT" {
                return false;
            }
            at = end;
        }
        false
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case", deny_unknown_fields)]
pub enum Message {
    Open {
        document: String,
        file: String,
        state: String,
    },
    Request {
        document: String,
    },
    Document {
        document: String,
        file: String,
        state: String,
        vector: String,
    },
    Sync {
        document: String,
        id: u64,
        update: String,
    },
    Update {
        document: String,
        peer: String,
        update: String,
    },
    Ack {
        document: String,
        id: u64,
    },
    Presence {
        document: String,
        caret: String,
        anchor: String,
        #[serde(default)]
        view: Option<Viewport>,
    },
    Cursor {
        document: String,
        peer: String,
        caret: String,
        anchor: String,
        #[serde(default)]
        view: Option<Viewport>,
    },
    Activate {
        surface: Surface,
    },
    Active {
        surface: Surface,
    },
    Frame {
        frame: Frame,
    },
}
impl Message {
    /// Validate allocation bounds before a command enters the network queue.
    pub fn client_valid(&self) -> bool {
        match self {
            Self::Open {
                document,
                file,
                state,
            } => {
                recovery::valid_id(document)
                    && valid_file(file)
                    && state.len() <= MAX_UPDATE * 4 / 3 + 8
            }
            Self::Sync {
                document, update, ..
            } => recovery::valid_id(document) && update.len() <= MAX_UPDATE * 4 / 3 + 8,
            Self::Request { document } => recovery::valid_id(document),
            Self::Presence {
                document,
                caret,
                anchor,
                view,
            } => {
                recovery::valid_id(document)
                    && caret.len() <= 256
                    && anchor.len() <= 256
                    && view.as_ref().is_none_or(Viewport::valid)
            }
            Self::Activate { surface } => surface.valid(),
            Self::Frame { frame } => frame.valid(),
            _ => false,
        }
    }
}
impl Surface {
    pub fn valid(&self) -> bool {
        match self {
            Self::Code { document } => recovery::valid_id(document),
            Self::Preview { id, title } => {
                recovery::valid_id(id)
                    && !title.is_empty()
                    && title.len() <= 255
                    && !title.chars().any(char::is_control)
            }
            Self::Idle => true,
        }
    }
}
pub fn valid_file(file: &str) -> bool {
    !file.is_empty()
        && file.len() <= 1024
        && !file.contains(['\\', ':'])
        && !file.chars().any(char::is_control)
        && file
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    document: String,
    file: String,
    #[serde(default)]
    shared: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    documents: Vec<Entry>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    data: String,
    crc: u32,
}

pub struct Store {
    root: Option<PathBuf>,
    documents: BTreeMap<String, Recovery>,
    shared: BTreeSet<String>,
    bytes: usize,
    pub active: Surface,
    pub frame: Option<Frame>,
    pub failed: bool,
}
impl Store {
    /// The containing session owns the root recovery lock; children have their own journal locks.
    pub fn open(root: &str, restore: bool) -> Result<Self, String> {
        let root = if root.is_empty() {
            None
        } else {
            Some(PathBuf::from(root).join("workspace"))
        };
        let mut result = Self {
            root,
            documents: BTreeMap::new(),
            shared: BTreeSet::new(),
            bytes: 0,
            active: Surface::Idle,
            frame: None,
            failed: false,
        };
        if let Some(root) = &result.root {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(root).map_err(|_| STORAGE_ERROR)?;
            if restore {
                let path = root.join("manifest.json");
                if fs::metadata(&path).map_err(|_| CORRUPT)?.len() > 128 * 1024 {
                    return Err(CORRUPT.into());
                }
                let envelope: Envelope =
                    serde_json::from_slice(&fs::read(&path).map_err(|_| CORRUPT)?)
                        .map_err(|_| CORRUPT)?;
                if crc32fast::hash(envelope.data.as_bytes()) != envelope.crc {
                    return Err(CORRUPT.into());
                }
                let manifest: Manifest =
                    serde_json::from_str(&envelope.data).map_err(|_| CORRUPT)?;
                if manifest.version != 1 || manifest.documents.len() > MAX_DOCUMENTS {
                    return Err(CORRUPT.into());
                }
                for entry in manifest.documents {
                    result.check_new(&entry.document, &entry.file)?;
                    let path = result.path(&entry.document);
                    let saved = Recovery::open(&path, &entry.file, true, "", "")?;
                    if saved.id != entry.document || saved.file != entry.file {
                        return Err(CORRUPT.into());
                    }
                    result.bytes += saved.doc.state().len();
                    if result.bytes > MAX_STATE {
                        return Err(CORRUPT.into());
                    }
                    if entry.shared {
                        result.shared.insert(entry.document.clone());
                    }
                    result.documents.insert(entry.document, saved);
                }
            } else {
                result.manifest()?;
            }
        }
        Ok(result)
    }
    fn path(&self, document: &str) -> String {
        self.root.as_ref().map_or_else(String::new, |root| {
            root.join(document).to_string_lossy().into_owned()
        })
    }
    fn check_new(&self, document: &str, file: &str) -> Result<(), String> {
        if !recovery::valid_id(document) || !valid_file(file) {
            return Err("Invalid Jam document path or identity".into());
        }
        if self.documents.len() >= MAX_DOCUMENTS
            || self.documents.contains_key(document)
            || self.documents.values().any(|saved| saved.file == file)
        {
            return Err("Jam document already exists or the workspace limit was reached".into());
        }
        Ok(())
    }
    fn manifest(&self) -> Result<(), String> {
        let Some(root) = &self.root else {
            return Ok(());
        };
        let data = serde_json::to_string(&Manifest {
            version: 1,
            documents: self
                .documents
                .iter()
                .map(|(id, saved)| Entry {
                    document: id.clone(),
                    file: saved.file.clone(),
                    shared: self.shared.contains(id),
                })
                .collect(),
        })
        .map_err(|_| STORAGE_ERROR)?;
        let data = serde_json::to_vec(&Envelope {
            crc: crc32fast::hash(data.as_bytes()),
            data,
        })
        .map_err(|_| STORAGE_ERROR)?;
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(root.join("manifest.next"))
            .map_err(|_| STORAGE_ERROR)?;
        file.write_all(&data)
            .and_then(|_| file.sync_all())
            .map_err(|_| STORAGE_ERROR)?;
        fs::rename(root.join("manifest.next"), root.join("manifest.json"))
            .map_err(|_| STORAGE_ERROR)?;
        #[cfg(unix)]
        fs::File::open(root)
            .and_then(|file| file.sync_all())
            .map_err(|_| STORAGE_ERROR)?;
        Ok(())
    }
    pub fn adopt(&mut self, document: &str, file: &str, state: &str) -> Result<(), String> {
        if self.failed {
            return Err(STORAGE_ERROR.into());
        }
        if !recovery::valid_id(document) || !valid_file(file) {
            return Err("Invalid Jam document path or identity".into());
        }
        let mut candidate = Document::new("")?;
        let previous = if let Some(saved) = self.documents.get(document) {
            if saved.file != file {
                return Err("Jam document identity changed paths".into());
            }
            let old = saved.doc.state();
            if old == state {
                return Ok(());
            }
            candidate.apply(&old)?;
            old.len()
        } else {
            self.check_new(document, file)?;
            0
        };
        candidate.apply(state)?;
        let next = self.bytes - previous + candidate.state().len();
        if next > MAX_STATE {
            return Err("Jam workspace exceeds its document budget".into());
        }
        let result = if let Some(saved) = self.documents.get_mut(document) {
            saved.adopt(document, file, state)
        } else {
            Recovery::open(&self.path(document), file, false, document, state).and_then(|saved| {
                self.documents.insert(document.into(), saved);
                self.manifest()
            })
        };
        if result.is_err() {
            self.failed = true;
        }
        self.bytes = next;
        result
    }
    pub fn accept(&mut self, document: &str, update: &str) -> Result<(), String> {
        if self.failed {
            return Err(STORAGE_ERROR.into());
        }
        let saved = self
            .documents
            .get_mut(document)
            .ok_or("Unknown Jam document")?;
        let previous = saved.doc.state();
        let mut candidate = Document::new("")?;
        candidate.apply(&previous)?;
        candidate.apply(update)?;
        let next = candidate.state();
        if next == previous {
            return Ok(());
        }
        if self.bytes - previous.len() + next.len() > MAX_STATE {
            return Err("Jam workspace exceeds its document budget".into());
        }
        let result = saved.accept(update);
        if result.is_err() {
            self.failed = true;
        }
        self.bytes = self.bytes - previous.len() + next.len();
        result
    }
    pub fn snapshot(&self, document: &str) -> Result<Message, String> {
        let saved = self.documents.get(document).ok_or("Unknown Jam document")?;
        Ok(Message::Document {
            document: document.into(),
            file: saved.file.clone(),
            state: saved.doc.state(),
            vector: saved.doc.vector(),
        })
    }
    pub fn snapshots(&self) -> Vec<Message> {
        self.documents
            .keys()
            .map(|id| self.snapshot(id).unwrap())
            .collect()
    }
    pub fn shared(&self, document: &str) -> bool {
        self.shared.contains(document)
    }
    pub fn presence(
        &self,
        document: &str,
        caret: &str,
        anchor: &str,
        view: &Option<Viewport>,
    ) -> Result<(), String> {
        if caret.len() > 256 || anchor.len() > 256 || !view.as_ref().is_none_or(Viewport::valid) {
            return Err("Invalid Jam position".into());
        }
        let saved = self.documents.get(document).ok_or("Unknown Jam document")?;
        saved.doc.resolve(caret)?;
        saved.doc.resolve(anchor)?;
        if let Some(view) = view {
            saved.doc.resolve(&view.top)?;
        }
        Ok(())
    }
    pub fn activate(&mut self, surface: Surface) -> Result<(), String> {
        if !surface.valid() {
            return Err("Invalid Jam surface".into());
        }
        if let Surface::Code { document } = &surface {
            self.snapshot(document)?;
            if self.shared.insert(document.clone()) {
                if let Err(error) = self.manifest() {
                    self.failed = true;
                    return Err(error);
                }
            }
        }
        self.active = surface;
        self.frame = None;
        Ok(())
    }
    pub fn frame(&mut self, frame: Frame) -> Result<(), String> {
        if !frame.valid()
            || !matches!(&self.active, Surface::Preview { id, .. } if id == &frame.view)
            || self
                .frame
                .as_ref()
                .is_some_and(|previous| previous.sequence >= frame.sequence)
        {
            return Err("Invalid or stale Jam preview frame".into());
        }
        self.frame = Some(frame);
        Ok(())
    }
    pub fn checkpoint(&mut self) -> Result<(), String> {
        if self.failed {
            return Err(STORAGE_ERROR.into());
        }
        for saved in self.documents.values_mut() {
            saved.checkpoint()?;
        }
        self.manifest()
    }
}
