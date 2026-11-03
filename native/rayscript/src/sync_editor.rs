//! Bounded native channels carry the same editor protocol as the browser bridge.
use rayde_session::{desktop, dir_store::DirStore, editor::Editors};
use rayde_sync::client::Config;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    sync::{
        Arc, Condvar, Mutex, OnceLock,
        atomic::{AtomicI32, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::mpsc;

const MAX_BYTES: usize = 32 * 1024 * 1024;
struct Queue {
    messages: VecDeque<String>,
    bytes: usize,
    closed: bool,
}
struct Bridge {
    queue: Mutex<Queue>,
    wake: Condvar,
    send: Mutex<Option<mpsc::Sender<String>>>,
    queued: AtomicUsize,
}
static NEXT: AtomicI32 = AtomicI32::new(1);
static BRIDGES: Mutex<Option<HashMap<i32, Arc<Bridge>>>> = Mutex::new(None);
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(8)
            .enable_all()
            .build()
            .expect("native sync workers")
    })
}
fn bridge(id: i32) -> Option<Arc<Bridge>> {
    BRIDGES.lock().unwrap().as_ref()?.get(&id).cloned()
}
impl Bridge {
    fn emit(&self, message: String) {
        let mut queue = self.queue.lock().unwrap();
        if queue.closed {
            return;
        }
        if queue.bytes + message.len() > MAX_BYTES {
            queue.closed = true;
            self.send.lock().unwrap().take();
        } else {
            queue.bytes += message.len();
            queue.messages.push_back(message)
        }
        self.wake.notify_all();
    }
    fn reply(&self, id: Value, result: rayde_session::error::Result<Value>) {
        let mut reply = match result {
            Ok(reply) => reply,
            Err(error) => json!({"ok":false,"code":error.code,"message":error.message}),
        };
        if reply["ok"].is_null() {
            reply["ok"] = true.into()
        }
        reply["id"] = id;
        self.emit(reply.to_string());
    }
}
pub fn open(config: &str) -> i32 {
    let Ok(config) = serde_json::from_str::<Config>(config) else {
        return -1;
    };
    let (send, receive) = mpsc::channel::<String>(1024);
    let bridge = Arc::new(Bridge {
        queue: Mutex::new(Queue {
            messages: VecDeque::new(),
            bytes: 0,
            closed: false,
        }),
        wake: Condvar::new(),
        send: Mutex::new(Some(send)),
        queued: AtomicUsize::new(0),
    });
    let mut bridges = BRIDGES.lock().unwrap();
    let bridges = bridges.get_or_insert_default();
    if bridges.len() >= 32 {
        return -1;
    }
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    bridges.insert(id, bridge.clone());
    runtime().spawn(serve(bridge, config, receive));
    id
}
async fn serve(bridge: Arc<Bridge>, config: Config, mut receive: mpsc::Receiver<String>) {
    let out = bridge.clone();
    let root = config.root.to_string_lossy().to_string();
    let editors = desktop::open(config, None, Arc::new(move |message| out.emit(message))).await;
    let mut channels: HashMap<String, mpsc::Sender<(Value, usize)>> = HashMap::new();
    let mut actors = tokio::task::JoinSet::new();
    while let Some(raw) = receive.recv().await {
        while actors.try_join_next().is_some() {}
        let request: Value = match serde_json::from_str(&raw) {
            Ok(Value::Object(fields)) => Value::Object(fields),
            _ => {
                bridge.queued.fetch_sub(raw.len(), Ordering::Relaxed);
                continue;
            }
        };
        let op = request["op"].as_str().unwrap_or("");
        let editors = match &editors {
            Ok(editors) => editors,
            Err(error) => {
                bridge.queued.fetch_sub(raw.len(), Ordering::Relaxed);
                bridge.reply(
                    request["id"].clone(),
                    Err(rayde_session::error::SessionError::new(
                        error.code,
                        error.message.clone(),
                    )),
                );
                continue;
            }
        };
        if op == "hello" {
            bridge.queued.fetch_sub(raw.len(), Ordering::Relaxed);
            bridge.reply(request["id"].clone(),Ok(json!({"root":root,"name":std::path::Path::new(&root).file_name().unwrap_or_default().to_string_lossy(),"documentBridge":true,"remote":false})));
            continue;
        }
        let Some(handle) = request["handle"].as_str().filter(|s| s.len() <= 1024) else {
            bridge.queued.fetch_sub(raw.len(), Ordering::Relaxed);
            continue;
        };
        if !channels.contains_key(handle) {
            if channels.len() >= 256 {
                bridge.queued.fetch_sub(raw.len(), Ordering::Relaxed);
                bridge.reply(
                    request["id"].clone(),
                    Err(rayde_session::error::SessionError::new(
                        "busy",
                        "Too many cloud editor documents are open.",
                    )),
                );
                continue;
            }
            let (send, rx) = mpsc::channel(256);
            channels.insert(handle.into(), send);
            let owner = bridge.clone();
            let editors = editors.clone();
            actors.spawn(actor(owner, editors, rx));
        }
        let channel = channels.get(handle).unwrap().clone();
        let closing = op == "view.close";
        let name = handle.to_string();
        if channel.send((request, raw.len())).await.is_err() {
            bridge.queued.fetch_sub(raw.len(), Ordering::Relaxed);
            channels.remove(&name);
        }
        if closing {
            channels.remove(&name);
        }
    }
    drop(channels);
    while actors.join_next().await.is_some() {}
    if let Ok(editors) = editors {
        editors.close().await;
    }
}
async fn actor(
    bridge: Arc<Bridge>,
    editors: Arc<Editors<DirStore>>,
    mut requests: mpsc::Receiver<(Value, usize)>,
) {
    type Saving = std::pin::Pin<
        Box<dyn std::future::Future<Output = (Value, rayde_session::error::Result<Value>)> + Send>,
    >;
    let finish = |id, result: rayde_session::error::Result<Value>| {
        bridge.reply(id, result.map(|reply| json!({"result":reply})))
    };
    let mut saving: Option<Saving> = None;
    loop {
        let next = tokio::select! {
            request=requests.recv()=>request,
            completed=async{saving.as_mut().unwrap().await},if saving.is_some()=>{saving=None;finish(completed.0,completed.1);continue},
        };
        let Some((request, size)) = next else { break };
        bridge.queued.fetch_sub(size, Ordering::Relaxed);
        let op = request["op"].as_str().unwrap_or("");
        if op == "view.save" {
            if saving.is_some() {
                finish(
                    request["id"].clone(),
                    Err(rayde_session::error::SessionError::new(
                        "busy",
                        "This document is already being saved.",
                    )),
                );
                continue;
            }
            let owner = editors.clone();
            let mut future: Saving = Box::pin(async move {
                let result = owner.request("view.save", &request).await;
                (request["id"].clone(), result)
            });
            let first =
                std::future::poll_fn(|cx| std::task::Poll::Ready(future.as_mut().poll(cx))).await;
            if let std::task::Poll::Ready((id, result)) = first {
                finish(id, result)
            } else {
                saving = Some(future)
            }
            continue;
        }
        if op == "view.close" {
            if let Some(saving) = saving.take() {
                let (id, result) = saving.await;
                finish(id, result)
            }
        }
        let result = editors.request(op, &request).await;
        if !request["id"].is_null() {
            finish(request["id"].clone(), result)
        } else if let Err(error) = result {
            bridge.emit(json!({"ev":"view.error","handle":request["handle"],"code":error.code,"message":error.message}).to_string());
        }
        if op == "view.close" {
            break;
        }
    }
    if let Some(saving) = saving {
        let (id, result) = saving.await;
        finish(id, result)
    }
}
pub fn send(id: i32, text: &str) -> bool {
    if text.len() > 16 * 1024 * 1024 {
        return false;
    }
    let Some(bridge) = bridge(id) else {
        return false;
    };
    if bridge.queued.fetch_add(text.len(), Ordering::Relaxed) + text.len() > MAX_BYTES {
        bridge.queued.fetch_sub(text.len(), Ordering::Relaxed);
        return false;
    }
    let result = bridge
        .send
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|send| send.try_send(text.into()).is_ok());
    if !result {
        bridge.queued.fetch_sub(text.len(), Ordering::Relaxed);
    }
    result
}
pub fn receive(id: i32, seconds: f64) -> Option<String> {
    let bridge = bridge(id)?;
    let mut queue = bridge.queue.lock().unwrap();
    if queue.messages.is_empty() && !queue.closed {
        let delay = if seconds.is_finite() {
            seconds.clamp(0., 3600.)
        } else {
            0.
        };
        queue = bridge
            .wake
            .wait_timeout(queue, Duration::from_secs_f64(delay))
            .unwrap()
            .0;
    }
    if let Some(message) = queue.messages.pop_front() {
        queue.bytes -= message.len();
        return Some(message);
    }
    queue
        .closed
        .then(|| json!({"ev":"session.disconnected"}).to_string())
}
pub fn close(id: i32) {
    if let Some(bridge) = BRIDGES
        .lock()
        .unwrap()
        .as_mut()
        .and_then(|map| map.remove(&id))
    {
        bridge.send.lock().unwrap().take();
        let mut queue = bridge.queue.lock().unwrap();
        queue.closed = true;
        queue.messages.clear();
        queue.bytes = 0;
        bridge.wake.notify_all();
    }
}
