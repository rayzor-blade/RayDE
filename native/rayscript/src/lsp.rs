//! Process-owned LSP pipes. Workers exchange owned bytes, never HashLink objects.
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, VecDeque},
    io::{self, BufRead, BufReader, Read, Write},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

const MAX_MESSAGE: usize = 16 << 20;
const MAX_QUEUE: usize = 32 << 20;
static CLIENTS: Mutex<BTreeMap<i32, Arc<Client>>> = Mutex::new(BTreeMap::new());
static NEXT: AtomicI32 = AtomicI32::new(1);

struct Client {
    input: mpsc::SyncSender<String>,
    input_bytes: AtomicUsize,
    output: Mutex<(VecDeque<String>, usize)>,
    child: Mutex<Option<Child>>,
    stopped: AtomicBool,
}

impl Client {
    fn push(&self, event: String) -> bool {
        if self.stopped.load(Ordering::Acquire) {
            return false;
        }
        let mut queue = self.output.lock().unwrap();
        if queue.1 + event.len() > MAX_QUEUE {
            return false;
        }
        queue.1 += event.len();
        queue.0.push_back(event);
        true
    }

    fn finish(&self, error: String) {
        if !self.stopped.swap(true, Ordering::AcqRel) {
            let event = json!({"t":"error", "message":error}).to_string();
            let mut queue = self.output.lock().unwrap();
            // Keep the terminal event even if a noisy server filled the queue.
            if queue.1 + event.len() > MAX_QUEUE {
                queue.0.clear();
                queue.1 = 0;
            }
            queue.1 += event.len();
            queue.0.push_back(event);
        }
        self.reap();
    }

    fn reap(&self) {
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// stderr entries are complete lines, so display prefixes cannot split SGR sequences or UTF-8.
#[derive(Default)]
struct StderrLines {
    pending: Vec<u8>,
}

impl StderrLines {
    fn push(&mut self, bytes: &[u8]) -> Vec<String> {
        const LIMIT: usize = 64 << 10;
        self.pending.extend_from_slice(bytes);
        let mut lines = Vec::new();
        while let Some(end) = self.pending.iter().position(|b| *b == b'\n') {
            let mut line: Vec<u8> = self.pending.drain(..=end).collect();
            line.pop();
            if line.last() == Some(&b'\r') { line.pop(); }
            lines.push(String::from_utf8_lossy(&line).into_owned());
        }
        // Bound unterminated lines, retaining a short escape sequence and any partial UTF-8 suffix.
        while self.pending.len() > LIMIT {
            let mut cut = LIMIT;
            if let Some(at) = self.pending[LIMIT - 256..LIMIT].iter().rposition(|b| *b == 27) {
                cut = LIMIT - 256 + at;
            }
            while cut > 0 && self.pending[cut] & 0xc0 == 0x80 { cut -= 1; }
            lines.push(String::from_utf8_lossy(&self.pending[..cut]).into_owned());
            self.pending.drain(..cut);
        }
        lines
    }

    fn finish(&mut self) -> Option<String> {
        if self.pending.is_empty() { None }
        else { Some(String::from_utf8_lossy(&std::mem::take(&mut self.pending)).into_owned()) }
    }
}

fn read_message(reader: &mut impl BufRead) -> io::Result<Option<String>> {
    let mut length = None;
    let mut headers = 0;
    loop {
        let mut line = String::new();
        // Bound headers even when the server never sends a newline.
        let read = reader.take(8193).read_line(&mut line)?;
        if read == 0 && headers == 0 {
            return Ok(None);
        }
        headers += read;
        if read == 0 || headers > 8192 || !line.ends_with('\n') {
            return Err(io::Error::other("Invalid LSP header"));
        }
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("Content-Length") {
                if length.is_some() {
                    return Err(io::Error::other("Duplicate Content-Length"));
                }
                length = Some(value.trim().parse::<usize>().map_err(io::Error::other)?);
            }
        }
    }
    let length = length
        .filter(|n| *n > 0 && *n <= MAX_MESSAGE)
        .ok_or_else(|| io::Error::other("Invalid LSP Content-Length"))?;
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    let body = String::from_utf8(body).map_err(io::Error::other)?;
    let value: Value = serde_json::from_str(&body).map_err(io::Error::other)?;
    if !value.is_object() {
        return Err(io::Error::other("Expected LSP JSON object"));
    }
    Ok(Some(body))
}

pub fn open(config: &str) -> Result<i32, String> {
    let config: Value = serde_json::from_str(config).map_err(|e| e.to_string())?;
    let command = config["command"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("Missing server command")?
        .to_owned();
    let cwd = config["cwd"]
        .as_str()
        .ok_or("Missing server directory")?
        .to_owned();
    let args: Vec<String> = config["args"]
        .as_array()
        .ok_or("Missing server arguments")?
        .iter()
        .map(|s| {
            s.as_str()
                .map(str::to_owned)
                .ok_or("Invalid server argument")
        })
        .collect::<Result<_, _>>()?;
    let mut env = BTreeMap::new();
    if let Some(values) = config["env"].as_object() {
        for (key, value) in values {
            env.insert(
                key.clone(),
                value
                    .as_str()
                    .ok_or("Invalid server environment")?
                    .to_owned(),
            );
        }
    }
    let (tx, rx) = mpsc::sync_channel::<String>(128);
    let client = Arc::new(Client {
        input: tx,
        input_bytes: AtomicUsize::new(0),
        output: Mutex::new((VecDeque::new(), 0)),
        child: Mutex::new(None),
        stopped: AtomicBool::new(false),
    });
    let handle = NEXT.fetch_add(1, Ordering::Relaxed);
    if handle <= 0 {
        return Err("LSP handles exhausted".into());
    }
    CLIENTS.lock().unwrap().insert(handle, client.clone());
    let worker = client.clone();
    let spawned = thread::Builder::new().name("rayde-lsp-reader".into()).spawn(move || {
        let work = || -> io::Result<()> {
            if worker.stopped.load(Ordering::Acquire) { return Ok(()); }
            let mut child = Command::new(command).args(args).envs(env).current_dir(cwd)
                .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
            let mut stdin = child.stdin.take().unwrap();
            let stdout = child.stdout.take().unwrap();
            let mut stderr = child.stderr.take().unwrap();
            *worker.child.lock().unwrap() = Some(child);
            if worker.stopped.load(Ordering::Acquire) { return Ok(()); }
            let writer = worker.clone();
            thread::Builder::new().name("rayde-lsp-writer".into()).spawn(move || {
                while !writer.stopped.load(Ordering::Acquire) {
                    match rx.recv_timeout(Duration::from_millis(100)) {
                        Ok(body) => {
                            writer.input_bytes.fetch_sub(body.len(), Ordering::AcqRel);
                            let frame = format!("Content-Length: {}\r\n\r\n{}", body.len(), body);
                            if let Err(error) = stdin.write_all(frame.as_bytes()).and_then(|_| stdin.flush()) {
                                writer.finish(error.to_string()); break;
                            }
                        },
                        Err(mpsc::RecvTimeoutError::Timeout) => {},
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
            })?;
            let logger = worker.clone();
            thread::Builder::new().name("rayde-lsp-stderr".into()).spawn(move || {
                let mut bytes = [0; 4096];
                let mut lines = StderrLines::default();
                while let Ok(size) = stderr.read(&mut bytes) {
                    if size == 0 || logger.stopped.load(Ordering::Acquire) { break; }
                    for message in lines.push(&bytes[..size]) {
                        logger.push(json!({"t":"stderr", "message":message}).to_string());
                    }
                }
                if let Some(message) = lines.finish() {
                    logger.push(json!({"t":"stderr", "message":message}).to_string());
                }
            })?;
            worker.push("{\"t\":\"connected\"}".into());
            let mut reader = BufReader::new(stdout);
            while !worker.stopped.load(Ordering::Acquire) {
                let Some(body) = read_message(&mut reader)? else { return Err(io::Error::other("Language server closed stdout")); };
                if !worker.push(format!("{{\"t\":\"message\",\"body\":{body}}}")) {
                    return Err(io::Error::other("Language server output queue exceeded its limit"));
                }
            }
            Ok(())
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work));
        worker.finish(match result { Ok(Err(e)) => e.to_string(), Err(_) => "LSP worker panicked".into(), _ => "Language server stopped".into() });
    });
    if let Err(error) = spawned {
        CLIENTS.lock().unwrap().remove(&handle);
        return Err(error.to_string());
    }
    Ok(handle)
}

pub fn send(handle: i32, body: &str) -> bool {
    let client = CLIENTS.lock().unwrap().get(&handle).cloned();
    let Some(client) = client else {
        return false;
    };
    if body.len() > MAX_MESSAGE || client.stopped.load(Ordering::Acquire) {
        return false;
    }
    if client
        .input_bytes
        .try_update(Ordering::AcqRel, Ordering::Acquire, |size| {
            size.checked_add(body.len()).filter(|n| *n <= MAX_QUEUE)
        })
        .is_err()
    {
        return false;
    }
    if client.input.try_send(body.to_owned()).is_err() {
        client.input_bytes.fetch_sub(body.len(), Ordering::AcqRel);
        return false;
    }
    true
}

pub fn poll(handle: i32) -> Option<String> {
    let client = CLIENTS.lock().unwrap().get(&handle).cloned()?;
    let mut queue = client.output.lock().unwrap();
    if queue.0.is_empty() {
        return None;
    }
    let mut batch = Vec::new();
    let mut size = 0;
    while let Some(event) = queue.0.pop_front() {
        size += event.len();
        queue.1 -= event.len();
        batch.push(event);
        if size >= 256 << 10 || batch.len() >= 64 {
            break;
        }
    }
    Some(format!("[{}]", batch.join(",")))
}

pub fn close(handle: i32) {
    if let Some(client) = CLIENTS.lock().unwrap().remove(&handle) {
        client.stopped.store(true, Ordering::Release);
        // Process exit and reaping must not block the caller's UI thread.
        let _ = thread::Builder::new()
            .name("rayde-lsp-close".into())
            .spawn(move || client.reap());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stderr_lines_preserve_split_ansi_and_utf8() {
        let expected = "\x1b[31mλ😀\x1b[0m";
        let mut lines = StderrLines::default();
        let bytes = format!("{expected}\r\ntrailing");
        let mut found = Vec::new();
        for byte in bytes.as_bytes() { found.extend(lines.push(&[*byte])); }
        assert_eq!(found, vec![expected.to_string()]);
        assert_eq!(lines.finish().as_deref(), Some("trailing"));
        assert_eq!(lines.finish(), None);
    }

    #[test]
    fn stderr_unterminated_lines_are_bounded_without_splitting_a_color() {
        let mut lines = StderrLines::default();
        let prefix = "x".repeat((64 << 10) - 2);
        let text = format!("{prefix}\x1b[31mred\x1b[0m");
        let found = lines.push(text.as_bytes());
        assert_eq!(found, vec![prefix]);
        assert_eq!(lines.finish().as_deref(), Some("\x1b[31mred\x1b[0m"));
    }

    #[test]
    fn frames_use_bytes_and_survive_partial_reads() {
        let text = "{\"text\":\"λ😀\"}";
        let bytes = format!(
            "Content-Length: {}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{text}",
            text.len()
        );
        let mut reader = BufReader::with_capacity(1, bytes.as_bytes());
        assert_eq!(read_message(&mut reader).unwrap(), Some(text.into()));
        assert!(read_message(&mut reader).unwrap().is_none());
    }
    #[test]
    fn malformed_and_unbounded_frames_are_rejected() {
        for frame in [
            "Content-Length: 16777217\r\n\r\n",
            "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            "Content-Length: 20\r\n\r\n{}",
            "Content-Length: 2\r\n\r\n[]",
        ] {
            assert!(read_message(&mut BufReader::new(frame.as_bytes())).is_err());
        }
        assert!(read_message(&mut BufReader::new(vec![b'x'; 9000].as_slice())).is_err());
    }
}
