//! Per-connection terminals; PTY and screen work stays off the ordered session receiver.
use crate::{
    error::Result,
    session::Out,
};
use serde_json::Value;

pub trait Terminals: Send + Sync + 'static {
    fn profiles(&self) -> Value;
    fn open(&self, request: &Value, out: Out) -> Result<u64>;
    fn command(&self, id: u64, request: &Value) -> Result<()>;
    fn close(&self, id: u64);
}

#[cfg(feature = "server")]
mod native {
    use super::*;
    use crate::error::SessionError;
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    use rayde_terminal::Session;
    use serde_json::json;
    use std::{
        collections::HashMap,
        path::PathBuf,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
            mpsc::{self, Receiver, RecvTimeoutError, SyncSender},
        },
        time::{Duration, Instant},
    };

    const INPUT: usize = 256 * 1024;
    enum Command {
        Changed,
        Ack,
        Visible(bool),
        Write(Vec<u8>),
        Resize(u16, u16),
        Scroll(usize),
        Close,
    }
    struct Running {
        tx: SyncSender<Command>,
        cancel: AtomicBool,
        input: AtomicUsize,
        screen: Mutex<Option<Arc<Session>>>,
    }
    pub struct NativeTerminals {
        root: PathBuf,
        profiles: Value,
        environment: HashMap<String, String>,
        running: Arc<Mutex<HashMap<u64, Arc<Running>>>>,
        next: AtomicU64,
    }

    fn dimensions(request: &Value) -> Result<(u16, u16)> {
        let cols = request["cols"].as_u64().unwrap_or(100);
        let rows = request["rows"].as_u64().unwrap_or(24);
        if !(2..=300).contains(&cols) || !(1..=100).contains(&rows) {
            return Err(SessionError::new(
                "bad-request",
                "Terminal dimensions exceed the limit.",
            ));
        }
        Ok((cols as u16, rows as u16))
    }
    impl NativeTerminals {
        pub fn new(root: PathBuf, environment: HashMap<String, String>) -> Self {
            Self {
                root,
                profiles: profiles(&environment),
                environment,
                running: Arc::default(),
                next: AtomicU64::new(1),
            }
        }
    }
    fn profiles(environment: &HashMap<String, String>) -> Value {
        let mut paths = Vec::new();
        #[cfg(windows)]
        {
            if let Some(root) = std::env::var_os("SystemRoot") {
                let root = PathBuf::from(root);
                paths.push(root.join("System32/WindowsPowerShell/v1.0/powershell.exe"));
                paths.push(root.join("System32/cmd.exe"));
            }
        }
        #[cfg(not(windows))]
        {
            if let Some(shell) = environment
                .get("SHELL")
                .map(std::ffi::OsString::from)
                .or_else(|| std::env::var_os("SHELL"))
            {
                paths.push(PathBuf::from(shell));
            }
            if let Ok(shells) = std::fs::read_to_string("/etc/shells") {
                for line in shells.lines() {
                    let p = line.trim();
                    if p.starts_with('/') && !p.contains("nologin") && !p.ends_with("/false") {
                        paths.push(p.into());
                    }
                }
            }
            paths.push("/bin/sh".into());
        }
        let mut found = Vec::new();
        for path in paths {
            if path.is_file()
                && !found
                    .iter()
                    .any(|v: &Value| v["program"] == path.to_string_lossy().as_ref())
            {
                found.push(json!({"name":path.file_stem().unwrap_or_default().to_string_lossy(),"program":path,"isDefault":found.is_empty()}));
            }
        }
        json!(found)
    }
    impl Terminals for NativeTerminals {
        fn profiles(&self) -> Value {
            self.profiles.clone()
        }
        fn open(&self, request: &Value, out: Out) -> Result<u64> {
            let (cols, rows) = dimensions(request)?;
            let key = request["key"]
                .as_str()
                .filter(|v| !v.is_empty() && v.len() <= 128)
                .ok_or_else(|| SessionError::new("bad-request", "A terminal key is required."))?
                .to_string();
            let cwd = crate::store::clean(request["cwd"].as_str().unwrap_or(""))?;
            let program = request["program"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or_else(|| self.profiles[0]["program"].as_str().map(str::to_string))
                .ok_or_else(|| {
                    SessionError::new("unavailable", "No shell is configured on the session host.")
                })?;
            let args = match request.get("args") {
                Some(Value::Array(values)) => values
                    .iter()
                    .map(|v| {
                        v.as_str().map(str::to_string).ok_or_else(|| {
                            SessionError::new("bad-request", "Terminal arguments must be text.")
                        })
                    })
                    .collect::<Result<Vec<_>>>()?,
                _ => {
                    if cfg!(windows) {
                        vec![]
                    } else {
                        vec!["-l".into()]
                    }
                }
            };
            if program.len() > 4096
                || args.len() > 64
                || args.iter().map(String::len).sum::<usize>() > 65536
            {
                return Err(SessionError::new(
                    "too-large",
                    "Terminal command is too large.",
                ));
            }
            let mut all = self.running.lock().unwrap();
            if all.len() >= 8 {
                return Err(SessionError::new("busy", "Too many terminals are running."));
            }
            let id = self.next.fetch_add(1, Ordering::Relaxed);
            let (tx, rx) = mpsc::sync_channel(64);
            let running = Arc::new(Running {
                tx,
                cancel: AtomicBool::new(false),
                input: AtomicUsize::new(0),
                screen: Mutex::new(None),
            });
            all.insert(id, running.clone());
            drop(all);
            let (root, all, environment) = (
                self.root.clone(),
                self.running.clone(),
                self.environment.clone(),
            );
            tokio::task::spawn_blocking(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
                    || -> std::result::Result<(), String> {
                        let dir = std::fs::canonicalize(root.join(cwd))
                            .map_err(|_| "Terminal directory does not exist.")?;
                        if !dir.starts_with(&root) {
                            return Err("Terminal directory leaves the workspace.".into());
                        }
                        let wake = running.tx.clone();
                        let screen = Arc::new(Session::configured(
                            &program,
                            &args,
                            dir.to_str(),
                            cols,
                            rows,
                            1000,
                            Arc::new(move || {
                                let _ = wake.try_send(Command::Changed);
                            }),
                            &environment,
                        )?);
                        *running.screen.lock().unwrap() = Some(screen.clone());
                        if !running.cancel.load(Ordering::Acquire) {
                            out(json!({"ev":"term.ready","key":key,"tid":id}).to_string());
                            drive(&screen, &running, &rx, id, &key, &out);
                        }
                        screen.terminate();
                        Ok(())
                    },
                ));
                if !running.cancel.load(Ordering::Acquire) {
                    if let Err(message) =
                        result.unwrap_or_else(|_| Err("Terminal processing failed.".into()))
                    {
                        out(
                            json!({"ev":"term.failed","key":key,"tid":id,"message":message})
                                .to_string(),
                        );
                    }
                }
                if let Some(screen) = running.screen.lock().unwrap().take() {
                    screen.terminate();
                }
                all.lock().unwrap().remove(&id);
            });
            Ok(id)
        }
        fn command(&self, id: u64, request: &Value) -> Result<()> {
            let running = self
                .running
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or_else(|| SessionError::new("not-found", "No such terminal."))?;
            let mut bytes = 0;
            let command = match request["op"].as_str().unwrap_or("") {
                "term.ack" => Command::Ack,
                "term.visible" => Command::Visible(request["visible"] == true),
                "term.resize" => {
                    let (cols, rows) = dimensions(request)?;
                    Command::Resize(cols, rows)
                }
                "term.scroll" => {
                    Command::Scroll(request["lines"].as_u64().unwrap_or(0).min(1000) as usize)
                }
                "term.write" => {
                    let text = request["data"].as_str().ok_or_else(|| {
                        SessionError::new("bad-request", "Terminal input must be text.")
                    })?;
                    bytes = text.len();
                    if bytes > 65536
                        || running
                            .input
                            .try_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                                n.checked_add(bytes).filter(|n| *n <= INPUT)
                            })
                            .is_err()
                    {
                        return Err(SessionError::new("busy", "Terminal input queue is full."));
                    }
                    Command::Write(text.as_bytes().to_vec())
                }
                _ => {
                    return Err(SessionError::new(
                        "bad-request",
                        "Unknown terminal operation.",
                    ));
                }
            };
            if running.tx.try_send(command).is_err() {
                if bytes > 0 {
                    running.input.fetch_sub(bytes, Ordering::AcqRel);
                }
                return Err(SessionError::new("busy", "Terminal command queue is full."));
            }
            Ok(())
        }
        fn close(&self, id: u64) {
            if let Some(running) = self.running.lock().unwrap().get(&id).cloned() {
                running.cancel.store(true, Ordering::Release);
                let _ = running.tx.try_send(Command::Close);
                let _ = std::thread::Builder::new()
                    .name("terminal-close".into())
                    .spawn(move || {
                        let screen = running.screen.lock().unwrap().clone();
                        if let Some(screen) = screen {
                            screen.terminate();
                        }
                    });
            }
        }
    }
    fn drive(
        screen: &Session,
        running: &Running,
        rx: &Receiver<Command>,
        id: u64,
        key: &str,
        out: &Out,
    ) {
        let mut visible = true;
        let mut inflight = false;
        let mut sent = 0;
        let mut last = Instant::now() - Duration::from_secs(1);
        let mut exit = -1;
        while !running.cancel.load(Ordering::Acquire) {
            let revision = screen.revision();
            let code = screen.exit_code();
            let due = visible && !inflight && (revision != sent || code != exit);
            if due && last.elapsed() >= Duration::from_millis(33) {
                let info = screen.info();
                let dirty = screen.dirty();
                let mut rows = Vec::new();
                for (r, changed) in dirty.iter().enumerate() {
                    if *changed != 0 {
                        let data = screen.row(r as u16);
                        let mut packed = (data.len() as u32).to_le_bytes().to_vec();
                        packed.extend(data);
                        let (text, columns) = screen.copy_row(r as u16);
                        let columns: Vec<u8> =
                            columns.into_iter().flat_map(u16::to_le_bytes).collect();
                        rows.push(json!({"row":r,"runs":B64.encode(packed),"text":text,"columns":B64.encode(columns)}));
                    }
                }
                out(json!({"ev":"term.update","tid":id,"key":key,"revision":revision,"info":B64.encode(info),"rows":rows,"exit":code}).to_string());
                sent = revision;
                exit = code;
                inflight = true;
                last = Instant::now();
            }
            let timeout = if due {
                Some(Duration::from_millis(33).saturating_sub(last.elapsed()))
            } else if screen.output_closed() && exit == -1 {
                Some(Duration::from_millis(20))
            } else {
                None
            };
            let command = match timeout {
                Some(time) => match rx.recv_timeout(time) {
                    Ok(c) => c,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(_) => break,
                },
                None => match rx.recv() {
                    Ok(c) => c,
                    Err(_) => break,
                },
            };
            match command {
                Command::Changed => {}
                Command::Ack => inflight = false,
                Command::Visible(on) => {
                    visible = on;
                    if on {
                        screen.invalidate();
                    }
                }
                Command::Write(data) => {
                    let ok = screen.write(&data);
                    running.input.fetch_sub(data.len(), Ordering::AcqRel);
                    if !ok {
                        break;
                    }
                }
                Command::Resize(cols, rows) => screen.resize(cols, rows),
                Command::Scroll(lines) => {
                    screen.set_scrollback(lines);
                }
                Command::Close => break,
            }
        }
    }
}
#[cfg(feature = "server")]
pub use native::NativeTerminals;
