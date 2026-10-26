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
    sync::{Arc, Mutex, atomic::{AtomicU64, AtomicUsize, Ordering}},
};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, process::Command, sync::mpsc};

struct Running {
    /// Bytes for the program's stdin; `None` closes it.
    input: mpsc::Sender<Option<Vec<u8>>>,
    input_bytes: Arc<AtomicUsize>,
    input_closed: bool,
    os_id: Option<u32>,
    #[cfg(not(unix))]
    kill: mpsc::Sender<()>,
}

const MAX_INPUT: usize = 8 * 1024 * 1024;

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
        // The directory is resolved first, so a symlink inside the workspace cannot lead a program out of it.
        let directory = std::fs::canonicalize(self.root.join(cwd)).map_err(|_| SessionError::new("not-found", "The directory does not exist."))?;
        if !directory.starts_with(&self.root) {
            return Err(SessionError::new("outside", "The path leaves the workspace."));
        }
        let mut processes = self.running.lock().unwrap();
        if processes.len() >= self.limit {
            return Err(SessionError::new("busy", "Too many programs are running."));
        }
        let mut command_line = Command::new(command);
        command_line.args(args)
            .envs(env)
            .current_dir(directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        #[cfg(unix)]
        command_line.process_group(0);
        let mut child = command_line.spawn()
            .map_err(|error| SessionError::new("spawn-failed", error.to_string()))?;
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (input, mut queue) = mpsc::channel::<Option<Vec<u8>>>(128);
        let input_bytes = Arc::new(AtomicUsize::new(0));
        let os_id = child.id();
        #[cfg(not(unix))]
        let (kill, mut killed) = mpsc::channel::<()>(1);
        processes.insert(id, Running { input, input_bytes:input_bytes.clone(), input_closed:false, os_id, #[cfg(not(unix))] kill });
        drop(processes);
        let mut stdin = child.stdin.take();
        let (stdout, stderr) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
        let running = self.running.clone();
        tokio::spawn(async move {
            let writer = async {
                while let Some(item) = queue.recv().await {
                    match item {
                        Some(data) => {
                            let count = data.len();
                            if let Some(pipe) = stdin.as_mut() {
                                let result = pipe.write_all(&data).await;
                                input_bytes.fetch_sub(count, Ordering::AcqRel);
                                if result.is_err() {
                                    break;
                                }
                            } else {
                                input_bytes.fetch_sub(count, Ordering::AcqRel);
                            }
                        }
                        None => stdin = None,
                    }
                }
            };
            let output = async { tokio::join!(pump(stdout, "stdout", id, emit.clone()), pump(stderr, "stderr", id, emit.clone())) };
            let wait = async {
                #[cfg(unix)]
                let status = child.wait().await;
                #[cfg(not(unix))]
                let status = tokio::select! {
                    status = child.wait() => status,
                    _ = killed.recv() => { let _ = child.start_kill(); child.wait().await }
                };
                // Descendants inherit the group's pipes and must not outlive its owning program.
                #[cfg(unix)]
                if let Some(pid) = os_id { unsafe { libc::kill(-(pid as i32),libc::SIGKILL); } }
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
        if program.input_closed {
            return Err(SessionError::new("closed-input", "The program input is closed."));
        }
        program.input_bytes.try_update(Ordering::AcqRel,Ordering::Acquire,|size| size.checked_add(data.len()).filter(|size| *size <= MAX_INPUT))
            .map_err(|_| SessionError::new("input-full", "The program input queue is full."))?;
        if let Err(error) = program.input.try_send(Some(data.to_vec())) {
            program.input_bytes.fetch_sub(data.len(),Ordering::AcqRel);
            return Err(match error {
                mpsc::error::TrySendError::Full(_) => SessionError::new("input-full", "The program input queue is full."),
                mpsc::error::TrySendError::Closed(_) => SessionError::new("not-found", "The program has ended."),
            });
        }
        Ok(())
    }

    fn close_input(&self, id: u64) -> Result<()> {
        let mut running = self.running.lock().unwrap();
        let program = running.get_mut(&id).ok_or_else(|| SessionError::new("not-found", "No such program."))?;
        if program.input_closed { return Ok(()); }
        program.input.try_send(None).map_err(|_| SessionError::new("input-full", "The program input queue is unavailable."))?;
        program.input_closed = true;
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
            unsafe { libc::kill(-(pid as i32), number) };
        }
        #[cfg(not(unix))]
        {
            if !["KILL", "SIGKILL", "TERM", "SIGTERM"].contains(&signal) {
                return Err(SessionError::new("bad-request", "This host supports TERM and KILL."));
            }
            let _ = program.kill.try_send(());
        }
        Ok(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::time::Duration;

    async fn ended(programs: &ChildPrograms) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while programs.running() != 0 { tokio::time::sleep(Duration::from_millis(5)).await; }
        }).await.expect("programs and their output pipes close");
    }

    #[tokio::test]
    async fn blocked_input_is_bounded_and_close_refuses_more_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let programs = ChildPrograms::new(dir.path().into(), 1);
        let id = programs.spawn("/bin/sh", &["-c".into(),"sleep 20".into()], "", &HashMap::new(), Arc::new(|_| {})).unwrap();
        let bytes = vec![0u8; MAX_INPUT/2];
        programs.write(id,&bytes).unwrap(); programs.write(id,&bytes).unwrap();
        assert_eq!(programs.write(id,b"overflow").unwrap_err().code,"input-full");
        programs.close_input(id).unwrap();
        assert_eq!(programs.write(id,b"late").unwrap_err().code,"closed-input");
        programs.kill(id,"KILL").unwrap(); ended(&programs).await;
    }

    #[tokio::test]
    async fn killing_a_program_closes_descendant_pipes_and_releases_its_slot() {
        let dir = tempfile::tempdir().unwrap();
        let programs = ChildPrograms::new(dir.path().into(), 1);
        let ready = Arc::new(tokio::sync::Notify::new());
        let signal = ready.clone();
        let id = programs.spawn("/bin/sh", &["-c".into(),"sleep 20 & echo ready; wait".into()], "", &HashMap::new(), Arc::new(move |message| {
            if message.contains("proc.out") { signal.notify_one(); }
        })).unwrap();
        tokio::time::timeout(Duration::from_secs(3),ready.notified()).await.unwrap();
        programs.kill(id,"KILL").unwrap(); ended(&programs).await;
        let next = programs.spawn("/bin/echo", &["next".into()], "", &HashMap::new(), Arc::new(|_| {}));
        assert!(next.is_ok(),"the process slot is reusable after descendants exit");
        ended(&programs).await;
    }

    #[tokio::test]
    async fn concurrent_starts_respect_the_process_limit() {
        let dir = tempfile::tempdir().unwrap();
        let programs = Arc::new(ChildPrograms::new(dir.path().into(), 1));
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let runtime = tokio::runtime::Handle::current();
        let mut threads = Vec::new();
        for _ in 0..2 {
            let (programs,barrier,runtime) = (programs.clone(),barrier.clone(),runtime.clone());
            threads.push(std::thread::spawn(move || {
                let _runtime = runtime.enter(); barrier.wait();
                programs.spawn("/bin/sleep", &["20".into()], "", &HashMap::new(), Arc::new(|_| {}))
            }));
        }
        barrier.wait();
        let results: Vec<_> = threads.into_iter().map(|thread| thread.join().unwrap()).collect();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(),1);
        for id in results.into_iter().flatten() { programs.kill(id,"KILL").unwrap(); }
        ended(&programs).await;
    }
}
