//! One Yrs document per file. Buffered recovery persists privately until an explicit Save.
use crate::{
    error::{Result, SessionError},
    store::FileStore,
};
use futures_util::lock::Mutex as AsyncMutex;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};
use yrs::{
    Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, TextRef, Transact, Update,
    updates::{decoder::Decode, encoder::Encode},
};

const DISK: &[u8] = b"disk";
const LOAD: &[u8] = b"load";
const CLOUD: &[u8] = b"cloud";
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
    cloud: Mutex<Option<crate::cloud::Binding>>,
    cloud_legacy: bool,
    #[cfg(feature="server")] watch:Mutex<Option<Box<dyn crate::cloud::Subscription>>>,
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
    pub document_id:Option<String>,
    /// What the client lacks, given the state vector it sent.
    pub update: Vec<u8>,
    /// The session's state vector, so the client can send back what the session lacks.
    pub vector: Vec<u8>,
    pub text: String,
    pub buffered: bool,
    pub dirty: bool,
    pub cloud_lineage: Option<String>,
    pub cloud_legacy: bool,
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
    cloud: OnceLock<Arc<dyn crate::cloud::Provider>>,
    demo_seed:OnceLock<crate::demo_seed::DemoSeed>,
    cloud_status:Mutex<HashMap<String,Arc<dyn Fn(&str,Option<SessionError>)+Send+Sync>>>,
    #[cfg(feature="server")] link:OnceLock<std::sync::Weak<Self>>,
    #[cfg(feature="server")] watch_jobs:Mutex<HashMap<String,Option<std::sync::Weak<OpenDoc>>>>,
}

impl<S: FileStore> DocHub<S> {
    pub fn new(store: Arc<S>, dirty: Arc<dyn Fn(&str) + Send + Sync>) -> Self {
        Self { store, open: Mutex::new(HashMap::new()), opening: AsyncMutex::new(()), dirty, cloud:OnceLock::new(),demo_seed:OnceLock::new(),cloud_status:Default::default(),#[cfg(feature="server")]link:OnceLock::new(),#[cfg(feature="server")]watch_jobs:Default::default() }
    }

    pub fn set_cloud(&self,provider:Arc<dyn crate::cloud::Provider>){let _=self.cloud.set(provider);}
    pub fn cloud_available(&self)->bool{self.cloud.get().is_some()}
    pub fn set_demo_seed(&self,seed:crate::demo_seed::DemoSeed)->bool {self.demo_seed.set(seed).is_ok()}
    pub fn demo_release(&self)->Option<&str> {self.demo_seed.get().map(|seed|seed.release())}
    #[cfg(feature="server")] pub fn enable_push(self:&Arc<Self>){let _=self.link.set(Arc::downgrade(self));}
    pub fn on_cloud_status(&self,id:String,listener:Arc<dyn Fn(&str,Option<SessionError>)+Send+Sync>){self.cloud_status.lock().unwrap().insert(id,listener);}
    pub fn remove_cloud_status(&self,id:&str){self.cloud_status.lock().unwrap().remove(id);}
    #[cfg(feature="server")] fn cloud_status(&self,path:&str,error:Option<SessionError>){let callbacks:Vec<_>=self.cloud_status.lock().unwrap().values().cloned().collect();for callback in callbacks{callback(path,error.clone());}}
    pub fn refresh_cloud(&self){if let Some(provider)=self.cloud.get(){provider.refresh();}}
    pub fn snapshot(&self,path:&str)->Result<Vec<u8>>{self.get(path).map(|open|state_of(&open.doc)).ok_or_else(||SessionError::new("not-open","The document is not open."))}

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

    pub async fn rename_documents(&self,from:&str,to:&str)->Result<crate::store::DocumentMoveReceipt>{
        let _opening=self.opening.lock().await;
        if self.conflicts(&[from,to],true,None).await? {return Err(SessionError::new("document-open","Close shared documents before moving this file or folder."));}
        self.store.rename_documents(from,to).await
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
                Some(state) if crate::buffer_state::unpack(&state)?.is_some() => Some(self.load(path,true).await?),
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

    async fn load(&self, path: &str, use_cloud:bool) -> Result<Arc<OpenDoc>> {
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
        let saved=self.store.read_state(&format!("doc:{path}")).await?;
        if saved.is_none() {
            if let Some(seed)=self.demo_seed.get().and_then(|seed|seed.graph(path)) {
                doc.transact_mut_with(yrs::Origin::from(LOAD)).apply_update(Update::decode_v1(&seed)
                    .map_err(|_|SessionError::new("demo-seed","The demo source graph is invalid."))?)
                    .map_err(|_|SessionError::new("demo-seed","The demo source graph cannot be applied."))?;
            }
        }
        let mut buffered=false;let mut cloud=None;
        if let Some(saved)=&saved {
            let state=if let Some((baseline,state))=crate::buffer_state::unpack(saved)? {
                if let Some(binding)=baseline.path.as_deref(){if !self.store.matches_recovery_binding(path,binding).await?{return Err(Self::disk_conflict());}}
                if !baseline.accepts(&crate::checkpoint::digest(disk.as_bytes())){return Err(Self::disk_conflict());}
                buffered=true;cloud=baseline.cloud;state
            }else{saved};
            let update=Update::decode_v1(state).map_err(|_|SessionError::new("bad-buffer-state","Stored document recovery is invalid."))?;
            let mut txn=doc.transact_mut_with(yrs::Origin::from(LOAD));
            txn.apply_update(update).map_err(|_|SessionError::new("bad-buffer-state","Stored document recovery cannot be applied."))?;
            if txn.has_missing_updates(){return Err(SessionError::new("bad-buffer-state","Stored document recovery is incomplete."));}
        }
        let cloud_legacy=self.cloud.get().is_some() && saved.is_some() && cloud.is_none();
        if cloud.is_some() && !use_cloud{return Err(SessionError::new("cloud-client-required","Reload this editor to use its cloud history. Previous recovery has been kept."));}
        if cloud.is_some() && self.cloud.get().is_none(){return Err(crate::cloud::lineage());}
        if use_cloud && (saved.is_none() || cloud.is_some()) {
            if let Some(provider)=self.cloud.get(){
                match provider.open(path,&disk,cloud.clone()).await {
                    Ok(Some(opened))=>{
                        opened.binding.validate()?;
                        if cloud.as_ref().is_some_and(|old|old.seed!=opened.binding.seed||old.gateway!=opened.binding.gateway){return Err(crate::cloud::lineage());}
                        let update=Update::decode_v1(&opened.state).map_err(|_|crate::cloud::lineage())?;
                        let mut txn=doc.transact_mut_with(yrs::Origin::from(LOAD));
                        txn.apply_update(update).map_err(|_|crate::cloud::lineage())?;
                        if txn.has_missing_updates(){return Err(crate::cloud::lineage());}
                        drop(txn);cloud=Some(opened.binding);buffered=true;
                    }
                    Ok(None) if cloud.is_none()=>{},
                    Err(error) if cloud.is_some() && crate::cloud::offline(&error)=>{},
                    Err(error)=>return Err(error),
                    _=>return Err(crate::cloud::lineage()),
                }
            }
        }
        if !buffered {apply_diff(&doc,&text,&disk,DISK);}
        let state=state_of(&doc);
        let state=if buffered{crate::buffer_state::pack_cloud(&state,&crate::checkpoint::digest(disk.as_bytes()),None,&self.store.recovery_path(path).await?,cloud.clone())?}else{state};
        self.store.write_state(&format!("doc:{path}"),&state).await?;

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
            OpenDoc { doc: doc.clone(), text: text.clone(), subscribers, last_disk: Mutex::new(disk.clone()), buffered, saving: AsyncMutex::new(()), cloud:Mutex::new(cloud.clone()),cloud_legacy,#[cfg(feature="server")]watch:Default::default() }
        });
        Ok(open)
    }

    /// Opens `path` for `client`, and returns what it needs to catch up. `update` and later updates go to `send`.
    pub async fn attach(&self, path: &str, client: &str, vector: Option<&[u8]>, send: Send_) -> Result<Opened> {
        self.attach_identified(path,client,vector,None,send).await
    }

    /// Checks a returning replica's identity under the same gate as filesystem moves and subscription changes.
    pub async fn attach_identified(&self, path: &str, client: &str, vector: Option<&[u8]>, expected:Option<&str>, send: Send_) -> Result<Opened> {
        self.attach_cloud(path,client,vector,expected,None,send).await
    }

    pub async fn attach_cloud(&self,path:&str,client:&str,vector:Option<&[u8]>,expected:Option<&str>,lineage:Option<&str>,send:Send_)->Result<Opened>{
        self.attach_mode(path,client,vector,expected,lineage,true,send).await
    }

    pub async fn attach_mode(&self,path:&str,client:&str,vector:Option<&[u8]>,expected:Option<&str>,lineage:Option<&str>,use_cloud:bool,send:Send_)->Result<Opened>{
        let from = match vector {
            Some(bytes) => StateVector::decode_v1(bytes).map_err(|_| SessionError::new("bad-request", "The state vector is not valid."))?,
            None => StateVector::default(),
        };
        // Registering a subscriber and releasing the last one share the same gate.
        let _opening = self.opening.lock().await;
        if let Some(id)=expected {
            if self.store.document_identity(path).await?.as_deref()!=Some(id){return Err(SessionError::new("document-changed","The path belongs to a different document. Preserve local recovery and reopen the file."));}
        } else if !from.is_empty() && self.store.path_rebound(path).await? {
            return Err(SessionError::new("identity-required","This path has moved or been replaced. Preserve local recovery and reopen using its document identity."));
        }
        if self.conflicts(&[path],false,Some(path)).await? {return Err(SessionError::new("document-open","This file is already shared through another path."));}
        let open = match self.get(path) {
            Some(open) => open,
            None => {
                if self.open.lock().unwrap().len() >= MAX_DOCUMENTS {
                    return Err(SessionError::new("busy", "This workspace has too many shared documents open. Close a document before opening another."));
                }
                self.load(path,use_cloud).await?
            }
        };
        if !use_cloud && open.cloud.lock().unwrap().is_some(){return Err(SessionError::new("cloud-client-required","Reload this editor to use its cloud history. Previous recovery has been kept."));}
        let cloud_lineage=open.cloud.lock().unwrap().as_ref().map(|binding|binding.lineage().map(str::to_string)).transpose()?;
        if cloud_lineage.is_some() && !from.is_empty() && cloud_lineage.as_deref()!=lineage {return Err(crate::cloud::lineage());}
        if lineage.is_some() && cloud_lineage.as_deref()!=lineage {return Err(crate::cloud::lineage());}
        let document_id=self.store.document_identity(path).await?;
        self.open.lock().unwrap().insert(path.to_string(), open.clone());
        open.subscribers.lock().unwrap().insert(client.to_string(), send);
        #[cfg(feature="server")] if let (Some(link),Some(provider),Some(binding))=(self.link.get(),self.cloud.get(),open.cloud.lock().unwrap().clone()){
            let mut watch=open.watch.lock().unwrap();if watch.is_none(){
                let (link,expected,path)=(link.clone(),Arc::downgrade(&open),path.to_string());
                *watch=provider.watch(binding,Arc::new(move|notice|{if let (Some(hub),Some(open))=(link.upgrade(),expected.upgrade()){
                    if !hub.get(&path).is_some_and(|current|Arc::ptr_eq(&current,&open)){return}
                    match notice{crate::cloud::Notice::Refresh=>hub.queue_watch(path.clone(),Arc::downgrade(&open)),crate::cloud::Notice::Failed(error)=>hub.cloud_status(&path,Some(error))}
                }}));
            }provider.refresh();
        }
        let txn = open.doc.transact();
        let text = open.text.get_string(&txn);
        let dirty = open.buffered && text != *open.last_disk.lock().unwrap();
        Ok(Opened { document_id,update: txn.encode_state_as_update_v1(&from), vector: txn.state_vector().encode_v1(), text, buffered:open.buffered, dirty,cloud_lineage,cloud_legacy:open.cloud_legacy })
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
        let state = crate::buffer_state::pack_cloud(&state, &baseline, None, &self.store.recovery_path(path).await?,open.cloud.lock().unwrap().clone())?;
        self.store.write_state(&format!("doc:{path}"), &state).await
    }

    /// Local recovery precedes cloud publication; the accepted graph excludes edits that arrived during I/O.
    pub async fn sync_cloud(&self,path:&str)->Result<Option<Vec<u8>>>{
        self.cloud_barrier(path,true).await
    }
    async fn cloud_barrier(&self,path:&str,activity:bool)->Result<Option<Vec<u8>>>{
        let Some(open)=self.get(path) else{return Err(SessionError::new("not-open","The document is not open."))};
        if open.cloud.lock().unwrap().is_none(){return Ok(None)}
        if activity{self.refresh_cloud();}
        let _saving=open.saving.lock().await;
        self.persist(path,&open,&state_of(&open.doc),None).await?;
        self.sync_cloud_inner(path,&open).await
    }
    #[cfg(feature="server")]
    fn queue_watch(self:&Arc<Self>,path:String,expected:std::sync::Weak<OpenDoc>){
        {let mut jobs=self.watch_jobs.lock().unwrap();if let Some(pending)=jobs.get_mut(&path){*pending=Some(expected);return}jobs.insert(path.clone(),Some(expected));}
        let hub=self.clone();tokio::spawn(async move{loop{
            let expected={let mut jobs=hub.watch_jobs.lock().unwrap();match jobs.get_mut(&path).and_then(Option::take){Some(expected)=>expected,None=>{jobs.remove(&path);return}}};
            if let Some(open)=expected.upgrade().filter(|open|hub.get(&path).is_some_and(|current|Arc::ptr_eq(&current,open))){
                let result=hub.cloud_barrier(&path,false).await;
                if let Err(error)=&result{if let (Some(provider),Some(binding))=(hub.cloud.get(),open.cloud.lock().unwrap().clone()){provider.failed(binding,error.clone());}}
                hub.cloud_status(&path,result.err());
            }
        }});
    }
    async fn sync_cloud_inner(&self,path:&str,open:&OpenDoc)->Result<Option<Vec<u8>>>{
        let Some(binding)=open.cloud.lock().unwrap().clone() else{return Ok(None)};
        let provider=self.cloud.get().ok_or_else(crate::cloud::lineage)?;
        let from=crate::checkpoint::decode_vector(&binding.vector)?;
        let (captured,update)={let txn=open.doc.transact();
            if !matches!(txn.state_vector().partial_cmp(&from),Some(std::cmp::Ordering::Equal|std::cmp::Ordering::Greater)){return Err(crate::cloud::lineage())}
            (txn.encode_state_as_update_v1(&StateVector::default()),txn.encode_state_as_update_v1(&from))};
        let reply=provider.exchange(binding.clone(),update).await?;
        reply.binding.validate()?;
        if binding.seed!=reply.binding.seed||binding.gateway!=reply.binding.gateway||reply.binding.sequence<binding.sequence{return Err(crate::cloud::lineage())}
        let accepted=Doc::with_options(Options{offset_kind:OffsetKind::Utf16,..Options::default()});
        for state in [&captured,&reply.update]{accepted.transact_mut().apply_update(Update::decode_v1(state).map_err(|_|crate::cloud::lineage())?).map_err(|_|crate::cloud::lineage())?;}
        {let txn=accepted.transact();if txn.has_missing_updates()||txn.state_vector()!=crate::checkpoint::decode_vector(&reply.binding.vector)?{return Err(crate::cloud::lineage())}}
        let accepted=state_of(&accepted);crate::checkpoint::pack(&accepted)?;
        if crate::checkpoint::digest(crate::checkpoint::text(&accepted)?.as_bytes())!=reply.sha256{return Err(crate::cloud::lineage())}
        open.doc.transact_mut_with(yrs::Origin::from(CLOUD)).apply_update(Update::decode_v1(&reply.update).map_err(|_|crate::cloud::lineage())?).map_err(|_|crate::cloud::lineage())?;
        *open.cloud.lock().unwrap()=Some(reply.binding.clone());
        self.persist(path,open,&state_of(&open.doc),None).await?;
        provider.accepted(reply.binding);
        Ok(Some(accepted))
    }
    pub fn journal_from(state:&[u8],vector:&str)->Result<crate::checkpoint::Delta>{
        let from=crate::checkpoint::decode_vector(vector)?;let doc=Doc::new();
        doc.transact_mut().apply_update(Update::decode_v1(state).map_err(|_|crate::cloud::lineage())?).map_err(|_|crate::cloud::lineage())?;
        let txn=doc.transact();if txn.has_missing_updates()||!matches!(txn.state_vector().partial_cmp(&from),Some(std::cmp::Ordering::Equal|std::cmp::Ordering::Greater)){return Err(crate::cloud::lineage())}
        crate::checkpoint::pack_delta(&txn.encode_state_as_update_v1(&from),&txn.state_vector().encode_v1())
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
        let cloud=open.cloud.lock().unwrap().clone();
        let state = crate::buffer_state::pack_cloud(state,&baseline,saving,&self.store.recovery_path(path).await?,cloud)?;
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
        if explicit{self.refresh_cloud();}
        if explicit && open.cloud.lock().unwrap().is_some(){self.persist(path,&open,&state_of(&open.doc),None).await?;}
        let accepted=if explicit {self.sync_cloud_inner(path,&open).await?}else{None};
        let (text,state)=if let Some(state)=accepted{(crate::checkpoint::text(&state)?,state)}else{let txn=open.doc.transact();(open.text.get_string(&txn),txn.encode_state_as_update_v1(&StateVector::default()))};
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
                let cloud=open.cloud.lock().unwrap().clone();
                let intent = crate::buffer_state::pack_cloud(&state, &baseline, Some(&crate::checkpoint::digest(text.as_bytes())), &self.store.recovery_path(path).await?,cloud)?;
                self.store.write_state(&format!("doc:{path}"), &intent).await?;
            }
            self.store.write(path, text.as_bytes()).await?;
            *open.last_disk.lock().unwrap() = text;
        }
        self.persist(path,&open,&state_of(&open.doc),None).await?;
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
