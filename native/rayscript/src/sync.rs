use rayde_sync::client::{Config, Push};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicI32, Ordering},
    },
};

static NEXT: AtomicI32 = AtomicI32::new(1);
static PUSHES: Mutex<Option<HashMap<i32, Arc<Push>>>> = Mutex::new(None);

fn push(id: i32) -> Option<Arc<Push>> {
    PUSHES.lock().unwrap().as_ref()?.get(&id).cloned()
}

/// Starts an upload from a JSON config and returns its handle, or -1 when the config is not valid.
pub fn start(config: &str) -> i32 {
    let Ok(config) = serde_json::from_str::<Config>(config) else {
        return -1;
    };
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    PUSHES.lock().unwrap().get_or_insert_default().insert(id, Arc::new(Push::start(config)));
    id
}

/// The events since the last poll as a JSON array, or None when there are none.
pub fn poll(id: i32) -> Option<String> {
    let events = push(id)?.poll();
    if events.is_empty() { None } else { Some(serde_json::to_string(&events).unwrap()) }
}

pub fn pending(id: i32) -> bool {
    push(id).is_some_and(|p| p.pending())
}

pub fn cancel(id: i32) {
    if let Some(p) = push(id) {
        p.cancel();
    }
}

pub fn close(id: i32) {
    if let Some(p) = PUSHES.lock().unwrap().as_mut().and_then(|m| m.remove(&id)) {
        p.cancel();
    }
}
