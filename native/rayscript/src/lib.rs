//! An embedded extension VM, confined to one thread; only owned messages cross the ABI.
use rayscript_host::{Config, Host, PROTOCOL};
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicI32, Ordering},
        mpsc,
    },
    thread,
    time::Instant,
};

enum Command {
    Message(String),
    CloseView(u32),
    Collect,
    Shutdown,
    Wake,
}

struct Runtime {
    input: mpsc::Sender<Command>,
    output: Mutex<Vec<String>>,
    // 0 running, 1 stopped normally, 2 failed.
    status: AtomicI32,
}

impl Runtime {
    fn start(root: Option<PathBuf>) -> std::io::Result<Arc<Self>> {
        let (tx, rx) = mpsc::channel();
        let runtime = Arc::new(Self {
            input: tx.clone(),
            output: Mutex::new(Vec::new()),
            status: AtomicI32::new(0),
        });
        let worker = runtime.clone();
        thread::Builder::new().name("rayde-extension".into()).stack_size(64 << 20).spawn(move || {
            let result = catch_unwind(AssertUnwindSafe(|| {
                let mut host = Host::new(Config { root, ..Config::default() });
                host.vm().set_native_waker(Arc::new(move || { let _ = tx.send(Command::Wake); }));
                worker.push(format!("{{\"t\":\"ready\",\"protocol\":{PROTOCOL}}}"));
                let mut next = None;
                loop {
                    let mut collect = false;
                    let mut shutdown = false;
                    // Bound input work so a busy producer cannot starve fibers.
                    for _ in 0..64 {
                        let command = next.take().or_else(|| rx.try_recv().ok());
                        match command {
                            Some(Command::Message(line)) => host.handle_line(&line),
                            Some(Command::CloseView(root)) => {
                                host.vm().view_unmount(root);
                                collect = true;
                            }
                            Some(Command::Collect) => collect = true,
                            Some(Command::Shutdown) => { shutdown = true; break; }
                            Some(Command::Wake) => {},
                            None => break,
                        }
                    }
                    if shutdown || host.is_shutdown() {
                        host.vm().cancel_all();
                        for (root, _) in host.vm().view_mounts() {
                            host.vm().view_unmount(root);
                        }
                        // Cleanup callbacks may spawn work; cancel it before the final scheduler round.
                        host.vm().cancel_all();
                        host.pump();
                        worker.output.lock().unwrap().extend(host.take_output());
                        // Vm::drop drains native calls before releasing their libraries and heap.
                        break;
                    }
                    let more = host.pump();
                    if collect {
                        host.vm().collect();
                        let vm = host.vm();
                        let heap = vm.heap_stats();
                        worker.push(format!("{{\"t\":\"collected\",\"collections\":{},\"objects\":{},\"bytes\":{},\"fibers\":{}}}",
                            vm.collections(), heap.objects, heap.bytes, vm.fiber_count()));
                    }
                    worker.output.lock().unwrap().extend(host.take_output());
                    if more { continue; }
                    next = match host.next_wake() {
                        Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                            Ok(command) => Some(command),
                            Err(mpsc::RecvTimeoutError::Timeout) => None,
                            Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        },
                        None => match rx.recv() { Ok(command) => Some(command), Err(_) => break },
                    };
                }
            }));
            if result.is_err() {
                worker.push("{\"t\":\"error\",\"kind\":\"host\",\"message\":\"Embedded extension runtime panicked\"}".into());
            }
            worker.status.store(if result.is_ok() { 1 } else { 2 }, Ordering::Release);
        })?;
        Ok(runtime)
    }

    fn push(&self, line: String) {
        self.output.lock().unwrap().push(line);
    }
}

#[cfg(not(test))]
mod ffi;

#[cfg(test)]
mod tests;
