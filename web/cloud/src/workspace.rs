use super::*;
use futures_util::StreamExt;
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
    time::Duration,
};

const MAX_CONNECTIONS: usize = 8;

struct PendingOpen {
    sid: Value,
    ticket: Rc<()>,
    abort: futures_util::future::AbortHandle,
}
type Openings = Rc<RefCell<Vec<PendingOpen>>>;
struct Opening {
    pending: Openings,
    ticket: Rc<()>,
    controller: Option<AbortController>,
}
impl Drop for Opening {
    fn drop(&mut self) {
        if let Some(controller) = self.controller.take() {
            controller.abort();
        }
        self.pending
            .borrow_mut()
            .retain(|opening| !Rc::ptr_eq(&opening.ticket, &self.ticket));
    }
}

#[derive(Default)]
struct Pending {
    closed: bool,
    hello: BTreeSet<String>,
    preview_opens:BTreeSet<String>,
    previews:BTreeSet<String>,
    preview_reads:usize,
    source: Option<String>,
    checkpoints: bool,
    journals: bool,
    file_mutations: bool,
    identities: bool,
    document_requests: BTreeMap<String,(String,bool)>,
    documents: BTreeMap<String,String>,
    serial: u64,
    requests: BTreeMap<String, futures_channel::oneshot::Sender<Value>>,
}
type Backend = (WebSocket, WebSocket, Rc<RefCell<Pending>>);
struct PreviewRead(Rc<RefCell<Pending>>);
impl Drop for PreviewRead {fn drop(&mut self){self.0.borrow_mut().preview_reads-=1;}}
struct RecoveryAdmission {
    count: Rc<Cell<usize>>,
    bytes: Rc<Cell<usize>>,
    size: usize,
    finished: Option<futures_channel::oneshot::Sender<()>>,
}
impl Drop for RecoveryAdmission {
    fn drop(&mut self) {
        self.count.set(self.count.get() - 1);
        self.bytes.set(self.bytes.get() - self.size);
        drop(self.finished.take());
    }
}

pub(crate) async fn deadline<F: std::future::Future>(
    future: F,
    seconds: u64,
) -> std::result::Result<F::Output, ()> {
    match futures_util::future::select(
        Box::pin(future),
        Box::pin(Delay::from(Duration::from_secs(seconds))),
    )
    .await
    {
        futures_util::future::Either::Left((value, _)) => Ok(value),
        _ => Err(()),
    }
}
fn save_failure(id: Value, message: &str) -> Value {
    json!({"id":id,"ok":false,"code":"checkpoint-failed","message":message})
}

fn update_failure(id: Value, message: &str) -> Value {
    json!({"id":id,"ok":false,"code":"journal-failed","message":message})
}

fn filesystem_failure(id: Value, message: &str) -> Value {
    json!({"id":id,"ok":false,"code":"filesystem-recovery-failed","message":message})
}

async fn forward_filesystem(
    gate: Rc<futures_util::lock::Mutex<()>>, checkpoints: Rc<crate::checkpoints::Checkpoints>,
    backend: WebSocket, pending: Rc<RefCell<Pending>>, id: Value, request: Value, expires: u64,
) -> Value {
    let Ok(_guard) = deadline(gate.lock(),20).await else {return filesystem_failure(id,"The recovery queue is busy. Try the file operation again.");};
    if expires < now() {return filesystem_failure(id,"Sign in again before changing files.");}
    let source=pending.borrow().source.clone().filter(|_|pending.borrow().file_mutations && !pending.borrow().closed);
    let Some(source)=source else {return filesystem_failure(id,"Update or reconnect the workspace host before changing files.");};
    let mutation=match checkpoints.mutation_begin(&source,&request).await {Ok(mutation)=>mutation,Err(error)=>return filesystem_failure(id,&error.message)};
    if expires < now() {
        let _ = checkpoints.mutation_refuse(&mutation).await;
        return filesystem_failure(id,"Sign in again before changing files.");
    }
    let result=compute(&backend,&pending,request).await;
    if let Err(error)=checkpoints.mutation_finish(&mutation,result.as_ref().ok()).await {return filesystem_failure(id,&error.message);}
    match result {
        Ok(mut reply)=>{reply["id"]=id;reply["recoveryMutation"]=json!({"id":mutation.id});reply},
        Err(message)=>filesystem_failure(id,message),
    }
}

async fn compute(backend: &WebSocket, pending: &Rc<RefCell<Pending>>, mut request: Value) -> std::result::Result<Value, &'static str> {
    let (sender, receiver) = futures_channel::oneshot::channel();
    let key = {
        let mut pending = pending.borrow_mut();
        if pending.closed { return Err("The workspace disconnected. Reconnect before retrying."); }
        pending.serial = pending.serial.checked_add(1).ok_or("Reconnect before retrying.")?;
        request["id"] = json!(["recovery",pending.serial]);
        let key = request["id"].to_string();
        pending.requests.insert(key.clone(),sender);
        key
    };
    let result = if backend.send(&request).is_err() { Err(()) } else { deadline(receiver,25).await };
    pending.borrow_mut().requests.remove(&key);
    match result {
        Ok(Ok(reply)) => Ok(reply),
        _ => Err("The workspace did not confirm document recovery. Reconnect before retrying."),
    }
}

async fn forward_update(
    gate: Rc<futures_util::lock::Mutex<()>>, checkpoints: Rc<crate::checkpoints::Checkpoints>,
    backend: WebSocket, pending: Rc<RefCell<Pending>>, id: Value, path: String, update: String, document:Option<String>, expires: u64,
) -> Value {
    let Ok(_guard) = deadline(gate.lock(),20).await else { return update_failure(id,"The recovery queue is busy. Reconnect before retrying."); };
    if expires < now() { return update_failure(id,"Sign in again before synchronizing edits."); }
    let source = pending.borrow().source.clone().filter(|_|pending.borrow().journals);
    let Some(source) = source else { return update_failure(id,"Update or reconnect the workspace host before synchronizing durable edits."); };
    let vector = match checkpoints.journal_vector(&path,&source,document.as_deref()).await {
        Ok(vector)=>vector, Err(error)=>return update_failure(id,&error.message),
    };
    let mut request=json!({"op":"doc.update","path":path,"update":update,"journal":true,"vector":vector});
    if let Some(document)=&document {request["documentId"]=json!(document);}
    let mut reply = match compute(&backend,&pending,request).await {
        Ok(reply)=>reply, Err(message)=>return update_failure(id,message),
    };
    reply["id"] = id.clone();
    if reply["ok"] != true { return reply; }
    let delta = serde_json::from_value(reply.as_object_mut().and_then(|reply|reply.remove("journal")).unwrap_or(Value::Null));
    let stored = match delta {
        Ok(delta)=>checkpoints.journal_append(&path,&source,&vector,delta,document.as_deref()).await,
        Err(_)=>Err(bad(502,"The workspace host returned no valid recovery delta.")),
    };
    match stored {
        Ok(record)=>{reply["durableUpdate"] = json!({"id":record.id,"sequence":record.sequence});reply},
        Err(error)=>update_failure(id,&format!("Edits remain in this browser; durable recovery could not be recorded. {}",error.message)),
    }
}

async fn forward_save(
    gate: Rc<futures_util::lock::Mutex<()>>,
    checkpoints: Rc<crate::checkpoints::Checkpoints>,
    backend: WebSocket,
    pending: Rc<RefCell<Pending>>,
    id: Value,
    path: String,
    document:Option<String>,
    expires: u64,
) -> Value {
    let Ok(_guard) = deadline(gate.lock(), 20).await else {
        return save_failure(id, "The recovery queue is busy. Try saving again.");
    };
    if pending.borrow().closed {
        return save_failure(
            id,
            "The workspace disconnected before saving. Reconnect and try again.",
        );
    }
    if expires < now() {
        return save_failure(id, "Sign in again before saving.");
    }
    let Some(source) = pending
        .borrow()
        .source
        .clone()
        .filter(|_| pending.borrow().checkpoints)
    else {
        return save_failure(
            id,
            "Update or reconnect the workspace host before saving durable recovery.",
        );
    };
    let mut request=json!({"op":"doc.save","path":path,"checkpoint":true});
    if let Some(document)=&document {request["documentId"]=json!(document);}
    let mut reply = match compute(&backend,&pending,request).await {
        Ok(reply)=>reply, Err(message)=>return save_failure(id,message),
    };
    reply["id"] = id.clone();
    if reply["ok"] != true { return reply; }
    let checkpoint = serde_json::from_value(reply.as_object_mut().and_then(|reply|reply.remove("checkpoint")).unwrap_or(Value::Null));
    let stored = match checkpoint {
        Ok(checkpoint)=>checkpoints.save_identified(&path,&source,checkpoint,true,document.as_deref()).await,
        Err(_)=>Err(bad(502,"The workspace host returned no valid checkpoint.")),
    };
    match stored {
        Ok(manifest)=>{reply["durable"] = json!({"id":manifest.id,"sha256":manifest.sha256});reply},
        Err(error)=>save_failure(id,&format!("The workspace file was saved, but durable recovery could not be recorded. {}",error.message)),
    }
}

#[durable_object]
pub struct WorkspaceSession {
    state: State,
    env: Env,
    starting: Rc<Cell<bool>>,
    reconnecting: futures_util::lock::Mutex<()>,
    backends: Rc<RefCell<Vec<Backend>>>,
    checkpoints: Rc<crate::checkpoints::Checkpoints>,
    saving: Rc<futures_util::lock::Mutex<()>>,
    save_waiting: Rc<Cell<usize>>,
    queued_bytes: Rc<Cell<usize>>,
    recovery_tail: RefCell<Option<futures_channel::oneshot::Receiver<()>>>,
    connecting: Openings,
}
impl DurableObject for WorkspaceSession {
    fn new(state: State, env: Env) -> Self {
        let checkpoints = Rc::new(crate::checkpoints::Checkpoints::new(state.storage(), env.bucket("WORKSPACE_FILES").ok(), &state.id().to_string()));
        Self {
            state,
            env,
            starting: Rc::new(Cell::new(false)),
            reconnecting: futures_util::lock::Mutex::new(()),
            backends: Rc::new(RefCell::new(Vec::new())),
            checkpoints,
            saving: Rc::new(futures_util::lock::Mutex::new(())),
            save_waiting: Rc::new(Cell::new(0)),
            queued_bytes: Rc::new(Cell::new(0)),
            recovery_tail: RefCell::new(None),
            connecting: Rc::new(RefCell::new(Vec::new())),
        }
    }
    async fn fetch(&self, req: Request) -> Result<Response> {
        finish(self.handle(req).await)
    }
    async fn websocket_message(
        &self,
        ws: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let attachment = ws.deserialize_attachment::<Value>()?.unwrap_or_default();
        let backend = self
            .backends
            .borrow()
            .iter()
            .find(|(client, _, _)| *client == ws)
            .map(|(_, server, handshakes)| (server.clone(), handshakes.clone()));
        let Some((backend, handshakes)) = backend else {
            return ws.close(Some(1011), Some("Reconnect to the workspace"));
        };
        if attachment["expires"].as_u64().unwrap_or(0) < now() {
            self.disconnect(&ws);
            return ws.close(Some(1008), Some("Sign in again"));
        }
        let WebSocketIncomingMessage::String(message) = message else {
            self.disconnect(&ws);
            return ws.close(Some(1008), Some("Invalid session message"));
        };
        if message.len() > 16 * 1024 * 1024 {
            self.disconnect(&ws);
            return ws.close(Some(1009), Some("Message too large"));
        }
        let Ok(mut data) = serde_json::from_str::<Value>(&message) else {
            self.disconnect(&ws);
            return ws.close(Some(1008), Some("Invalid session message"));
        };
        if !data["id"].is_null() && !data["id"].is_string() && !data["id"].is_number() {
            self.disconnect(&ws);
            return ws.close(Some(1008),Some("Invalid session request ID"));
        }
        if data["op"] == "doc.restore" {
            return ws.send(&json!({"id":data["id"],"ok":false,"code":"denied","message":"Document restoration belongs to the workspace service."}));
        }
        if data["op"]=="doc.resolve" || data["op"]=="fs.rename" && data["preserveDocuments"]==true {
            return ws.send(&json!({"id":data["id"],"ok":false,"code":"unsupported","message":"Document-preserving moves require hosted identity recovery support."}));
        }
        if handshakes.borrow().document_requests.contains_key(&data["id"].to_string()) {
            return ws.send(&json!({"id":data["id"],"ok":false,"code":"busy","message":"The document request ID is already in use."}));
        }
        if matches!(data["op"].as_str(),Some("doc.open"|"doc.close")) {
            if let Some(path)=data["path"].as_str().and_then(|p|rayde_session::store::clean(p).ok()).filter(|p|!p.is_empty()&&p.len()<=4096) {
                let mut pending=handshakes.borrow_mut();
                if pending.document_requests.len()>=64 || pending.documents.len()>=512 && !pending.documents.contains_key(&path) {
                    return ws.send(&json!({"id":data["id"],"ok":false,"code":"busy","message":"Too many document requests are open."}));
                }
                pending.document_requests.insert(data["id"].to_string(),(path,data["op"]=="doc.open"));
            }
        }
        if data["op"]=="preview.open" {
            let mut pending=handshakes.borrow_mut();
            if preview_origin(&self.env).is_none() || pending.preview_opens.len()>=8 {
                return ws.send(&json!({"id":data["id"],"ok":false,"code":"preview-unavailable","message":"App preview hosting is not configured."}));
            }
            pending.preview_opens.insert(data["id"].to_string());
        }
        if data["op"]=="preview.close" {if let Some(id)=data["preview"].as_str(){handshakes.borrow_mut().previews.remove(id);}}
        let filesystem=matches!(data["op"].as_str(),Some("fs.write"|"fs.mkdir"|"fs.remove"|"fs.rename"));
        if data["op"] == "doc.save" || data["op"] == "doc.update" || filesystem {
            let editing = data["op"] == "doc.update";
            let id = data["id"].clone();
            let path = data["path"]
                .as_str()
                .and_then(|path| rayde_session::store::clean(path).ok())
                .filter(|path| !path.is_empty() && path.len() <= 4096);
            if id.to_string().len() > 128 || (!filesystem && path.is_none()) {
                return ws.send(&if filesystem {filesystem_failure(id,"The file request is invalid.")} else if editing {update_failure(id,"The document update is invalid.")} else {save_failure(id, "The Save request is invalid.")});
            }
            let filesystem_request=if filesystem {match crate::recovery::normalize(std::mem::take(&mut data)) {Ok(request)=>Some(request),Err(error)=>return ws.send(&filesystem_failure(id,&error.message))}} else {None};
            let update = if editing { data["update"].as_str().map(str::to_owned) } else { None };
            let size = if filesystem {message.len()} else {update.as_ref().map_or(0,String::len)};
            let document=path.as_ref().and_then(|path|handshakes.borrow().documents.get(path).cloned());
            if !filesystem && handshakes.borrow().identities && document.is_none() {
                return ws.send(&json!({"id":id,"ok":false,"code":"not-open","message":"Reopen the document before synchronizing its recovery."}));
            }
            if !filesystem && data.get("documentId").is_some_and(|id|id.as_str()!=document.as_deref()) {
                return ws.send(&json!({"id":id,"ok":false,"code":"document-changed","message":"The path belongs to a different document."}));
            }
            if filesystem && size > rayde_session::session::MAX_MESSAGE-1024 {return ws.send(&filesystem_failure(id,"The file request exceeds the recovery queue limit."));}
            if editing && (update.is_none() || size > rayde_session::checkpoint::MAX_BYTES.div_ceil(3)*4) {
                return ws.send(&update_failure(id,"The document update exceeds the recovery size limit."));
            }
            let budget=if filesystem {16*1024*1024} else {8*1024*1024};
            if self.save_waiting.get() >= 256 || self.queued_bytes.get().saturating_add(size) > budget {
                return ws.send(&if filesystem {filesystem_failure(id,"The recovery queue is busy. Try the file operation again.")} else if editing {update_failure(id,"The recovery queue is busy. Reconnect before retrying.")} else {save_failure(id,"Too many saves are waiting. Try saving again.")});
            }
            self.save_waiting.set(self.save_waiting.get() + 1);
            self.queued_bytes.set(self.queued_bytes.get() + size);
            // Reserve FIFO order before yielding; dependent edits must reach compute in arrival order.
            let (finished,next) = futures_channel::oneshot::channel();
            let previous = self.recovery_tail.replace(Some(next));
            let admission = RecoveryAdmission { count:self.save_waiting.clone(), bytes:self.queued_bytes.clone(), size, finished:Some(finished) };
            let gate = self.saving.clone();
            let checkpoints = self.checkpoints.clone();
            let expires = attachment["expires"].as_u64().unwrap_or(0);
            drop(data);
            drop(message);
            self.state.wait_until(async move {
                let timed_out = match previous {Some(previous)=>deadline(previous,20).await.is_err(),None=>false};
                let reply = if timed_out {
                    if filesystem {filesystem_failure(id,"The recovery queue is busy. Try the file operation again.")} else if editing {update_failure(id,"The recovery queue is busy. Reconnect before retrying.")} else {save_failure(id,"The recovery queue is busy. Try saving again.")}
                } else if filesystem {
                    forward_filesystem(gate,checkpoints,backend,handshakes,id,filesystem_request.unwrap(),expires).await
                } else if editing {
                    forward_update(gate,checkpoints,backend,handshakes,id,path.unwrap(),update.unwrap(),document,expires).await
                } else {
                    forward_save(gate,checkpoints,backend,handshakes,id,path.unwrap(),document,expires).await
                };
                let _ = ws.send(&reply);
                drop(admission);
            });
            return Ok(());
        }
        if data["op"] == "hello" {
            {
                let mut pending = handshakes.borrow_mut();
                if pending.hello.len() >= 64 {
                    drop(pending);
                    self.disconnect(&ws);
                    return ws.close(Some(1008), Some("Too many session handshakes"));
                }
                let id = data["id"].to_string();
                if id.len() > 128 {
                    drop(pending);
                    self.disconnect(&ws);
                    return ws.close(Some(1008), Some("Invalid session request ID"));
                }
                pending.hello.insert(id);
            }
            let value = self
                .state
                .storage()
                .get::<Value>("workspace")
                .await?
                .unwrap_or_default();
            data["token"] = value["connection"]["token"].clone();
        }
        backend.send(&data)
    }
    async fn websocket_close(
        &self,
        ws: WebSocket,
        _code: usize,
        _reason: String,
        _clean: bool,
    ) -> Result<()> {
        self.disconnect(&ws);
        Ok(())
    }
    async fn websocket_error(&self, ws: WebSocket, _error: Error) -> Result<()> {
        self.disconnect(&ws);
        Ok(())
    }
    async fn alarm(&self) -> Result<Response> {
        let mut next = u64::MAX;
        for ws in self.state.get_websockets() {
            let value = ws.deserialize_attachment::<Value>()?.unwrap_or_default();
            let expires = value["expires"].as_u64().unwrap_or(0);
            if expires <= now() {
                self.disconnect(&ws);
                let _ = ws.close(Some(1008), Some("Sign in again"));
            } else {
                next = next.min(expires);
            }
        }
        if next != u64::MAX {
            self.state
                .storage()
                .set_alarm(Duration::from_millis(next.saturating_sub(now())))
                .await?;
        }
        Response::empty()
    }
}
impl WorkspaceSession {
    async fn preview_resource(&self,id:&str,path:&str)->AppResult<Response> {
        use base64::engine::general_purpose::STANDARD;
        if !opaque(id) || rayde_session::store::clean(path).is_err(){return Err(bad(404,"This app preview is unavailable."));}
        let connection=self.backends.borrow().iter().find(|(_,_,pending)|!pending.borrow().closed&&pending.borrow().previews.contains(id)).cloned();
        let (client,backend,pending)=connection.ok_or_else(||bad(404,"This app preview is closed."))?;
        if pending.borrow().preview_reads>=16{return Err(bad(503,"The preview resource queue is full."));}
        pending.borrow_mut().preview_reads+=1;
        let admission=PreviewRead(pending.clone());
        let expires=client.deserialize_attachment::<Value>()?.and_then(|value|value["expires"].as_u64()).unwrap_or(0);
        if expires<=now(){return Err(bad(404,"This app preview is closed."));}
        let first=compute(&backend,&pending,json!({"op":"preview.read","preview":id,"path":path,"offset":0,"length":524288})).await.map_err(|_|bad(502,"The preview host did not respond."))?;
        if first["ok"]!=true{return Err(bad(404,"This preview file is unavailable."));}
        let size=first["size"].as_u64().filter(|size|*size<=64*1024*1024).ok_or_else(||bad(502,"The preview file is too large."))?;
        let mime=first["mime"].as_str().unwrap_or("application/octet-stream").to_owned();
        let initial=STANDARD.decode(first["data"].as_str().unwrap_or("")).map_err(|_|bad(502,"Invalid preview artifact."))?;
        let id=id.to_owned();let path=path.to_owned();
        let stream=futures_util::stream::try_unfold((Some(initial),0u64,backend,pending,admission),move |(initial,offset,backend,pending,admission)| {
            let id=id.clone();let path=path.clone();
            async move {
                if pending.borrow().closed || !pending.borrow().previews.contains(&id) || expires<=now(){return Err(worker::Error::RustError("The app preview closed.".into()));}
                if offset>=size && initial.is_none(){return Ok(None);}
                let bytes=if let Some(bytes)=initial {bytes}else{
                    let reply=compute(&backend,&pending,json!({"op":"preview.read","preview":id,"path":path,"offset":offset,"length":524288})).await.map_err(|message|worker::Error::RustError(message.into()))?;
                    if reply["ok"]!=true||reply["size"]!=size||reply["offset"]!=offset{return Err(worker::Error::RustError("The preview artifact changed.".into()));}
                    STANDARD.decode(reply["data"].as_str().unwrap_or("")).map_err(|_|worker::Error::RustError("Invalid preview artifact.".into()))?
                };
                let next=offset+bytes.len() as u64;
                if next>size || next==offset && size!=0{return Err(worker::Error::RustError("Invalid preview artifact length.".into()));}
                Ok(Some((bytes,(None,next,backend,pending,admission))))
            }
        });
        let headers=Headers::new();
        for (name,value) in [("Content-Type",mime.as_str()),("Cache-Control","no-store"),("X-Content-Type-Options","nosniff"),("Cross-Origin-Opener-Policy","same-origin"),("Cross-Origin-Embedder-Policy","require-corp"),("Cross-Origin-Resource-Policy","cross-origin")] {headers.set(name,value)?;}
        Ok(Response::from_stream(stream)?.with_headers(headers))
    }
    fn disconnect(&self, ws: &WebSocket) {
        self.backends
            .borrow_mut()
            .retain(|(client, backend, pending)| {
                if client == ws {
                    pending.borrow_mut().closed = true;
                    pending.borrow_mut().requests.clear();
                    let _ = backend.close(Some(1000), Some("Closed"));
                    false
                } else {
                    true
                }
            });
    }
    async fn handle(&self, mut req: Request) -> AppResult<Response> {
        let request_path=req.path();
        if let Some(path)=request_path.strip_prefix("/preview/") {
            let (id,path)=path.split_once('/').ok_or_else(||bad(404,"This app preview is unavailable."))?;
            return self.preview_resource(id,path).await;
        }
        let data: Value = if req.path() == "/socket" {
            serde_json::from_str(&req.headers().get("X-RayDE-Identity")?.unwrap_or_default())
                .map_err(|_| bad(403, "The request could not be verified."))?
        } else {
            req.json().await?
        };
        let storage = self.state.storage();
        let mut value = storage.get::<Value>("workspace").await?;
        if req.path() == "/disconnect" {
            for opening in self
                .connecting
                .borrow()
                .iter()
                .filter(|opening| opening.sid == data["sid"])
            {
                opening.abort.abort();
            }
            for ws in self.state.get_websockets() {
                if ws
                    .deserialize_attachment::<Value>()?
                    .is_some_and(|v| v["sid"] == data["sid"])
                {
                    self.disconnect(&ws);
                    let _ = ws.close(Some(1008), Some("Signed out"));
                }
            }
            return Ok(reply(&json!({}), 200)?);
        }
        if value.as_ref().is_some_and(|v| v["owner"] != data["owner"]) {
            return Err(bad(403, "This workspace belongs to another account."));
        }
        if req.path() == "/checkpoint"
            || req.path() == "/checkpoints"
            || req.path() == "/checkpoint/import"
            || req.path() == "/journal"
            || req.path() == "/journals"
            || req.path() == "/recovery/plan"
            || req.path() == "/recovery/file"
        {
            if value.is_none() {
                return Err(bad(404, "Workspace not found."));
            }
            let result = if req.path() == "/recovery/file" {
                let mutation = data["mutation"].as_u64().ok_or_else(||bad(400,"The file mutation is invalid."))?;
                let revision = data["revision"].as_u64().ok_or_else(||bad(400,"The recovery revision is invalid."))?;
                self.checkpoints.file_payload(text(&data,"source")?,mutation,revision).await?
            } else if req.path() == "/recovery/plan" {
                let expected=match data.get("revision") {None|Some(Value::Null)=>None,Some(value)=>Some(value.as_u64().ok_or_else(||bad(400,"The recovery revision is invalid."))?)};
                self.checkpoints.recovery_plan(text(&data,"source")?,expected).await?
            } else if req.path() == "/journals" {
                self.checkpoints.journal_list().await?
            } else if req.path() == "/journal" {
                self.checkpoints.journal_get(text(&data,"id")?).await?
            } else if req.path() == "/checkpoints" {
                self.checkpoints.list().await?
            } else if req.path() == "/checkpoint/import" {
                let checkpoint = serde_json::from_value(data["checkpoint"].clone())
                    .map_err(|_| bad(400, "The checkpoint is invalid."))?;
                json!(
                    self.checkpoints
                        .save_identified(text(&data, "path")?, text(&data, "source")?, checkpoint,false,data.get("documentId").map(|value|value.as_str().ok_or_else(||bad(400,"The document identity is invalid."))).transpose()?)
                        .await?
                )
            } else {
                self.checkpoints.get(text(&data, "id")?).await?
            };
            return Ok(reply(&result, 200)?);
        }
        if req.path() == "/socket" {
            let record = value.ok_or_else(|| bad(404, "Workspace not found."))?;
            if record["status"] != "ready" {
                return Err(bad(409, "The workspace is still starting."));
            }
            if self.backends.borrow().len() + self.connecting.borrow().len() >= MAX_CONNECTIONS {
                return Err(bad(
                    429,
                    "This workspace has too many connections. Close another editor and reconnect.",
                ));
            }
            let (abort, registration) = futures_util::future::AbortHandle::new_pair();
            let ticket = Rc::new(());
            self.connecting.borrow_mut().push(PendingOpen {
                sid: data["sid"].clone(),
                ticket: ticket.clone(),
                abort,
            });
            let controller = AbortController::default();
            let signal = controller.signal();
            let mut admission = Opening {
                pending: self.connecting.clone(),
                ticket,
                controller: Some(controller),
            };
            let connect = async {
                let mut current = storage.get::<Value>("workspace").await?.ok_or_else(||bad(404,"Workspace not found."))?;
                let mut response = connect_backend(&self.env, &current["connection"], &data, &signal).await;
                let mut recovery = None;
                if current["connection"]["recoverable"] == true && !response.as_ref().is_ok_and(|response|response.status_code() == 101) {
                    recovery = Some(self.reconnecting.lock().await);
                    current = storage.get::<Value>("workspace").await?.ok_or_else(||bad(404,"Workspace not found."))?;
                    response = connect_backend(&self.env, &current["connection"], &data, &signal).await;
                    if !response.as_ref().is_ok_and(|response|response.status_code() == 101) {
                        let connection = deadline(prepare(&self.env, &current, data["access"].clone()),150).await
                            .map_err(|_|bad(504,"Workspace recovery timed out. Try reconnecting."))??;
                        current["connection"] = connection;
                        storage.put("workspace", &current).await?;
                        response = connect_backend(&self.env, &current["connection"], &data, &signal).await;
                    }
                }
                let response = response?;
                if recovery.is_none() {
                    recovery = Some(self.reconnecting.lock().await);
                    current = storage.get::<Value>("workspace").await?.ok_or_else(||bad(404,"Workspace not found."))?;
                }
                let _recovery = recovery;
                if let Some(token) = response.headers().get("X-RayDE-Token")? {
                    let generation = response.headers().get("X-RayDE-Generation")?.and_then(|value|value.parse::<u64>().ok())
                        .filter(|generation| *generation > 0).ok_or_else(||bad(502,"Invalid compute generation."))?;
                    if token.len()!=64 || !token.bytes().all(|byte|byte.is_ascii_hexdigit()) || current["connection"]["generation"].as_u64().is_some_and(|old|generation<old) {
                        if let Some(socket) = response.websocket() {let _ = socket.close(Some(1008),Some("Stale compute generation"));}
                        return Err(bad(409,"The workspace compute generation needs reconciliation."));
                    }
                    if current["connection"]["token"] != token || current["connection"]["generation"] != generation {
                        current["connection"]["token"] = json!(token);
                        current["connection"]["generation"] = json!(generation);
                        storage.put("workspace", &current).await?;
                    }
                }
                Ok::<_,Failure>((current,response))
            };
            let (record,response) = futures_util::future::Abortable::new(deadline(connect,170),registration).await
                .map_err(|_|bad(403,"The account signed out before connecting."))?
                .map_err(|_|bad(504,"The workspace did not respond. Reconnect and try again."))??;
            let backend = response
                .websocket()
                .ok_or_else(|| bad(502, "The workspace could not be reached."))?;
            backend.accept()?;
            let pair = WebSocketPair::new()?;
            let handshakes = Rc::new(RefCell::new(Pending::default()));
            let authority = format!("cloud:{}", self.state.id());
            let workspace = record["id"].clone();
            let principal = format!("account:{}", data["owner"]);
            let preview_origin=preview_origin(&self.env);
            self.state.accept_web_socket(&pair.server);
            let mut attachment = data.clone();
            if let Some(fields) = attachment.as_object_mut() {fields.remove("access");}
            pair.server.serialize_attachment(&attachment)?;
            self.backends.borrow_mut().push((
                pair.server.clone(),
                backend.clone(),
                handshakes.clone(),
            ));
            admission.controller = None;
            drop(admission);
            let client = pair.server.clone();
            let backends = self.backends.clone();
            self.state.wait_until(async move {
                if let Ok(mut events) = backend.events() {
                    while let Some(event) = events.next().await {
                        match event {
                            Ok(WebsocketEvent::Message(message)) => {
                                if let Some(text) = message.text() {
                                    let mut text = text;
                                    if let Ok(mut reply) = serde_json::from_str::<Value>(&text) {
                                        let pending = handshakes.borrow_mut().requests.remove(&reply["id"].to_string());
                                        if let Some(pending) = pending {
                                            let _ = pending.send(reply);
                                            continue;
                                        }
                                        // Late checkpoint replies are internal payloads, including after a Save timeout.
                                        if reply.get("checkpoint").is_some() || reply.get("journal").is_some() || reply["id"].is_array() {continue;}
                                        let document_request=handshakes.borrow_mut().document_requests.remove(&reply["id"].to_string());
                                        if let Some((path,opening))=document_request {
                                            if reply["ok"]==true {
                                                if opening {
                                                    if let Some(id)=reply["documentId"].as_str().filter(|id|handshakes.borrow().identities && crate::checkpoints::document_id(id)) {
                                                        handshakes.borrow_mut().documents.insert(path,id.into());
                                                    }
                                                } else {handshakes.borrow_mut().documents.remove(&path);}
                                            }
                                        }
                                        if handshakes.borrow_mut().preview_opens.remove(&reply["id"].to_string()) && reply["ok"]==true {
                                            if let (Some(origin),Some(id))=(&preview_origin,reply["preview"].as_str().filter(|id|opaque(id))) {
                                                let id=id.to_owned();
                                                handshakes.borrow_mut().previews.insert(id.clone());
                                                reply["url"]=json!(format!("{origin}/previews/{}/{id}/index.html",workspace.as_str().unwrap_or_default()));
                                                text=reply.to_string();
                                            }
                                        }
                                        if reply.get("id").is_some()
                                            && handshakes.borrow_mut().hello.remove(&reply["id"].to_string())
                                            && reply["ok"] == true
                                        {
                                            // Compute still owns CRDT state: a fresh disk must not replay an older replica's baseline.
                                            let backend = reply["cacheIdentity"].clone();
                                            let valid = backend["version"] == 1
                                                && ["authority", "workspace"].iter().all(|field|
                                                    backend[field].as_str().is_some_and(|value|
                                                        !value.is_empty() && value.len() <= 128));
                                            {
                                                let mut pending = handshakes.borrow_mut();
                                                pending.source = valid.then(||hash(&json!([backend["authority"],backend["workspace"]]).to_string()));
                                                pending.checkpoints = reply["checkpoints"]==1;
                                                pending.journals = reply["journals"]==1;
                                                pending.file_mutations = reply["fileMutations"]==1;
                                                pending.identities = reply["documentIdentities"]==1;
                                            }
                                            reply["durableCheckpoints"] = json!(valid && reply["checkpoints"]==1);
                                            reply["durableUpdates"] = json!(valid && reply["journals"]==1);
                                            reply["documentIdentities"] = json!(0);
                                            reply["closedDocumentMoves"] = json!(0);
                                            reply["appPreviews"]=json!(reply["appPreviews"]==true && preview_origin.is_some());
                                            reply["cacheIdentity"] = if valid {
                                                json!({
                                                    "version": 1,
                                                    "authority": json!([authority, backend["authority"], backend["workspace"]]).to_string(),
                                                    "workspace": workspace,
                                                    "principal": principal
                                                })
                                            } else { Value::Null };
                                            text = reply.to_string();
                                        }
                                    }
                                    if client.send_with_str(&text).is_err() {
                                        break;
                                    }
                                } else if let Some(bytes) = message.bytes() {
                                    if client.send_with_bytes(bytes).is_err() {
                                        break;
                                    }
                                }
                            }
                            _ => break,
                        }
                    }
                }
                handshakes.borrow_mut().closed=true;
                handshakes.borrow_mut().requests.clear();
                backends.borrow_mut().retain(|(ws, _, _)| *ws != client);
                let _ = client.close(Some(1011), Some("Workspace disconnected"));
                let _ = backend.close(Some(1000), Some("Closed"));
            });
            let earliest = self
                .state
                .get_websockets()
                .iter()
                .filter_map(|ws| {
                    ws.deserialize_attachment::<Value>()
                        .ok()
                        .flatten()
                        .and_then(|v| v["expires"].as_u64())
                })
                .min()
                .unwrap_or(now());
            let duration = data["expires"]
                .as_u64()
                .unwrap_or(now())
                .min(earliest)
                .saturating_sub(now());
            storage.set_alarm(Duration::from_millis(duration)).await?;
            return Ok(Response::from_websocket(pair.client)?);
        }
        if req.path() == "/open" {
            if value.is_none() {
                let record = json!({"id":data["id"],"owner":data["owner"],"repository":data["repository"],"status":"preparing","created":now()});
                storage.put("workspace", &record).await?;
                value = Some(record);
            }
            let mut record = value.unwrap();
            if record["status"] == "failed" {
                record["status"] = json!("preparing");
                record["message"] = Value::Null;
                storage.put("workspace", &record).await?;
            }
            if record["status"] != "ready" && !self.starting.replace(true) {
                // A provider reuses this workspace ID if an interrupted request is retried.
                let starting = self.starting.clone();
                let env = self.env.clone();
                let storage = self.state.storage();
                let mut next = record.clone();
                let access = data["access"].clone();
                self.state.wait_until(async move {
                    match prepare(&env, &next, access).await {
                        Ok(connection) => {
                            next["connection"] = connection;
                            next["status"] = json!("ready");
                            next["message"] = Value::Null;
                        }
                        Err(error) => {
                            next["status"] = json!("failed");
                            next["message"] = json!(error.message);
                        }
                    }
                    let _ = storage.put("workspace", next).await;
                    starting.set(false);
                });
            }
            return Ok(reply(&public_workspace(&record), 200)?);
        }
        if req.path() == "/state" {
            let record = value.ok_or_else(|| bad(404, "Workspace not found."))?;
            return Ok(reply(&public_workspace(&record), 200)?);
        }
        Err(bad(404, "Unknown workspace operation."))
    }
}
async fn prepare(env: &Env, value: &Value, access: Value) -> AppResult<Value> {
    let url = config(env, "RUNNER_URL").unwrap_or_else(|| "https://runner.internal".into());
    let endpoint = Url::parse(&url).map_err(|_| bad(503, "Invalid runner configuration."))?;
    if endpoint.scheme() != "https" && config(env, "LOCAL_DEV").as_deref() != Some("1") {
        return Err(bad(503, "The runner requires HTTPS."));
    }
    let mut req = request(
        &format!("{}/workspaces/open", url.trim_end_matches('/')),
        &json!({"id":value["id"],"owner":value["owner"],"repository":value["repository"],"checkout":{"accessToken":access}}),
    )?;
    req.headers_mut()?.set(
        "Authorization",
        &format!(
            "Bearer {}",
            config(env, "RUNNER_SECRET")
                .ok_or_else(|| bad(503, "Workspace compute is not configured."))?
        ),
    )?;
    let mut response = if let Ok(binding) = env.service("RUNNER") {
        binding.fetch_request(req).await?
    } else {
        Fetch::Request(req).send().await?
    };
    if response.status_code() >= 400 {
        return Err(bad(502, "The workspace could not be prepared."));
    }
    let connection: Value = response.json().await?;
    let endpoint = Url::parse(text(&connection, "url")?)
        .map_err(|_| bad(502, "Invalid workspace endpoint."))?;
    if endpoint.scheme() != "wss"
        && !(config(env, "LOCAL_DEV").as_deref() == Some("1") && endpoint.scheme() == "ws")
    {
        return Err(bad(502, "The workspace requires a secure connection."));
    }
    let token =
        text(&connection, "token").map_err(|_| bad(502, "The workspace credential is missing."))?;
    if token.is_empty() || token.len() > 4096 {
        return Err(bad(502, "Invalid workspace credential."));
    }
    let project = connection["project"]
        .as_str()
        .filter(|p| !p.starts_with('/') && !p.split('/').any(|part| part == ".."));
    Ok(json!({"url":endpoint.as_str(),"token":token,"project":project,"generation":connection["generation"],"toolchain":connection["toolchain"],"recoverable":connection["recoverable"]==true}))
}

async fn connect_backend(env: &Env, connection: &Value, data: &Value, signal: &worker::AbortSignal) -> AppResult<Response> {
    let mut endpoint = Url::parse(text(connection,"url")?).map_err(|_|bad(502,"Invalid workspace endpoint."))?;
    let scheme = if endpoint.scheme()=="wss" {"https"} else {"http"};
    endpoint.set_scheme(scheme).map_err(|_|bad(502,"Invalid workspace endpoint."))?;
    let headers = Headers::new();
    headers.set("Upgrade","websocket")?;
    headers.set("Origin",text(data,"origin")?)?;
    if let Some(secret) = config(env,"RUNNER_SECRET") {headers.set("Authorization",&format!("Bearer {secret}"))?;}
    let fetch=Fetch::Request(Request::new_with_init(endpoint.as_str(),RequestInit::new().with_headers(headers))?);
    deadline(fetch.send_with_signal(signal),10).await
        .map_err(|_|bad(504,"The workspace did not respond. Reconnect and try again."))?.map_err(Failure::from)
}
