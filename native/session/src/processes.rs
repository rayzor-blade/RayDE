//! Programs run as child processes of the server, in directories of the workspace.
use crate::{
    error::{Result, SessionError},
    session::{Out, Programs},
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde_json::json;
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}},
};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, process::Command, sync::mpsc};

struct Running {
    /// Bytes for the program's stdin; `None` closes it.
    input: mpsc::UnboundedSender<Option<Vec<u8>>>,
    os_id: Option<u32>,
}

pub struct ChildPrograms {
    root: PathBuf,
    running: Arc<Mutex<HashMap<u64, Running>>>,
    next: AtomicU64,
    limit: usize,
    extensions: Option<serde_json::Value>,
}

impl ChildPrograms {
    pub fn new(root: PathBuf, limit: usize) -> Self {
        let root = std::fs::canonicalize(&root).unwrap_or(root);
        Self { root, running: Arc::new(Mutex::new(HashMap::new())), next: AtomicU64::new(1), limit, extensions: None }
    }

    pub fn with_extensions(mut self, host: PathBuf, root: Option<PathBuf>) -> Self {
        self.extensions = Some(json!({"host": host, "root": root}));
        self
    }

    pub fn running(&self) -> usize {
        self.running.lock().unwrap().len()
    }
}

async fn pump(mut reader: impl AsyncReadExt + Unpin, stream: &'static str, id: u64, emit: Out) {
    let mut buffer = vec![0u8; 16 * 1024];
    while let Ok(n) = reader.read(&mut buffer).await {
        if n == 0 {
            break;
        }
        emit(json!({"ev": "proc.out", "pid": id, "stream": stream, "data": B64.encode(&buffer[..n])}).to_string());
    }
}

impl Programs for ChildPrograms {
    fn extensions(&self) -> Option<serde_json::Value> { self.extensions.clone() }
    fn spawn(&self, command: &str, args: &[String], cwd: &str, env: &HashMap<String, String>, emit: Out) -> Result<u64> {
        if command.is_empty() {
            return Err(SessionError::new("bad-request", "The command is empty."));
        }
        if self.running() >= self.limit {
            return Err(SessionError::new("busy", "Too many programs are running."));
        }
        // The directory is resolved first, so a symlink inside the workspace cannot lead a program out of it.
        let directory = std::fs::canonicalize(self.root.join(cwd)).map_err(|_| SessionError::new("not-found", "The directory does not exist."))?;
        if !directory.starts_with(&self.root) {
            return Err(SessionError::new("outside", "The path leaves the workspace."));
        }
        let mut child = Command::new(command)
            .args(args)
            .envs(env)
            .current_dir(directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| SessionError::new("spawn-failed", error.to_string()))?;
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (input, mut queue) = mpsc::unbounded_channel::<Option<Vec<u8>>>();
        self.running.lock().unwrap().insert(id, Running { input, os_id: child.id() });
        let mut stdin = child.stdin.take();
        let (stdout, stderr) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
        let running = self.running.clone();
        tokio::spawn(async move {
            let writer = async {
                while let Some(item) = queue.recv().await {
                    match item {
                        Some(data) => {
                            if let Some(pipe) = stdin.as_mut() {
                                if pipe.write_all(&data).await.is_err() {
                                    break;
                                }
                            }
                        }
                        None => stdin = None,
                    }
                }
            };
            let output = async { tokio::join!(pump(stdout, "stdout", id, emit.clone()), pump(stderr, "stderr", id, emit.clone())) };
            let wait = async {
                let status = child.wait().await;
                status.ok()
            };
            tokio::pin!(writer, output, wait);
            let mut status = None;
            let (mut output_done, mut writer_done) = (false, false);
            loop {
                tokio::select! {
                    _ = &mut writer, if !writer_done => { writer_done = true; }
                    _ = &mut output, if !output_done => { output_done = true; }
                    result = &mut wait, if status.is_none() => { status = Some(result); }
                }
                if status.is_some() && output_done {
                    break;
                }
            }
            running.lock().unwrap().remove(&id);
            let status = status.flatten();
            #[cfg(unix)]
            let signal = { use std::os::unix::process::ExitStatusExt; status.and_then(|s| s.signal()) };
            #[cfg(not(unix))]
            let signal: Option<i32> = None;
            emit(json!({"ev": "proc.exit", "pid": id, "code": status.and_then(|s| s.code()), "signal": signal}).to_string());
        });
        Ok(id)
    }

    fn write(&self, id: u64, data: &[u8]) -> Result<()> {
        let running = self.running.lock().unwrap();
        let program = running.get(&id).ok_or_else(|| SessionError::new("not-found", "No such program."))?;
        program.input.send(Some(data.to_vec())).map_err(|_| SessionError::new("not-found", "The program has ended."))
    }

    fn close_input(&self, id: u64) -> Result<()> {
        let running = self.running.lock().unwrap();
        let program = running.get(&id).ok_or_else(|| SessionError::new("not-found", "No such program."))?;
        let _ = program.input.send(None);
        Ok(())
    }

    fn kill(&self, id: u64, signal: &str) -> Result<()> {
        let running = self.running.lock().unwrap();
        let program = running.get(&id).ok_or_else(|| SessionError::new("not-found", "No such program."))?;
        #[cfg(unix)]
        if let Some(pid) = program.os_id {
            let number = match signal.trim_start_matches("SIG") {
                "KILL" => libc::SIGKILL,
                "INT" => libc::SIGINT,
                "HUP" => libc::SIGHUP,
                "TERM" => libc::SIGTERM,
                _ => return Err(SessionError::new("bad-request", "The signal is not one of TERM, INT, HUP or KILL.")),
            };
            // SAFETY: `kill` takes a process id and a signal number and touches no memory of ours.
            unsafe { libc::kill(pid as i32, number) };
        }
        #[cfg(not(unix))]
        let _ = (program, signal);
        Ok(())
    }
}
