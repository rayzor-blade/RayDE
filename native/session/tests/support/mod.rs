#![allow(dead_code)]
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use rayde_session::server::{Options, Running, start};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::{Arc, Mutex}, time::Duration};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;
use yrs::{Doc, GetString, OffsetKind, Options as DocOptions, ReadTxn, StateVector, Text, TextRef, Transact, Update, updates::{decoder::Decode, encoder::Encode}};

pub async fn server(root: &std::path::Path, exec: bool) -> Running {
    let mut options = Options::new(root);
    options.state_root = Some(root.join(".rayde-session"));
    options.token = Some("secret".into());
    options.exec = exec;
    options.flush_delay = Duration::from_millis(30);
    start(options).await.expect("the server starts")
}

/// A client of the session: requests wait for their response, and events queue up.
pub struct Client {
    binary: bool,
    sink: futures_util::stream::SplitSink<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, Message>,
    waiting: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    pub events: mpsc::UnboundedReceiver<Value>,
    next: u64,
}

impl Client {
    pub async fn connect_binary(running: &Running) -> Client {
        let mut client = Client::connect(running).await;
        client.binary = true;
        client
    }

    pub async fn connect(running: &Running) -> Client {
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://{}/session", running.address)).await.expect("connects");
        let (sink, mut stream) = socket.split();
        let waiting: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>> = Arc::new(Mutex::new(HashMap::new()));
        let (events_tx, events) = mpsc::unbounded_channel();
        let table = waiting.clone();
        tokio::spawn(async move {
            while let Some(Ok(message)) = stream.next().await {
                let text = match message {
                    Message::Text(text) => text.to_string(),
                    Message::Binary(bytes) => String::from_utf8(bytes[4..].to_vec()).unwrap(),
                    _ => continue,
                };
                let value: Value = serde_json::from_str(&text).unwrap();
                match value.get("id").and_then(Value::as_u64) {
                    Some(id) => {
                        if let Some(reply) = table.lock().unwrap().remove(&id) {
                            let _ = reply.send(value);
                        }
                    }
                    None if value.get("ev").is_some() => {
                        let _ = events_tx.send(value);
                    }
                    None => {
                        let _ = events_tx.send(value);
                    }
                }
            }
        });
        Client { binary: false, sink, waiting, events, next: 1 }
    }

    pub async fn hello(running: &Running) -> Client {
        let mut client = Client::connect(running).await;
        let reply = client.request(json!({"op": "hello", "token": "secret"})).await;
        assert_eq!(reply["ok"], true, "{reply}");
        client
    }

    pub async fn request(&mut self, mut message: Value) -> Value {
        let id = self.next;
        self.next += 1;
        message["id"] = json!(id);
        let (reply, answer) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id, reply);
        let text = message.to_string();
        let message = if self.binary { Message::Binary(rayde_session::server::frame(&text).into()) } else { Message::Text(text.into()) };
        self.sink.send(message).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), answer).await.expect("a response arrives").unwrap()
    }

    pub async fn close(&mut self) {self.sink.close().await.unwrap();}

    /// The next event of `kind`, skipping others.
    pub async fn event(&mut self, kind: &str) -> Value {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let event = self.events.recv().await.expect("the connection stays open");
                if event["ev"] == kind {
                    return event;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("no {kind} event arrived"))
    }
}

/// A client's own copy of a document, the way a page keeps one.
pub struct Peer {
    pub doc: Doc,
    pub text: TextRef,
}

impl Peer {
    pub fn new() -> Peer {
        let doc = Doc::with_options(DocOptions { offset_kind: OffsetKind::Utf16, ..DocOptions::default() });
        let text = doc.get_or_insert_text("text");
        Peer { doc, text }
    }

    pub fn apply(&self, update: &str) {
        let bytes = B64.decode(update).unwrap();
        self.doc.transact_mut().apply_update(Update::decode_v1(&bytes).unwrap()).unwrap();
    }

    pub fn string(&self) -> String {
        self.text.get_string(&self.doc.transact())
    }

    pub fn vector(&self) -> String {
        B64.encode(self.doc.transact().state_vector().encode_v1())
    }

    /// Edits the text and returns the update that carries the edit.
    pub fn edit(&self, index: u32, remove: u32, insert: &str) -> String {
        let before = self.doc.transact().state_vector();
        {
            let mut txn = self.doc.transact_mut();
            if remove > 0 {
                self.text.remove_range(&mut txn, index, remove);
            }
            if !insert.is_empty() {
                self.text.insert(&mut txn, index, insert);
            }
        }
        B64.encode(self.doc.transact().encode_state_as_update_v1(&before))
    }

    /// What the session lacks, given the vector it reported.
    pub fn missing(&self, server_vector: &str) -> String {
        let vector = StateVector::decode_v1(&B64.decode(server_vector).unwrap()).unwrap();
        B64.encode(self.doc.transact().encode_state_as_update_v1(&vector))
    }
}

pub async fn until(mut check: impl FnMut() -> bool) {
    for _ in 0..200 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("the condition did not hold in time");
}
