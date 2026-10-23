use rayde_jam::{
    document::{Document, Patch},
    transport::{Config, Session},
};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicI32, Ordering},
    },
};

static NEXT: AtomicI32 = AtomicI32::new(1);
thread_local! { static DOCUMENTS: RefCell<HashMap<i32,Document>> = RefCell::default(); }
static SESSIONS: Mutex<Option<HashMap<i32, Arc<Session>>>> = Mutex::new(None);

pub fn document_open(text: &str) -> i32 {
    let Ok(doc) = Document::new(text) else {
        return -1;
    };
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    DOCUMENTS.with_borrow_mut(|docs| docs.insert(id, doc));
    id
}
pub fn document_close(id: i32) {
    DOCUMENTS.with_borrow_mut(|docs| docs.remove(&id));
}
pub fn document_call(id: i32, message: &str) -> String {
    let result = (|| -> Result<Value, String> {
        let message: Value = serde_json::from_str(message).map_err(|_| "Invalid Jam command")?;
        DOCUMENTS.with_borrow_mut(|docs| {
            let doc=docs.get_mut(&id).ok_or("Closed Jam document")?;
            let string=|key:&str| message[key].as_str().ok_or_else(||format!("Missing Jam {key}"));
            let index=|key:&str| message[key].as_u64().and_then(|n|u32::try_from(n).ok()).ok_or_else(||format!("Invalid Jam {key}"));
            let mut reply=json!({});
            match string("op")? {
                "snapshot" => { reply["state"]=doc.state().into(); reply["vector"]=doc.vector().into(); },
                "edit" => {
                    let parts:Vec<Patch>=serde_json::from_value(message["parts"].clone()).map_err(|_|"Invalid Jam edit ranges")?;
                    let before=doc.text();
                    return Ok(json!({"update":doc.edit(&before,&parts)?}));
                },
                "undo" => { reply["update"]=doc.undo(message["redo"].as_bool().unwrap_or(false)).into(); },
                "apply" => {
                    let caret=doc.position(index("caret")?)?; let anchor=doc.position(index("anchor")?)?;
                    doc.apply(string("update")?)?;
                    reply["caret"]=doc.resolve(&caret)?.into(); reply["anchor"]=doc.resolve(&anchor)?.into();
                },
                "diff" => return Ok(json!({"update":doc.diff(string("vector")?)?})),
                "position" => return Ok(json!({"caret":doc.position(index("caret")?)?,"anchor":doc.position(index("anchor")?)?})),
                "resolve" => return Ok(json!({"caret":doc.resolve(string("caret")?)?,"anchor":doc.resolve(string("anchor")?)?})),
                _ => return Err("Unknown Jam document command".into()),
            }
            reply["text"]=doc.text().into(); Ok(reply)
        })
    })();
    match result {
        Ok(reply) => reply.to_string(),
        Err(error) => json!({"error":error}).to_string(),
    }
}
pub fn session_open(config: &str) -> i32 {
    let Ok(config) = serde_json::from_str::<Config>(config) else {
        return -1;
    };
    let Ok(session) = Session::start(config, crate::wake::platform_wake()) else {
        return -1;
    };
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    SESSIONS
        .lock()
        .unwrap()
        .get_or_insert_default()
        .insert(id, session);
    id
}
fn session(id: i32) -> Option<Arc<Session>> {
    SESSIONS.lock().unwrap().as_ref()?.get(&id).cloned()
}
pub fn session_send(id: i32, message: &str) -> bool {
    session(id).is_some_and(|s| serde_json::from_str(message).is_ok_and(|v| s.send(v)))
}
pub fn session_poll(id: i32) -> Option<String> {
    let messages = session(id)?.poll();
    if messages.is_empty() {
        None
    } else {
        Some(serde_json::to_string(&messages).unwrap())
    }
}
pub fn session_pending(id: i32) -> bool {
    session(id).is_some_and(|s| s.pending())
}
pub fn session_can_wake(id: i32) -> bool {
    session(id).is_some_and(|s| s.can_wake())
}
pub fn session_close(id: i32) {
    if let Some(s) = SESSIONS
        .lock()
        .unwrap()
        .as_mut()
        .and_then(|m| m.remove(&id))
    {
        s.close();
    }
}
