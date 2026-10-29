//! One Yrs document per file. Buffered recovery persists privately until an explicit Save.
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
/// Distinct materialized documents retained by one workspace.
pub const MAX_DOCUMENTS: usize = 512;

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
    buffered: bool,
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
    pub buffered: bool,
    pub dirty: bool,
}

pub struct Saved {
    pub written: bool,
    pub mtime: u64,
    pub state: Option<Vec<u8>>,
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

    async fn conflicts(&self, roots: &[&str], descendants: bool, except: Option<&str>) -> Result<bool> {
        let paths:Vec<_>=self.open.lock().unwrap().keys().filter(|path|Some(path.as_str())!=except).cloned().collect();
        if paths.is_empty() {return Ok(false);}
        let inside=|path:&str,root:&str|path==root || (descendants && path.starts_with(&format!("{root}/")));
        if paths.iter().any(|path|roots.iter().any(|root|inside(path,root))) {return Ok(true);}
        let mut keys=Vec::new();for root in roots {keys.push(self.store.recovery_path(root).await?);}
        for path in paths {
            let path=self.store.recovery_path(&path).await?;
            if keys.iter().any(|root|inside(&path,root)) {return Ok(true);}
        }
        Ok(false)
    }

    /// A path-based document must be released before its file or parent can move.
    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        let _opening = self.opening.lock().await;
        if self.conflicts(&[from,to],true,None).await? {
            return Err(SessionError::new("document-open", "Close shared documents before moving this file or folder."));
        }
        self.store.rename(from, to).await
    }

    /// A direct write becomes a disk-origin edit before its acknowledgement.
    pub async fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        let _opening = self.opening.lock().await;
        if self.conflicts(&[path],false,Some(path)).await? {return Err(SessionError::new("document-open","Close aliased shared documents before writing this file."));}
        let registered = self.get(path);
        let live = registered.is_some();
        let open = match registered {
            Some(open) => Some(open),
            None => match self.store.read_state(&format!("doc:{path}")).await? {
                Some(state) if crate::buffer_state::unpack(&state)?.is_some() => Some(self.load(path).await?),
                _ => None,
            },
        };
        if let Some(open) = open {
            let _saving = open.saving.lock().await;
            if open.buffered && open.text.get_string(&open.doc.transact()) != *open.last_disk.lock().unwrap() {
                return Err(SessionError::new("buffer-dirty", "Save or reconcile the recovered buffer before replacing its file."));
            }
            if open.buffered {self.verify_disk(path,&open).await?;}
            let next = match std::str::from_utf8(data) {
                Ok(next) => next,
                Err(_) if !live => {
                    self.store.write(path,data).await?;
                    return self.store.write_state(&format!("doc:{path}"),&state_of(&open.doc)).await;
                }
                Err(_) => return Err(SessionError::new("not-text","Close this shared text document before replacing it with binary data.")),
            };
            self.store.write(path,data).await?;
            *open.last_disk.lock().unwrap() = next.into();
            apply_diff(&open.doc,&open.text,next,DISK);
            self.persist(path,&open,&state_of(&open.doc),None).await?;
            Ok(())
        } else {
            self.store.write(path,data).await
        }
    }

    /// Removing a shared file must not leave a live buffer able to recreate it.
    pub async fn remove(&self, path: &str, recursive: bool) -> Result<()> {
        let _opening = self.opening.lock().await;
        if self.conflicts(&[path],true,None).await? {
            return Err(SessionError::new("document-open","Close shared documents before removing this file or folder."));
        }
        self.store.remove(path,recursive).await
    }

    async fn load(&self, path: &str) -> Result<Arc<OpenDoc>> {
        match self.store.stat(path).await? {
            Some(entry) if entry.kind != "file" => return Err(SessionError::new("wrong-kind", "That is not a file.")),
            Some(entry) if entry.size > crate::session::MAX_READ => return Err(SessionError::new("too-large", "The file is too large to open as a shared document.")),
            Some(_) => {},
            None => return Err(SessionError::new("not-found", "No such file. Create it before opening a shared document.")),
        }
        let bytes = self.store.read(path).await?;
        if bytes.len() as u64 > crate::session::MAX_READ { return Err(SessionError::new("too-large", "The file is too large to open as a shared document.")); }
        let disk = String::from_utf8(bytes).map_err(|_| SessionError::new("not-text", "The file is not UTF-8 text."))?;
        let doc = Doc::with_options(Options { offset_kind: OffsetKind::Utf16, ..Options::default() });
        let text = doc.get_or_insert_text("text");
        let mut buffered = false;
        if let Some(saved) = self.store.read_state(&format!("doc:{path}")).await? {
            let state = if let Some((baseline,state)) = crate::buffer_state::unpack(&saved)? {
                if let Some(binding) = baseline.path.as_deref() {
                    if binding != self.store.recovery_path(path).await? {return Err(Self::disk_conflict());}
                }
                if !baseline.accepts(&crate::checkpoint::digest(disk.as_bytes())) {
                    return Err(Self::disk_conflict());
                }
                buffered = true;
                state
            } else { &saved };
            let update = Update::decode_v1(state).map_err(|_|SessionError::new("bad-buffer-state","Stored document recovery is invalid."))?;
            let mut txn = doc.transact_mut_with(yrs::Origin::from(LOAD));
            txn.apply_update(update).map_err(|_|SessionError::new("bad-buffer-state","Stored document recovery cannot be applied."))?;
            if txn.has_missing_updates() {return Err(SessionError::new("bad-buffer-state","Stored document recovery is incomplete."));}
        }
        // The file may have changed while the session was away: its text wins, as an edit on top of the saved history.
        if !buffered { apply_diff(&doc, &text, &disk, DISK); }
        let state = state_of(&doc);
        let state = if buffered {crate::buffer_state::pack(&state,&crate::checkpoint::digest(disk.as_bytes()),None,&self.store.recovery_path(path).await?)?} else {state};
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
            OpenDoc { doc: doc.clone(), text: text.clone(), subscribers, last_disk: Mutex::new(disk.clone()), buffered, saving: AsyncMutex::new(()) }
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
                if self.open.lock().unwrap().len() >= MAX_DOCUMENTS {
                    return Err(SessionError::new("busy", "This workspace has too many shared documents open. Close a document before opening another."));
                }
                let open = self.load(path).await?;
                self.open.lock().unwrap().insert(path.to_string(), open.clone());
                open
            }
        };
        open.subscribers.lock().unwrap().insert(client.to_string(), send);
        let txn = open.doc.transact();
        let text = open.text.get_string(&txn);
        let dirty = open.buffered && text != *open.last_disk.lock().unwrap();
        Ok(Opened { update: txn.encode_state_as_update_v1(&from), vector: txn.state_vector().encode_v1(), text, buffered:open.buffered, dirty })
    }

    /// Applies a client's update; the other subscribers get it from the document's update event.
    pub fn receive(&self, path: &str, client: &str, update: &[u8]) -> Result<()> {
        let open = self.get(path).ok_or_else(|| SessionError::new("not-open", "The document is not open."))?;
        let update = Update::decode_v1(update).map_err(|_| SessionError::new("bad-request", "The update is not valid."))?;
        open.doc.transact_mut_with(origin_of(client)).apply_update(update).map_err(|_| SessionError::new("bad-request", "The update does not apply."))?;
        Ok(())
    }

    /// Capture missing recovery state in the same transaction as the edit.
    pub fn receive_journal(&self, path: &str, client: &str, update: &[u8], vector: &str) -> Result<crate::checkpoint::Delta> {
        let from = crate::checkpoint::decode_vector(vector)?;
        let update = Update::decode_v1(update).map_err(|_| SessionError::new("bad-request", "The update is not valid."))?;
        let open = self.get(path).ok_or_else(|| SessionError::new("not-open", "The document is not open."))?;
        let mut txn = open.doc.transact_mut_with(origin_of(client));
        if !matches!(txn.state_vector().partial_cmp(&from), Some(std::cmp::Ordering::Equal | std::cmp::Ordering::Greater)) {
            return Err(SessionError::new("journal-conflict", "The workspace is missing previously acknowledged document history."));
        }
        txn.apply_update(update).map_err(|_| SessionError::new("bad-request", "The update does not apply."))?;
        if txn.has_missing_updates() { return Err(SessionError::new("bad-request", "The document update is missing earlier edits. Reconnect before retrying.")); }
        crate::checkpoint::pack_delta(&txn.encode_state_as_update_v1(&from), &txn.state_vector().encode_v1())
    }

    /// Keep acknowledged edits recoverable on the compute volume before the delayed file flush.
    pub async fn persist_journal(&self, path: &str) -> Result<()> {
        let open = self.get(path).ok_or_else(|| SessionError::new("not-open", "The document is not open."))?;
        let _saving = open.saving.lock().await;
        let state = state_of(&open.doc);
        let baseline = crate::checkpoint::digest(open.last_disk.lock().unwrap().as_bytes());
        let state = crate::buffer_state::pack(&state, &baseline, None, &self.store.recovery_path(path).await?)?;
        self.store.write_state(&format!("doc:{path}"), &state).await
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

    /// Flush recovered buffers privately; ordinary documents also write through to the file.
    pub async fn flush(&self, path: &str) -> Result<(bool, u64)> {
        let saved = self.save_inner(path, false, false).await?;
        Ok((saved.written,saved.mtime))
    }

    pub async fn save(&self, path: &str, checkpoint: bool) -> Result<Saved> {
        self.save_inner(path,checkpoint,true).await
    }

    fn disk_conflict() -> SessionError {
        SessionError::new("recovery-conflict", "The saved file changed. Reconcile it with the recovered buffer before saving.")
    }

    async fn persist(&self, path: &str, open: &OpenDoc, state: &[u8], saving: Option<&str>) -> Result<()> {
        if !open.buffered {return self.store.write_state(&format!("doc:{path}"),state).await;}
        let baseline = crate::checkpoint::digest(open.last_disk.lock().unwrap().as_bytes());
        let state = crate::buffer_state::pack(state,&baseline,saving,&self.store.recovery_path(path).await?)?;
        self.store.write_state(&format!("doc:{path}"),&state).await
    }

    async fn verify_disk(&self, path: &str, open: &OpenDoc) -> Result<()> {
        let entry = self.store.stat(path).await?.ok_or_else(Self::disk_conflict)?;
        if entry.kind != "file" || entry.size > crate::session::MAX_READ {return Err(Self::disk_conflict());}
        let disk = self.store.read(path).await?;
        if disk.as_slice() != open.last_disk.lock().unwrap().as_bytes() {return Err(Self::disk_conflict());}
        Ok(())
    }

    async fn save_inner(&self, path: &str, checkpoint: bool, explicit: bool) -> Result<Saved> {
        let Some(open) = self.get(path) else {
            return Ok(Saved {written:false,mtime:self.store.stat(path).await?.map_or(0, |e| e.mtime),state:None});
        };
        let _saving = open.saving.lock().await;
        let (text,state) = {
            let txn = open.doc.transact();
            (open.text.get_string(&txn),txn.encode_state_as_update_v1(&StateVector::default()))
        };
        if checkpoint && state.len() > crate::checkpoint::MAX_BYTES { return Err(SessionError::new("too-large", "The document checkpoint exceeds the recovery size limit.")); }
        if open.buffered && !explicit {
            self.persist(path,&open,&state,None).await?;
            return Ok(Saved {written:false,mtime:self.store.stat(path).await?.map_or(0,|entry|entry.mtime),state:None});
        }
        if open.buffered {
            self.verify_disk(path,&open).await?;
        }
        let changed = *open.last_disk.lock().unwrap() != text;
        if changed {
            if open.buffered || state.len() <= crate::checkpoint::MAX_BYTES {
                let baseline = crate::checkpoint::digest(open.last_disk.lock().unwrap().as_bytes());
                let intent = crate::buffer_state::pack(&state, &baseline, Some(&crate::checkpoint::digest(text.as_bytes())), &self.store.recovery_path(path).await?)?;
                self.store.write_state(&format!("doc:{path}"), &intent).await?;
            }
            self.store.write(path, text.as_bytes()).await?;
            *open.last_disk.lock().unwrap() = text;
        }
        self.persist(path,&open,&state,None).await?;
        Ok(Saved {written:changed,mtime:self.store.stat(path).await?.map_or(0, |e| e.mtime),state:checkpoint.then_some(state)})
    }

    /// Restore only a released document; its next open must load exactly this graph and text.
    pub async fn restore(&self, path: &str, checkpoint: &crate::checkpoint::Checkpoint) -> Result<u64> {
        let _opening = self.opening.lock().await;
        if self.get(path).is_some() { return Err(SessionError::new("document-open", "Close this shared document before restoring it.")); }
        if self.store.stat(path).await?.is_some_and(|entry|entry.kind!="file") { return Err(SessionError::new("wrong-kind","Restore requires a file path.")); }
        let state = crate::checkpoint::unpack(checkpoint)?;
        let text = crate::checkpoint::text(&state)?;
        self.store.write_state(&format!("doc:{path}"), &state).await?;
        self.store.write(path,text.as_bytes()).await?;
        Ok(self.store.stat(path).await?.map_or(0, |entry| entry.mtime))
    }

    pub async fn restore_buffer(&self, path: &str, checkpoint: &crate::checkpoint::Checkpoint, disk_sha256: &str) -> Result<(u64,bool)> {
        let _opening = self.opening.lock().await;
        if !crate::buffer_state::digest(disk_sha256) {return Err(SessionError::new("bad-request","The saved-file digest is invalid."));}
        if self.conflicts(&[path],false,None).await? {return Err(SessionError::new("document-open","Close aliased shared documents before restoring this buffer."));}
        let state = crate::checkpoint::unpack(checkpoint)?;
        let text = crate::checkpoint::text(&state)?;
        let entry = self.store.stat(path).await?.ok_or_else(Self::disk_conflict)?;
        if entry.kind != "file" || entry.size > crate::session::MAX_READ {return Err(Self::disk_conflict());}
        let disk = self.store.read(path).await?;
        let disk_text = std::str::from_utf8(&disk).map_err(|_|Self::disk_conflict())?;
        if crate::checkpoint::digest(&disk) != disk_sha256 {return Err(Self::disk_conflict());}
        self.store.write_state(&format!("doc:{path}"),&crate::buffer_state::pack(&state,disk_sha256,None,&self.store.recovery_path(path).await?)?).await?;
        Ok((entry.mtime,text != disk_text))
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
        if open.buffered {return;}
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
