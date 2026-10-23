//! Supervised native hosts; pipe I/O, termination and reaping never run on the UI thread.
use crate::wake::platform_wake;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, VecDeque},
    io::{self, BufRead, BufReader, Read, Write},
    process::{Child, Command, Stdio},
    sync::{Arc, Condvar, Mutex, atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicUsize, Ordering}, mpsc},
    thread,
    time::Duration,
};

pub(crate) const MAX_MESSAGE: usize = 16 << 20;
pub(crate) const MAX_QUEUE: usize = 32 << 20;
const MAX_EVENTS: usize = 4096;
static HOSTS: Mutex<BTreeMap<i32, Arc<Client>>> = Mutex::new(BTreeMap::new());
static NEXT: AtomicI32 = AtomicI32::new(1);

struct Client {
    input: mpsc::SyncSender<Option<(String, usize)>>,
    input_bytes: AtomicUsize,
    output: Mutex<(VecDeque<String>, usize)>,
    child: Mutex<Option<Child>>,
    status: AtomicI32,
    closing: AtomicBool,
    finished: AtomicBool,
    pid: AtomicU32,
    stderr: Mutex<VecDeque<u8>>,
    done: (Mutex<bool>, Condvar),
    wake: Option<unsafe extern "C" fn() -> bool>,
}

impl Client {
    fn wake(&self) { if let Some(wake) = self.wake { unsafe { wake(); } } }

    fn push(&self, line: String) -> bool {
        if self.finished.load(Ordering::Acquire) || self.closing.load(Ordering::Acquire) { return false; }
        let mut queue = self.output.lock().unwrap();
        if queue.0.len() >= MAX_EVENTS || queue.1 + line.len() > MAX_QUEUE { return false; }
        let wake = queue.0.is_empty();
        queue.1 += line.len(); queue.0.push_back(line);
        drop(queue);
        if wake { self.wake(); }
        true
    }

    fn finish(&self, failure: Option<String>) {
        if self.finished.swap(true, Ordering::AcqRel) { return; }
        let closing = self.closing.load(Ordering::Acquire);
        let mut success = false;
        let mut detail = failure;
        if let Some(mut child) = self.child.lock().unwrap().take() {
            // EOF can precede the parent's observation of process exit by one scheduling turn.
            let mut ended = child.try_wait().ok().flatten();
            if detail.is_none() {
                for _ in 0..10 {
                    if ended.is_some() { break; }
                    thread::sleep(Duration::from_millis(5));
                    ended = child.try_wait().ok().flatten();
                }
            }
            if ended.is_none() { let _ = child.kill(); }
            if let Ok(status) = child.wait() {
                success = status.success() && detail.is_none();
                if !status.success() && detail.is_none() { detail = Some(format!("Native extension host exited: {status}")); }
            }
        }
        if !success && !closing {
            let stderr = self.stderr.lock().unwrap();
            let bytes: Vec<u8> = stderr.iter().copied().collect();
            let diagnostics = String::from_utf8_lossy(&bytes);
            let message = format!("{}{}{}", detail.as_deref().unwrap_or("Native extension host stopped"),
                if diagnostics.is_empty() { "" } else { "\n" }, diagnostics);
            let event = json!({"t":"error","kind":"host","message":message}).to_string();
            let mut queue = self.output.lock().unwrap();
            if queue.1 + event.len() > MAX_QUEUE || queue.0.len() >= MAX_EVENTS { queue.0.clear(); queue.1 = 0; }
            queue.1 += event.len(); queue.0.push_back(event);
        }
        let _ = self.input.try_send(None);
        self.status.store(if success || closing { 1 } else { 2 }, Ordering::Release);
        *self.done.0.lock().unwrap() = true;
        self.done.1.notify_all();
        self.wake();
    }

    fn shutdown(&self) {
        let _done = self.done.0.lock().unwrap();
        if self.closing.swap(true, Ordering::AcqRel) { return; }
        let _ = self.input.try_send(Some(("{\"t\":\"shutdown\"}".into(), 0)));
        self.done.1.notify_all();
    }
}

pub(crate) fn read_line(reader: &mut impl BufRead) -> io::Result<Option<String>> {
    frame(reader, false)
}

fn frame(reader: &mut impl BufRead, output: bool) -> io::Result<Option<String>> {
    let mut line = String::new();
    let size = reader.take((MAX_MESSAGE + 1) as u64).read_line(&mut line)?;
    if size == 0 { return Ok(None); }
    if size > MAX_MESSAGE || !line.ends_with('\n') { return Err(io::Error::other("Invalid extension message length")); }
    let value: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
    if !value.is_object() || !value["t"].is_string() { return Err(io::Error::other("Expected extension message object")); }
    if output && !valid_output(&value) { return Err(io::Error::other("Invalid native extension output fields")); }
    line.pop();
    Ok(Some(line))
}

fn valid_output(value: &Value) -> bool {
    fn node(value: &Value) -> bool { value.as_u64().is_some_and(|n| n > 0 && n <= i32::MAX as u64) }
    match value["t"].as_str().unwrap_or("") {
        "ready" => value["protocol"].as_u64() == Some(rayscript_host::PROTOCOL as u64) && node(&value["pid"]),
        "registered" => value["id"].is_string(),
        "subscribe" => value["hook"].is_string(),
        "log" => value["message"].is_string(),
        "view" => value["title"].is_null() || value["title"].is_string(),
        "call" => value["id"].is_u64() && value["fn"].is_string() && value["args"].is_array(),
        "error" => value["kind"].is_string() && value["message"].is_string() && (value["items"].is_null() || value["items"].is_array()),
        "ops" => value["ops"].as_array().is_some_and(|ops| ops.iter().all(|op| {
            let Some(args) = op.as_array() else { return false; };
            if args.len() < 2 || !node(&args[1]) { return false; }
            match args[0].as_str().unwrap_or("") {
                "create" | "createText" | "setText" | "unset" | "listen" | "unlisten" => args.len() == 3 && args[2].is_string(),
                "set" => args.len() == 4 && args[2].is_string(),
                "insert" => args.len() == 4 && node(&args[2]) && (args[3].is_null() || node(&args[3])),
                "remove" => args.len() == 2,
                _ => false,
            }
        })),
        _ => true,
    }
}

pub(crate) fn open(config: &str) -> Result<i32, String> {
    let value: Value = serde_json::from_str(config).map_err(|e| e.to_string())?;
    let binary = value["binary"].as_str().filter(|s| !s.is_empty()).ok_or("Missing native host executable")?.to_owned();
    let root = value["root"].as_str().unwrap_or("").to_owned();
    let extension = value["extension"].as_str().unwrap_or("").to_owned();
    let (tx, rx) = mpsc::sync_channel::<Option<(String, usize)>>(256);
    let client = Arc::new(Client {
        input:tx, input_bytes:AtomicUsize::new(0), output:Mutex::new((VecDeque::new(),0)), child:Mutex::new(None),
        status:AtomicI32::new(0), closing:AtomicBool::new(false), finished:AtomicBool::new(false), pid:AtomicU32::new(0),
        stderr:Mutex::new(VecDeque::new()), done:(Mutex::new(false),Condvar::new()), wake:platform_wake(),
    });
    let handle = NEXT.fetch_add(1, Ordering::Relaxed);
    if handle <= 0 { return Err("Extension host handles exhausted".into()); }
    HOSTS.lock().unwrap().insert(handle, client.clone());
    let supervisor = client.clone();
    // Reserve supervision before launch so stopping never needs to create another thread.
    if let Err(error) = thread::Builder::new().name("extension-supervisor".into()).spawn(move || {
        let done = supervisor.done.0.lock().unwrap();
        let done = supervisor.done.1.wait_while(done, |done| !*done && !supervisor.closing.load(Ordering::Acquire)).unwrap();
        if *done { return; }
        let (done, _) = supervisor.done.1.wait_timeout_while(done, Duration::from_secs(1), |done| !*done).unwrap();
        if !*done { drop(done); supervisor.finish(Some("Native extension did not stop in time".into())); }
    }) {
        HOSTS.lock().unwrap().remove(&handle); return Err(error.to_string());
    }
    let reader = client.clone();
    if let Err(error) = thread::Builder::new().name("extension-reader".into()).spawn(move || {
        let work = || -> io::Result<()> {
            if reader.closing.load(Ordering::Acquire) { return Ok(()); }
            let mut command = Command::new(binary);
            #[cfg(windows)] {
                use std::os::windows::process::CommandExt;
                command.creation_flags(0x08000000);
            }
            command.arg("--extension").arg(extension);
            if !root.is_empty() { command.arg("--root").arg(root); }
            let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
            let mut stdin = child.stdin.take().unwrap();
            let stdout = child.stdout.take().unwrap();
            let mut stderr = child.stderr.take().unwrap();
            reader.pid.store(child.id(), Ordering::Release);
            *reader.child.lock().unwrap() = Some(child);
            if reader.closing.load(Ordering::Acquire) || reader.finished.load(Ordering::Acquire) {
                if let Some(mut child) = reader.child.lock().unwrap().take() { let _ = child.kill(); let _ = child.wait(); }
                return Ok(());
            }
            let writer = reader.clone();
            thread::Builder::new().name("extension-writer".into()).spawn(move || {
                while !writer.finished.load(Ordering::Acquire) {
                    match rx.recv() {
                        Ok(Some((line, bytes))) => {
                            writer.input_bytes.fetch_sub(bytes, Ordering::AcqRel);
                            if let Err(error) = stdin.write_all(line.as_bytes()).and_then(|_| stdin.write_all(b"\n")).and_then(|_| stdin.flush()) {
                                writer.finish(Some(format!("Native extension input failed: {error}"))); break;
                            }
                        },
                        _ => break,
                    }
                }
            })?;
            let logger = reader.clone();
            thread::Builder::new().name("extension-stderr".into()).spawn(move || {
                let mut bytes = [0;4096];
                while let Ok(size) = stderr.read(&mut bytes) {
                    if size == 0 { break; }
                    let mut tail = logger.stderr.lock().unwrap();
                    tail.extend(&bytes[..size]);
                    let excess = tail.len().saturating_sub(64 << 10); tail.drain(..excess);
                }
            })?;
            let mut stdout = BufReader::new(stdout);
            loop {
                let Some(line) = frame(&mut stdout, true)? else { return Ok(()); };
                if reader.closing.load(Ordering::Acquire) { continue; }
                if !reader.push(line) { return Err(io::Error::other("Native extension output queue exceeded its limit")); }
            }
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work));
        reader.finish(match result { Ok(Ok(())) => None, Ok(Err(error)) => Some(error.to_string()), Err(_) => Some("Native host transport panicked".into()) });
    }) {
        client.finish(Some(error.to_string()));
        HOSTS.lock().unwrap().remove(&handle); return Err(error.to_string());
    }
    Ok(handle)
}

fn client(handle:i32) -> Option<Arc<Client>> { HOSTS.lock().unwrap().get(&handle).cloned() }

pub(crate) fn send(handle:i32, line:&str) -> bool {
    let Some(client) = client(handle) else { return false; };
    if line.len() >= MAX_MESSAGE || client.closing.load(Ordering::Acquire) || client.finished.load(Ordering::Acquire) { return false; }
    if client.input_bytes.try_update(Ordering::AcqRel, Ordering::Acquire, |size| size.checked_add(line.len()).filter(|n| *n <= MAX_QUEUE)).is_err() { return false; }
    if client.input.try_send(Some((line.into(),line.len()))).is_err() { client.input_bytes.fetch_sub(line.len(), Ordering::AcqRel); return false; }
    true
}

pub(crate) fn poll(handle:i32) -> Option<String> {
    let client = client(handle)?;
    let mut queue = client.output.lock().unwrap();
    if queue.0.is_empty() { return None; }
    let mut batch = Vec::new(); let mut size = 0;
    while let Some(line) = queue.0.pop_front() {
        size += line.len(); queue.1 -= line.len(); batch.push(line);
        if size >= 1 << 20 { break; }
    }
    Some(batch.join("\n"))
}
pub(crate) fn pending(handle:i32) -> bool { client(handle).is_some_and(|c| !c.output.lock().unwrap().0.is_empty() || c.status.load(Ordering::Acquire) != 0) }
pub(crate) fn can_wake(handle:i32) -> bool { client(handle).is_some_and(|c| c.wake.is_some()) }
pub(crate) fn status(handle:i32) -> i32 { client(handle).map_or(1, |c| c.status.load(Ordering::Acquire)) }
pub(crate) fn close(handle:i32) { if let Some(client) = HOSTS.lock().unwrap().remove(&handle) { client.shutdown(); } }

#[cfg(test)]
#[path = "extension_process_tests.rs"]
mod tests;
