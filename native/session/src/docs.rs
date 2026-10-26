//! Text documents open in the session: one Yrs document per file, written back to the workspace once edits settle.
use crate::{
    error::{Result, SessionError},
    store::FileStore,
};
use futures_util::lock::Mutex as AsyncMutex;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use yrs::{
    Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, TextRef, Transact, Update,
    updates::{decoder::Decode, encoder::Encode},
};

const DISK: &[u8] = b"disk";
const LOAD: &[u8] = b"load";

/// Where an update came from, so it is not sent back to its sender and the file is not rewritten for its own text.
fn origin_of(client: &str) -> yrs::Origin {
    yrs::Origin::from(client.as_bytes())
}

type Send_ = Arc<dyn Fn(Vec<u8>) + Send + Sync>;

struct OpenDoc {
    doc: Doc,
    text: TextRef,
    subscribers: Mutex<HashMap<String, Send_>>,
    /// What the file held when the session last wrote or read it, so its own writes are not taken for outside edits.
    last_disk: Mutex<String>,
    saving: AsyncMutex<()>,
}

/// Replaces `text`'s contents with `next` by editing only what differs, so cursors and concurrent edits survive.
/// Offsets are UTF-16 units, as the document counts them, and an edit never cuts a surrogate pair.
fn apply_diff(doc: &Doc, text: &TextRef, next: &str, origin: &[u8]) {
    let current: Vec<u16> = text.get_string(&doc.transact()).encode_utf16().collect();
    let target: Vec<u16> = next.encode_utf16().collect();
    if current == target {
        return;
    }
    let limit = current.len().min(target.len());
    let mut start = 0;
    while start < limit && current[start] == target[start] {
        start += 1;
    }
    if start > 0 && (0xD800..0xDC00).contains(&current[start - 1]) {
        start -= 1;
    }
    let mut end = 0;
    while end < limit - start && current[current.len() - 1 - end] == target[target.len() - 1 - end] {
        end += 1;
    }
    if end > 0 && (0xDC00..0xE000).contains(&current[current.len() - end]) {
        end -= 1;
    }
    let removed = (current.len() - start - end) as u32;
    let inserted = String::from_utf16_lossy(&target[start..target.len() - end]);
    let mut txn = doc.transact_mut_with(yrs::Origin::from(origin));
    if removed > 0 {
        text.remove_range(&mut txn, start as u32, removed);
    }
    if !inserted.is_empty() {
        text.insert(&mut txn, start as u32, &inserted);
    }
}

/// The document's whole state. The read transaction ends here, so none is held across an await.
fn state_of(doc: &Doc) -> Vec<u8> {
    doc.transact().encode_state_as_update_v1(&StateVector::default())
}

pub struct Opened {
    /// What the client lacks, given the state vector it sent.
    pub update: Vec<u8>,
    /// The session's state vector, so the client can send back what the session lacks.
    pub vector: Vec<u8>,
    pub text: String,
}

pub struct DocHub<S: FileStore> {
    store: Arc<S>,
    open: Mutex<HashMap<String, Arc<OpenDoc>>>,
    opening: AsyncMutex<()>,
    /// Called with a path whose document has edits to write; the runner calls `flush` after they settle.
    dirty: Arc<dyn Fn(&str) + Send + Sync>,
}

impl<S: FileStore> DocHub<S> {
    pub fn new(store: Arc<S>, dirty: Arc<dyn Fn(&str) + Send + Sync>) -> Self {
        Self { store, open: Mutex::new(HashMap::new()), opening: AsyncMutex::new(()), dirty }
    }

    fn get(&self, path: &str) -> Option<Arc<OpenDoc>> {
        self.open.lock().unwrap().get(path).cloned()
    }

    /// A path-based document must be released before its file or parent can move.
    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        let _opening = self.opening.lock().await;
        let inside = |path: &str, root: &str| path == root || path.starts_with(&format!("{root}/"));
        if self.open.lock().unwrap().keys().any(|path| inside(path, from) || inside(path, to)) {
            return Err(SessionError::new("document-open", "Close shared documents before moving this file or folder."));
        }
        self.store.rename(from, to).await
    }

    async fn load(&self, path: &str) -> Result<Arc<OpenDoc>> {
        let disk = match self.store.stat(path).await? {
            Some(entry) if entry.kind != "file" => return Err(SessionError::new("wrong-kind", "That is not a file.")),
            Some(_) => String::from_utf8(self.store.read(path).await?).map_err(|_| SessionError::new("not-text", "The file is not UTF-8 text."))?,
            None => String::new(),
        };
        let doc = Doc::with_options(Options { offset_kind: OffsetKind::Utf16, ..Options::default() });
        let text = doc.get_or_insert_text("text");
        if let Some(saved) = self.store.read_state(&format!("doc:{path}")).await? {
            if let Ok(update) = Update::decode_v1(&saved) {
                let _ = doc.transact_mut_with(yrs::Origin::from(LOAD)).apply_update(update);
            }
        }
        // The file may have changed while the session was away: its text wins, as an edit on top of the saved history.
        apply_diff(&doc, &text, &disk, DISK);
        let state = state_of(&doc);
        self.store.write_state(&format!("doc:{path}"), &state).await?;

        let subscribers: Mutex<HashMap<String, Send_>> = Mutex::new(HashMap::new());
        let open = Arc::new_cyclic(|weak: &std::sync::Weak<OpenDoc>| {
            let weak = weak.clone();
            let dirty = self.dirty.clone();
            let name = path.to_string();
            doc.observe_update_v1("session", move |txn, event| {
                    let Some(open) = weak.upgrade() else { return };
                    let origin = txn.origin().map(|o| o.as_ref().to_vec());
                    let sender = origin.as_deref().and_then(|o| std::str::from_utf8(o).ok()).unwrap_or("");
                    for (client, send) in open.subscribers.lock().unwrap().iter() {
                        if client != sender {
                            send(event.update.clone());
                        }
                    }
                    if origin.as_deref() != Some(DISK) && origin.as_deref() != Some(LOAD) {
                        dirty(&name);
                    }
            })
            .expect("a document accepts an update observer");
            OpenDoc { doc: doc.clone(), text: text.clone(), subscribers, last_disk: Mutex::new(disk.clone()), saving: AsyncMutex::new(()) }
        });
        Ok(open)
    }

    /// Opens `path` for `client`, and returns what it needs to catch up. `update` and later updates go to `send`.
    pub async fn attach(&self, path: &str, client: &str, vector: Option<&[u8]>, send: Send_) -> Result<Opened> {
        let from = match vector {
            Some(bytes) => StateVector::decode_v1(bytes).map_err(|_| SessionError::new("bad-request", "The state vector is not valid."))?,
            None => StateVector::default(),
        };
        // Registering a subscriber and releasing the last one share the same gate.
        let _opening = self.opening.lock().await;
        let open = match self.get(path) {
            Some(open) => open,
            None => {
                let open = self.load(path).await?;
                self.open.lock().unwrap().insert(path.to_string(), open.clone());
                open
            }
        };
        open.subscribers.lock().unwrap().insert(client.to_string(), send);
        let txn = open.doc.transact();
        Ok(Opened { update: txn.encode_state_as_update_v1(&from), vector: txn.state_vector().encode_v1(), text: open.text.get_string(&txn) })
    }

    /// Applies a client's update; the other subscribers get it from the document's update event.
    pub fn receive(&self, path: &str, client: &str, update: &[u8]) -> Result<()> {
        let open = self.get(path).ok_or_else(|| SessionError::new("not-open", "The document is not open."))?;
        let update = Update::decode_v1(update).map_err(|_| SessionError::new("bad-request", "The update is not valid."))?;
        open.doc.transact_mut_with(origin_of(client)).apply_update(update).map_err(|_| SessionError::new("bad-request", "The update does not apply."))?;
        Ok(())
    }

    pub fn detach(&self, path: &str, client: &str) {
        if let Some(open) = self.get(path) {
            open.subscribers.lock().unwrap().remove(client);
        }
    }

    /// The paths with no subscriber left, for the runner to flush and release.
    pub fn idle(&self) -> Vec<String> {
        self.open.lock().unwrap().iter().filter(|(_, open)| open.subscribers.lock().unwrap().is_empty()).map(|(path, _)| path.clone()).collect()
    }

    /// Writes the document's text to its file, and its state to the session's, if they changed.
    pub async fn flush(&self, path: &str) -> Result<(bool, u64)> {
        let Some(open) = self.get(path) else {
            return Ok((false, self.store.stat(path).await?.map_or(0, |e| e.mtime)));
        };
        let _saving = open.saving.lock().await;
        let text = open.text.get_string(&open.doc.transact());
        let changed = *open.last_disk.lock().unwrap() != text;
        if changed {
            self.store.write(path, text.as_bytes()).await?;
            *open.last_disk.lock().unwrap() = text;
        }
        let state = state_of(&open.doc);
        self.store.write_state(&format!("doc:{path}"), &state).await?;
        Ok((changed, self.store.stat(path).await?.map_or(0, |e| e.mtime)))
    }

    /// Flushes and releases a document nobody has open.
    pub async fn release(&self, path: &str) -> Result<()> {
        let _opening = self.opening.lock().await;
        if self.get(path).is_some_and(|open| open.subscribers.lock().unwrap().is_empty()) {
            self.flush(path).await?;
            self.open.lock().unwrap().remove(path);
        }
        Ok(())
    }

    pub fn text(&self, path: &str) -> Option<String> {
        self.get(path).map(|open| open.text.get_string(&open.doc.transact()))
    }

    /// The file changed in the workspace: if it is open and the change is not the session's own write, it becomes an edit.
    pub async fn changed(&self, path: &str) {
        let Some(open) = self.get(path) else { return };
        let _saving = open.saving.lock().await;
        let Ok(bytes) = self.store.read(path).await else { return };
        let Ok(disk) = String::from_utf8(bytes) else { return };
        {
            let mut last = open.last_disk.lock().unwrap();
            if *last == disk {
                return;
            }
            *last = disk.clone();
        }
        apply_diff(&open.doc, &open.text, &disk, DISK);
        let state = state_of(&open.doc);
        let _ = self.store.write_state(&format!("doc:{path}"), &state).await;
    }

    pub async fn close(&self) {
        let paths: Vec<String> = self.open.lock().unwrap().keys().cloned().collect();
        for path in paths {
            let _ = self.flush(&path).await;
        }
        self.open.lock().unwrap().clear();
    }
}
