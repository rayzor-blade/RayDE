//! One event-driven socket per provider; notices request the existing durable exchange.
use crate::{
    cloud::{Binding, Notice, Notify, Subscription},
    error::SessionError,
};
use futures_util::{SinkExt, StreamExt};
use rayde_sync::client::Config;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex, Weak,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{
        Message,
        client::IntoClientRequest,
        protocol::{WebSocketConfig, frame::coding::CloseCode},
    },
};

const MAX_DOCUMENTS: usize = 256;
const MAX_BYTES: usize = 64 * 1024;
#[derive(Clone)]
struct Topic {
    id: u64,
    lineage: String,
    sequence: u64,
    hint: u64,
    requested: bool,
    dead: bool,
    notify: Notify,
}
#[derive(Default)]
struct State {
    topics: HashMap<String, Topic>,
    running: bool,
    resume: u64,
    failure: Option<SessionError>,
}
struct Inner {
    state: Mutex<State>,
    wake: tokio::sync::Notify,
    config: Arc<dyn Fn() -> Config + Send + Sync>,
    next: AtomicU64,
}
pub struct Broker {
    inner: Arc<Inner>,
}
struct Guard {
    inner: Weak<Inner>,
    path: String,
    id: u64,
}
impl Drop for Guard {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade() {
            let mut state = inner.state.lock().unwrap();
            if state
                .topics
                .get(&self.path)
                .is_some_and(|topic| topic.id == self.id)
            {
                state.topics.remove(&self.path);
            }
            drop(state);
            inner.wake.notify_one();
        }
    }
}
impl Broker {
    pub fn new(config: Arc<dyn Fn() -> Config + Send + Sync>) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: Default::default(),
                wake: Default::default(),
                config,
                next: AtomicU64::new(1),
            }),
        }
    }
    pub fn watch(&self, binding: Binding, notify: Notify) -> Option<Box<dyn Subscription>> {
        let path = binding.seed["path"].as_str()?.to_string();
        let lineage = binding.lineage().ok()?.to_string();
        let config = (self.inner.config)();
        if binding.gateway != config.gateway
            || binding.seed["workspace"].as_str() != config.workspace.as_deref()
        {
            notify(Notice::Failed(crate::cloud::lineage()));
            return None;
        }
        let mut state = self.inner.state.lock().unwrap();
        let bytes: usize = state
            .topics
            .keys()
            .filter(|p| **p != path)
            .map(|p| p.len() + 192)
            .sum();
        if state.topics.keys().filter(|p| **p != path).count() >= MAX_DOCUMENTS
            || bytes + path.len() + 192 > MAX_BYTES
        {
            drop(state);
            notify(Notice::Failed(SessionError::new(
                "cloud-watch-limit",
                "Too many Cloud Sync documents are open for pushed updates.",
            )));
            return None;
        }
        let id = self.inner.next.fetch_add(1, Ordering::Relaxed);
        state.topics.insert(
            path.clone(),
            Topic {
                id,
                lineage,
                sequence: binding.sequence,
                hint: 0,
                requested: false,
                dead: false,
                notify,
            },
        );
        state.resume = state.resume.wrapping_add(1);
        let start = !state.running;
        state.running = true;
        drop(state);
        if start {
            let inner = self.inner.clone();
            tokio::spawn(async move {
                run(inner).await;
            });
        }
        self.inner.wake.notify_one();
        Some(Box::new(Guard {
            inner: Arc::downgrade(&self.inner),
            path,
            id,
        }))
    }
    pub fn accepted(&self, binding: Binding) {
        let Some(path) = binding.seed["path"].as_str() else {
            return;
        };
        let mut state = self.inner.state.lock().unwrap();
        if let Some(topic) = state.topics.get_mut(path) {
            if binding.seed["lineage"].as_str() == Some(&topic.lineage) {
                topic.sequence = topic.sequence.max(binding.sequence);
                topic.requested = false;
            }
        }
        drop(state);
        self.inner.wake.notify_one();
    }
    pub fn refresh(&self) {
        let mut state = self.inner.state.lock().unwrap();
        state.resume = state.resume.wrapping_add(1);
        drop(state);
        self.inner.wake.notify_one();
    }
    pub fn failed(&self, binding: Binding, error: SessionError) {
        let Some(path) = binding.seed["path"].as_str() else {
            return;
        };
        let mut state = self.inner.state.lock().unwrap();
        if !state
            .topics
            .get(path)
            .is_some_and(|topic| binding.seed["lineage"].as_str() == Some(&topic.lineage))
        {
            return;
        }
        if matches!(
            error.code,
            "document-lineage" | "recovery-conflict" | "bad-buffer-state"
        ) {
            if let Some(topic) = state.topics.get_mut(path) {
                topic.dead = true;
            }
        } else {
            state.failure = Some(error);
        }
        drop(state);
        self.inner.wake.notify_one();
    }
}
fn fingerprint(config: &Config) -> String {
    crate::checkpoint::digest(
        &serde_json::to_vec(&(
            &config.gateway,
            &config.workspace,
            &config.account,
            &config.token,
        ))
        .unwrap(),
    )
}
fn failure(code: &'static str) -> SessionError {
    SessionError::new(
        code,
        if code == "sync-auth" {
            "Cloud access expired or was revoked. Reopen the workspace; edits are kept locally."
        } else {
            "Cloud updates disconnected. Edits are kept locally; activate the tab or save to retry."
        },
    )
}
fn emit(inner: &Inner, error: SessionError) {
    let callbacks: Vec<_> = inner
        .state
        .lock()
        .unwrap()
        .topics
        .values()
        .filter(|t| !t.dead)
        .map(|t| t.notify.clone())
        .collect();
    for notify in callbacks {
        notify(Notice::Failed(error.clone()));
    }
}
fn empty(inner: &Inner) -> bool {
    let mut state = inner.state.lock().unwrap();
    if state.topics.is_empty() {
        state.running = false;
        true
    } else {
        false
    }
}
fn delay(attempt: u32) -> Duration {
    Duration::from_millis(
        (250u64.saturating_mul(1u64 << attempt.min(7))).min(30_000) + rand::random::<u8>() as u64,
    )
}
enum End {
    Empty,
    Refresh,
    Failed(SessionError, bool),
}
async fn run(inner: Arc<Inner>) {
    let mut attempts = 0u32;
    let mut paused: Option<(String, bool)> = None;
    let mut resumed = inner.state.lock().unwrap().resume;
    loop {
        if empty(&inner) {
            return;
        }
        if inner
            .state
            .lock()
            .unwrap()
            .topics
            .values()
            .all(|topic| topic.dead)
        {
            inner.wake.notified().await;
            continue;
        }
        let config = (inner.config)();
        let identity = fingerprint(&config);
        let activity = inner.state.lock().unwrap().resume;
        if let Some((previous, auth)) = &paused {
            let authorized = !auth || config.token.is_none() || *previous != identity;
            if !authorized || activity == resumed && *previous == identity {
                inner.wake.notified().await;
                continue;
            }
            paused = None;
            attempts = 0;
        }
        resumed = activity;
        let started = Instant::now();
        match connected(&inner, &config).await {
            End::Empty => {
                if empty(&inner) {
                    return;
                }
                continue;
            }
            End::Refresh => {
                attempts = 0;
                continue;
            }
            End::Failed(error, auth) => {
                if empty(&inner) {
                    return;
                }
                emit(&inner, error);
                if started.elapsed() >= Duration::from_secs(30) {
                    attempts = 0
                }
                attempts += 1;
                if auth || attempts >= 8 {
                    paused = Some((identity, auth));
                    continue;
                }
            }
        }
        let deadline = tokio::time::Instant::now() + delay(attempts - 1);
        loop {
            tokio::select! {
                _=tokio::time::sleep_until(deadline)=>break,
                _=inner.wake.notified()=>{if empty(&inner){return}if inner.state.lock().unwrap().resume!=resumed{attempts=0;break}},
            }
        }
    }
}
async fn connected(inner: &Arc<Inner>, config: &Config) -> End {
    if let Some(error) = inner.state.lock().unwrap().failure.take() {
        let auth = error.code == "sync-auth";
        return End::Failed(error, auth);
    }
    let Some(workspace) = config.workspace.as_deref() else {
        return End::Failed(failure("cloud-watch-unavailable"), true);
    };
    let base = if let Some(base) = config.gateway.strip_prefix("https://") {
        format!("wss://{base}")
    } else if let Some(base) = config.gateway.strip_prefix("http://") {
        format!("ws://{base}")
    } else {
        return End::Failed(failure("cloud-watch-unavailable"), true);
    };
    let Ok(mut request) = format!(
        "{}/api/sync/workspaces/{workspace}/documents/watch",
        base.trim_end_matches('/')
    )
    .into_client_request() else {
        return End::Failed(failure("cloud-watch-unavailable"), true);
    };
    if let Some(token) = &config.token {
        let Ok(value) = format!("Bearer {token}").parse() else {
            return End::Failed(failure("sync-auth"), true);
        };
        request.headers_mut().insert("Authorization", value);
    }
    if let Some(account) = &config.account {
        let Ok(value) = account.parse() else {
            return End::Failed(failure("sync-auth"), true);
        };
        request.headers_mut().insert("X-Dev-Account", value);
    }
    let mut limits = WebSocketConfig::default();
    limits.max_message_size = Some(MAX_BYTES);
    limits.max_frame_size = Some(MAX_BYTES);
    limits.max_write_buffer_size = 128 * 1024;
    limits.write_buffer_size = 0;
    let connect = tokio::time::timeout(
        Duration::from_secs(15),
        connect_async_with_config(request, Some(limits), true),
    );
    tokio::pin!(connect);
    let mut socket = loop {
        tokio::select! {
            result=&mut connect=>break match result{
                Ok(Ok((socket,_)))=>socket,
                Ok(Err(tokio_tungstenite::tungstenite::Error::Http(reply))) if matches!(reply.status().as_u16(),401|403)=>return End::Failed(failure("sync-auth"),true),
                _=>return End::Failed(failure("cloud-offline"),false),
            },
            _=inner.wake.notified()=>{if empty(inner){return End::Empty}if fingerprint(&(inner.config)())!=fingerprint(config){return End::Refresh}},
        }
    };
    let ready = tokio::time::timeout(Duration::from_secs(5), socket.next()).await;
    let valid = matches!(ready,Ok(Some(Ok(Message::Text(ref raw)))) if serde_json::from_str::<Value>(raw).is_ok_and(|value|value["ev"]=="ready"&&value["version"]==1&&value["workspace"]==workspace));
    if !valid {
        return End::Failed(failure("cloud-offline"), false);
    }
    {
        let mut state = inner.state.lock().unwrap();
        for topic in state.topics.values_mut() {
            topic.requested = false;
        }
    }
    let mut sent: HashMap<String, (u64, u64)> = HashMap::new();
    let mut initial = true;
    loop {
        if empty(inner) {
            let _ = tokio::time::timeout(Duration::from_secs(2), socket.close(None)).await;
            return End::Empty;
        }
        if let Some(error) = inner.state.lock().unwrap().failure.take() {
            let auth = error.code == "sync-auth";
            return End::Failed(error, auth);
        }
        let topics = inner.state.lock().unwrap().topics.clone();
        if topics.values().all(|topic| topic.dead) {
            let _ = tokio::time::timeout(Duration::from_secs(2), socket.close(None)).await;
            return End::Refresh;
        }
        let mut callbacks = Vec::new();
        let mut outgoing = Vec::new();
        for (path, (id, _)) in &sent {
            if !topics
                .get(path)
                .is_some_and(|topic| !topic.dead && topic.id == *id)
            {
                outgoing.push(json!({"op":"unsubscribe","path":path}));
            }
        }
        sent.retain(|path, (id, _)| {
            topics
                .get(path)
                .is_some_and(|topic| !topic.dead && topic.id == *id)
        });
        for (path, topic) in topics.iter().filter(|(_, topic)| !topic.dead) {
            let fresh = !sent.contains_key(path);
            match sent.get(path) {
                None => {
                    outgoing.push(json!({"op":"subscribe","path":path,"lineage":topic.lineage,"sequence":topic.sequence}));
                    sent.insert(path.clone(), (topic.id, topic.sequence));
                }
                Some((_, sequence)) if topic.sequence > *sequence => {
                    outgoing.push(json!({"op":"ack","path":path,"lineage":topic.lineage,"sequence":topic.sequence}));
                    sent.insert(path.clone(), (topic.id, topic.sequence));
                }
                _ => {}
            }
            let mut state = inner.state.lock().unwrap();
            if let Some(current) = state.topics.get_mut(path) {
                if current.id == topic.id
                    && !current.requested
                    && (initial || fresh || current.hint > current.sequence)
                {
                    current.requested = true;
                    callbacks.push(current.notify.clone());
                }
            }
        }
        for message in outgoing {
            if !matches!(
                tokio::time::timeout(
                    Duration::from_secs(5),
                    socket.send(Message::Text(message.to_string().into()))
                )
                .await,
                Ok(Ok(()))
            ) {
                return End::Failed(failure("cloud-offline"), false);
            }
        }
        for notify in callbacks {
            notify(Notice::Refresh)
        }
        initial = false;
        tokio::select! {
            _=inner.wake.notified()=>{if fingerprint(&(inner.config)())!=fingerprint(config){return End::Refresh}},
            message=socket.next()=>match message{
                Some(Ok(Message::Text(raw)))=>{
                    let Ok(value)=serde_json::from_str::<Value>(&raw)else{return End::Failed(failure("cloud-watch-unavailable"),true)};
                    if value["ev"]=="error"{let auth=value["status"]==401||value["status"]==403;return End::Failed(failure(if auth{"sync-auth"}else{"cloud-offline"}),auth)}
                    if value["ev"]!="changed"{return End::Failed(failure("cloud-watch-unavailable"),true)}
                    let Some(path)=value["path"].as_str()else{return End::Failed(failure("cloud-watch-unavailable"),true)};
                    let mut notify=None;let mut state=inner.state.lock().unwrap();
                    if let Some(topic)=state.topics.get_mut(path){
                        if value["lineage"].as_str()!=Some(&topic.lineage)||value["retired"]==true{topic.dead=true;notify=Some(topic.notify.clone());}
                        else if let Some(sequence)=value["sequence"].as_u64().filter(|s|*s>0){topic.hint=topic.hint.max(sequence);}else{return End::Failed(failure("cloud-watch-unavailable"),true)}
                    }drop(state);if let Some(notify)=notify{notify(Notice::Failed(crate::cloud::lineage()));}
                },
                Some(Ok(Message::Ping(_)))=>{if !matches!(tokio::time::timeout(Duration::from_secs(5),socket.flush()).await,Ok(Ok(()))){return End::Failed(failure("cloud-offline"),false)}},
                Some(Ok(Message::Pong(_)))=>{},
                Some(Ok(Message::Close(frame)))=>{let auth=frame.is_some_and(|f|f.code==CloseCode::Policy&&f.reason.contains("access"));return End::Failed(failure(if auth{"sync-auth"}else{"cloud-offline"}),auth)},
                _=>return End::Failed(failure("cloud-offline"),false),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::net::TcpListener;
    fn config(gateway: String) -> Config {
        serde_json::from_value(json!({"root":".","gateway":gateway,"workspace":rayde_sync::ids::WorkspaceId::from_random(&[7;32]).as_str()})).unwrap()
    }
    fn binding(config: &Config) -> Binding {
        let doc = rayde_sync::live::Document::new(
            config.workspace.as_deref().unwrap(),
            "a.txt",
            1,
            "base",
        )
        .unwrap();
        Binding {
            version: 1,
            gateway: config.gateway.clone(),
            seed: serde_json::to_value(doc.seed).unwrap(),
            sequence: 1,
            vector: String::new(),
        }
    }
    #[tokio::test(start_paused = true)]
    async fn retries_stop_when_the_budget_is_exhausted_and_restart_only_on_activity() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let config = config(format!("http://{address}"));
        let state = config.clone();
        let broker = Broker::new(Arc::new(move || state.clone()));
        let errors = Arc::new(AtomicUsize::new(0));
        let changed = Arc::new(tokio::sync::Notify::new());
        let (counter, wake) = (errors.clone(), changed.clone());
        let guard = broker
            .watch(
                binding(&config),
                Arc::new(move |notice| {
                    if matches!(notice, Notice::Failed(_)) {
                        counter.fetch_add(1, Ordering::SeqCst);
                        wake.notify_one();
                    }
                }),
            )
            .unwrap();
        tokio::time::timeout(Duration::from_secs(600), async {
            while errors.load(Ordering::SeqCst) < 8 {
                changed.notified().await;
            }
        })
        .await
        .unwrap();
        tokio::time::advance(Duration::from_secs(3600)).await;
        tokio::task::yield_now().await;
        assert_eq!(errors.load(Ordering::SeqCst), 8);
        broker.refresh();
        tokio::time::timeout(Duration::from_secs(600), async {
            while errors.load(Ordering::SeqCst) < 16 {
                changed.notified().await;
            }
        })
        .await
        .unwrap();
        drop(guard);
        tokio::task::yield_now().await;
        assert!(broker.inner.state.lock().unwrap().topics.is_empty());
    }
    #[tokio::test]
    async fn rejected_credentials_do_not_retry_until_the_credential_changes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let connections = Arc::new(AtomicUsize::new(0));
        let count = connections.clone();
        let server = tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else {
                    return;
                };
                count.fetch_add(1, Ordering::SeqCst);
                tokio::spawn(async move {
                    let accepted = tokio_tungstenite::accept_hdr_async(
                        socket,
                        |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                         response| {
                            if request
                                .headers()
                                .get("Authorization")
                                .is_some_and(|v| v == "Bearer renewed")
                            {
                                Ok(response)
                            } else {
                                Err(tokio_tungstenite::tungstenite::http::Response::builder()
                                    .status(401)
                                    .body(None)
                                    .unwrap())
                            }
                        },
                    )
                    .await;
                    if let Ok(mut socket) = accepted {
                        let workspace = rayde_sync::ids::WorkspaceId::from_random(&[7; 32]);
                        let _ = socket
                            .send(Message::Text(
                                json!({"ev":"ready","version":1,"workspace":workspace.as_str()})
                                    .to_string()
                                    .into(),
                            ))
                            .await;
                        while socket.next().await.is_some() {}
                    }
                });
            }
        });
        let mut original = config(format!("http://{address}"));
        original.token = Some("expired".into());
        let config = Arc::new(Mutex::new(original.clone()));
        let current = config.clone();
        let broker = Broker::new(Arc::new(move || current.lock().unwrap().clone()));
        let notices = Arc::new(Mutex::new(Vec::new()));
        let seen = notices.clone();
        let guard = broker
            .watch(
                binding(&original),
                Arc::new(move |notice| seen.lock().unwrap().push(notice)),
            )
            .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            while notices.lock().unwrap().is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        for _ in 0..4 {
            broker.refresh();
            tokio::task::yield_now().await;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(connections.load(Ordering::SeqCst), 1);
        config.lock().unwrap().token = Some("renewed".into());
        broker.refresh();
        tokio::time::timeout(Duration::from_secs(3), async {
            while !notices
                .lock()
                .unwrap()
                .iter()
                .any(|notice| matches!(notice, Notice::Refresh))
            {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(connections.load(Ordering::SeqCst), 2);
        drop(guard);
        server.abort();
    }
    #[tokio::test]
    async fn retired_topics_drop_the_socket_and_stay_idle_until_a_new_subscription() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let connections = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let (count, live) = (connections.clone(), active.clone());
        let server = tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else {
                    return;
                };
                count.fetch_add(1, Ordering::SeqCst);
                let live = live.clone();
                tokio::spawn(async move {
                    let mut socket = tokio_tungstenite::accept_async(socket).await.unwrap();
                    live.fetch_add(1, Ordering::SeqCst);
                    let workspace = rayde_sync::ids::WorkspaceId::from_random(&[7; 32]);
                    socket
                        .send(Message::Text(
                            json!({"ev":"ready","version":1,"workspace":workspace.as_str()})
                                .to_string()
                                .into(),
                        ))
                        .await
                        .unwrap();
                    while let Some(Ok(Message::Text(raw))) = socket.next().await {
                        let request: Value = serde_json::from_str(&raw).unwrap();
                        if request["op"] == "subscribe" {
                            socket.send(Message::Text(json!({"ev":"changed","path":request["path"],"lineage":request["lineage"],"retired":true}).to_string().into())).await.unwrap();
                        }
                    }
                    live.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
        let config = config(format!("http://{address}"));
        let state = config.clone();
        let broker = Broker::new(Arc::new(move || state.clone()));
        let retired = Arc::new(AtomicUsize::new(0));
        let seen = retired.clone();
        let guard = broker
            .watch(
                binding(&config),
                Arc::new(move |notice| {
                    if matches!(notice,Notice::Failed(ref error) if error.code=="document-lineage")
                    {
                        seen.fetch_add(1, Ordering::SeqCst);
                    }
                }),
            )
            .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            while retired.load(Ordering::SeqCst) == 0 || active.load(Ordering::SeqCst) > 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        for _ in 0..4 {
            broker.refresh();
            tokio::task::yield_now().await;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(connections.load(Ordering::SeqCst), 1);
        let replacement = broker.watch(binding(&config), Arc::new(|_| {})).unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            while connections.load(Ordering::SeqCst) < 2 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        drop(guard);
        assert_eq!(
            broker.inner.state.lock().unwrap().topics.len(),
            1,
            "an old guard cannot remove its replacement"
        );
        drop(replacement);
        server.abort();
    }
}
