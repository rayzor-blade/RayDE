//! Native editor projections reuse session recovery, cloud barriers and per-author Yrs undo.
use crate::{
    docs::DocHub,
    error::{Result, SessionError},
    session::Out,
    store::{FileStore, clean},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use yrs::{
    Doc, GetString, OffsetKind, Options, ReadTxn, Text, TextRef, Transact, UndoManager, Update,
    updates::decoder::Decode,
};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Patch {
    from: u32,
    removed: String,
    inserted: String,
}
fn failure() -> SessionError {
    SessionError::new(
        "editor-sequence",
        "The editor transaction no longer matches its document.",
    )
}
fn blank() -> Doc {
    Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::default()
    })
}
fn apply(doc: &Doc, state: &[u8]) -> Result<()> {
    doc.transact_mut_with("remote")
        .apply_update(Update::decode_v1(state).map_err(|_| failure())?)
        .map_err(|_| failure())?;
    if doc.transact().has_missing_updates() {
        return Err(failure());
    }
    Ok(())
}
fn byte_at(text: &str, offset: u32) -> Result<usize> {
    let mut at = 0;
    for (byte, ch) in text.char_indices() {
        if at == offset {
            return Ok(byte);
        }
        at += ch.len_utf16() as u32;
        if at > offset {
            return Err(failure());
        }
    }
    if at == offset {
        Ok(text.len())
    } else {
        Err(failure())
    }
}
fn difference(before: &str, after: &str) -> Vec<Patch> {
    let mut parts: Vec<Patch> = Vec::new();
    let mut at = 0;
    let mut adjacent = false;
    let diff = similar::TextDiff::configure()
        .timeout(std::time::Duration::from_millis(20))
        .diff_chars(before, after);
    for change in diff.iter_all_changes() {
        let value = change.value();
        if change.tag() == similar::ChangeTag::Equal {
            at += value.encode_utf16().count() as u32;
            adjacent = false;
            continue;
        }
        if !adjacent {
            parts.push(Patch {
                from: at,
                removed: String::new(),
                inserted: String::new(),
            });
            adjacent = true;
        }
        let part = parts.last_mut().unwrap();
        match change.tag() {
            similar::ChangeTag::Delete => {
                part.removed.push_str(value);
                at += value.encode_utf16().count() as u32
            }
            similar::ChangeTag::Insert => part.inserted.push_str(value),
            _ => {}
        }
    }
    parts
}
struct Offer {
    state: Vec<u8>,
    serial: u64,
    epoch: u64,
}
struct View {
    path: String,
    subscriber: String,
    doc: Doc,
    text: TextRef,
    undo: UndoManager,
    epoch: u64,
    serial: u64,
    ready: bool,
    offer: Option<Offer>,
    history_bytes: usize,
}
impl View {
    fn new(path: String, subscriber: String, state: &[u8]) -> Result<Self> {
        let doc = blank();
        let text = doc.get_or_insert_text("text");
        apply(&doc, state)?;
        let mut undo = UndoManager::with_options(yrs::undo::Options {
            capture_timeout_millis: 0,
            ..Default::default()
        });
        undo.expand_scope(&doc, &text);
        undo.include_origin("editor");
        Ok(Self {
            path,
            subscriber,
            doc,
            text,
            undo,
            epoch: 0,
            serial: 0,
            ready: false,
            offer: None,
            history_bytes: 0,
        })
    }
    fn text(&self) -> String {
        self.text.get_string(&self.doc.transact())
    }
    fn snapshot(&self) -> Value {
        json!({"text":self.text(),"epoch":self.epoch,"serial":self.serial})
    }
    fn sequence(&self, r: &Value) -> Result<()> {
        if !self.ready
            || r["epoch"].as_u64() != Some(self.epoch)
            || r["serial"].as_u64() != Some(self.serial + 1)
        {
            Err(failure())
        } else {
            Ok(())
        }
    }
    fn edit(&mut self, r: &Value) -> Result<Vec<u8>> {
        self.sequence(r)?;
        let parts: Vec<Patch> =
            serde_json::from_value(r["parts"].clone()).map_err(|_| failure())?;
        if parts.len() > 4096 {
            return Err(failure());
        }
        let before = self.text();
        let mut last = 0;
        let mut size = before.len();
        let mut cost = 0;
        for part in &parts {
            let from = byte_at(&before, part.from)?;
            let end = from.checked_add(part.removed.len()).ok_or_else(failure)?;
            if from < last || before.get(from..end) != Some(part.removed.as_str()) {
                return Err(failure());
            }
            size = size
                .checked_sub(part.removed.len())
                .and_then(|n| n.checked_add(part.inserted.len()))
                .ok_or_else(failure)?;
            cost += part.removed.len() + part.inserted.len() + 64;
            last = end;
        }
        if size > 1024 * 1024 {
            return Err(SessionError::new(
                "document-limit",
                "Live sync text exceeds its size limit.",
            ));
        }
        if self.history_bytes + cost > 1024 * 1024 || self.undo.undo_stack().len() >= 100 {
            self.undo.clear_all();
            self.history_bytes = 0
        }
        self.history_bytes += cost;
        self.undo.reset();
        let mut txn = self.doc.transact_mut_with("editor");
        for part in parts.iter().rev() {
            if !part.removed.is_empty() {
                self.text.remove_range(
                    &mut txn,
                    part.from,
                    part.removed.encode_utf16().count() as u32,
                )
            }
            if !part.inserted.is_empty() {
                self.text.insert(&mut txn, part.from, &part.inserted)
            }
        }
        self.serial += 1;
        Ok(txn.encode_update_v1())
    }
}

/// One bridge owns its projections; another window can subscribe to the same document hub.
pub struct Editors<S: FileStore> {
    hub: Arc<DocHub<S>>,
    views: Mutex<HashMap<String, View>>,
    opening: tokio::sync::Mutex<()>,
    out: Out,
    closed: AtomicBool,
    serial: std::sync::atomic::AtomicU64,
    syncing: Mutex<HashMap<String, bool>>,
}
impl<S: FileStore> Editors<S> {
    pub fn pending(&self) -> bool {
        !self.syncing.lock().unwrap().is_empty()
    }
    pub fn new(hub: Arc<DocHub<S>>, out: Out) -> Arc<Self> {
        let owner=Arc::new(Self {
            hub,
            views: Mutex::new(HashMap::new()),
            opening: Default::default(),
            out,
            closed: AtomicBool::new(false),
            serial: Default::default(),
            syncing: Default::default(),
        });
        let weak=Arc::downgrade(&owner);owner.hub.on_cloud_status(format!("editor:{:p}",Arc::as_ptr(&owner)),Arc::new(move|path,error|{if let Some(owner)=weak.upgrade(){
            for (handle,_) in owner.views.lock().unwrap().iter().filter(|(_,view)|view.path==path){
                let message=error.as_ref().map_or("",|e|e.message.as_str());(owner.out)(json!({"ev":"view.status","handle":handle,"message":message}).to_string());
                if let Some(error)=&error{if matches!(error.code,"document-lineage"|"recovery-conflict"|"bad-buffer-state"){(owner.out)(json!({"ev":"view.error","handle":handle,"code":error.code,"message":error.message}).to_string());}}
            }
        }}));owner
    }
    pub async fn request(self: &Arc<Self>, op: &str, r: &Value) -> Result<Value> {
        if self.closed.load(Ordering::Acquire) {
            return Err(SessionError::new("closed", "The editor bridge is closed."));
        }
        let handle = r["handle"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 1024)
            .ok_or_else(failure)?;
        if op == "view.open" {
            let _opening = self.opening.lock().await;
            let path = clean(r["path"].as_str().ok_or_else(failure)?)?;
            {
                let views = self.views.lock().unwrap();
                if views.len() >= 256
                    || views.contains_key(handle)
                    || views.values().any(|view| view.path == path)
                {
                    return Err(failure());
                }
            }
            let subscriber = format!(
                "editor:{}:{}",
                Arc::as_ptr(self) as usize,
                self.serial.fetch_add(1, Ordering::Relaxed)
            );
            let weak = Arc::downgrade(self);
            let changed = path.clone();
            let send = Arc::new(move |_: Vec<u8>| {
                if let Some(owner) = weak.upgrade() {
                    let path = changed.clone();
                    tokio::spawn(async move {
                        tokio::task::yield_now().await;
                        owner.project(&path);
                    });
                }
            });
            let opened = match self
                .hub
                .attach_cloud(&path, &subscriber, None, None, None, send)
                .await
            {
                Ok(opened) => opened,
                Err(error) if matches!(error.code, "not-text" | "too-large") => {
                    return Ok(json!({"passthrough":true}));
                }
                Err(error) if crate::cloud::offline(&error) => {
                    return Ok(
                        json!({"passthrough":true,"syncMessage":"Cloud sync unavailable · edits kept locally"}),
                    );
                }
                Err(error) => return Err(error),
            };
            if opened.cloud_lineage.is_none() {
                self.hub.detach(&path, &subscriber);
                self.hub.release(&path).await?;
                return Ok(
                    json!({"passthrough":true,"syncMessage":if opened.cloud_legacy{"Live sync needs recovery reconciliation"}else{""}}),
                );
            }
            if self.closed.load(Ordering::Acquire) {
                self.hub.detach(&path, &subscriber);
                self.hub.release(&path).await?;
                return Err(SessionError::new("closed", "The editor bridge is closed."));
            }
            let view = View::new(path, subscriber, &opened.update)?;
            let mut reply = view.snapshot();
            reply["dirty"] = opened.dirty.into();
            reply["savedText"] = opened.saved_text.into();
            reply["savedRevision"] = opened.saved_version.into();
            self.views.lock().unwrap().insert(handle.into(), view);
            return Ok(reply);
        }
        if op == "view.close" {
            let view = self.views.lock().unwrap().remove(handle);
            if let Some(view) = view {
                self.hub.detach(&view.path, &view.subscriber);
                self.hub.release(&view.path).await?;
            }
            return Ok(json!({}));
        }
        let mut response = json!({});
        let path;
        {
            let mut views = self.views.lock().unwrap();
            let view = views.get_mut(handle).ok_or_else(failure)?;
            path = view.path.clone();
            match op {
                "view.ready" => view.ready = true,
                "view.edit" => {
                    let update = view.edit(r)?;
                    self.hub.receive(&path, &view.subscriber, &update)?;
                }
                "view.undo" => {
                    view.sequence(r)?;
                    let before = view.text();
                    let from = view.doc.transact().state_vector();
                    if r["redo"] == true {
                        view.undo.redo_blocking();
                    } else {
                        view.undo.undo_blocking();
                    }
                    view.serial += 1;
                    let update = view.doc.transact().encode_state_as_update_v1(&from);
                    self.hub.receive(&path, &view.subscriber, &update)?;
                    response = view.snapshot();
                    response["parts"] =
                        serde_json::to_value(difference(&before, &view.text())).unwrap();
                }
                "view.ack" => {
                    let offer = view.offer.take().ok_or_else(failure)?;
                    if r["epoch"].as_u64() != Some(offer.epoch) {
                        view.offer = Some(offer);
                        return Err(failure());
                    }
                    if r["accept"] == true {
                        if offer.serial != view.serial {
                            view.offer = Some(offer);
                            return Err(failure());
                        }
                        apply(&view.doc, &offer.state)?;
                        view.epoch = offer.epoch;
                    }
                }
                "view.save" | "view.sync" => {}
                _ => {
                    return Err(SessionError::new(
                        "bad-request",
                        "Unknown editor operation.",
                    ));
                }
            }
        }
        match op {
            "view.save" => {
                let saved = self.hub.save(&path, true).await?;
                self.project(&path);
                Ok(
                    json!({"written":saved.written,"mtime":saved.mtime,"text":crate::checkpoint::text(&saved.state.unwrap())?,"savedRevision":saved.saved_version}),
                )
            }
            "view.sync" | "view.ready" | "view.edit" | "view.undo" => {
                self.schedule_sync(path);
                Ok(response)
            }
            _ => {
                self.project(&path);
                Ok(response)
            }
        }
    }
    fn schedule_sync(self: &Arc<Self>, path: String) {
        {
            let mut pending = self.syncing.lock().unwrap();
            if let Some(again) = pending.get_mut(&path) {
                *again = true;
                return;
            }
            pending.insert(path.clone(), false);
        }
        let owner = self.clone();
        tokio::spawn(async move {
            loop {
                owner.sync(&path).await;
                let mut pending = owner.syncing.lock().unwrap();
                if !owner.closed.load(Ordering::Acquire) && pending.get(&path) == Some(&true) {
                    pending.insert(path.clone(), false);
                } else {
                    pending.remove(&path);
                    return;
                }
            }
        });
    }
    async fn sync(self: &Arc<Self>, path: &str) {
        let result = self.hub.sync_cloud(path).await;
        let message = match &result {
            Ok(_) => "",
            Err(error) => {
                if error.code == "sync-auth" {
                    "Cloud access expired · reopen workspace"
                } else {
                    "Cloud sync pending · edits kept locally"
                }
            }
        };
        for (handle, _) in self
            .views
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, view)| view.path == path)
        {
            (self.out)(json!({"ev":"view.status","handle":handle,"message":message}).to_string());
            if let Err(error) = &result {
                if matches!(
                    error.code,
                    "document-lineage" | "recovery-conflict" | "bad-buffer-state"
                ) {
                    (self.out)(json!({"ev":"view.error","handle":handle,"code":error.code,"message":error.message}).to_string());
                }
            }
        }
        self.project(path);
    }
    fn project(&self, path: &str) {
        if self.closed.load(Ordering::Acquire) {
            return;
        }
        let Ok(state) = self.hub.snapshot(path) else {
            return;
        };
        for (handle, view) in self
            .views
            .lock()
            .unwrap()
            .iter_mut()
            .filter(|(_, view)| view.path == path)
        {
            if !view.ready || view.offer.is_some() {
                continue;
            }
            let probe = blank();
            if apply(&probe, &state).is_err() {
                continue;
            }
            let before = view.text();
            let next = probe
                .get_or_insert_text("text")
                .get_string(&probe.transact());
            let update = probe
                .transact()
                .encode_state_as_update_v1(&view.doc.transact().state_vector());
            if before == next {
                let _ = apply(&view.doc, &update);
                continue;
            }
            let epoch = view.epoch + 1;
            view.offer = Some(Offer {
                state: update,
                serial: view.serial,
                epoch,
            });
            let (saved_text,saved_revision)=self.hub.saved_baseline(path).unwrap_or_default();
            (self.out)(json!({"ev":"view.remote","handle":handle,"epoch":epoch,"serial":view.serial,"text":next,"parts":difference(&before,&next),"dirty":next!=saved_text,"savedText":saved_text,"savedRevision":saved_revision}).to_string());
        }
    }
    pub async fn close(&self) {
        self.hub.remove_cloud_status(&format!("editor:{:p}",self));
        self.closed.store(true, Ordering::Release);
        let views = std::mem::take(&mut *self.views.lock().unwrap());
        for (_, view) in views {
            self.hub.detach(&view.path, &view.subscriber);
            let _ = self.hub.release(&view.path).await;
        }
    }
}
