//! An in-memory backend for the conformance suite and for client tests that need a provider without a VM.
//! It runs two programs: `cat` echoes stdin to stdout, `echo` prints its arguments; `sleep <ms>` waits.
//! `with_program` registers a stand-in for a guest program, so a test can play the part of what runs inside a sandbox.

use crate::*;
use std::{collections::HashMap, pin::Pin, sync::Arc, sync::Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

/// A guest program: the sandbox's name, the command, its stdin and its stdout. Its result is the exit status; stdout closes when it ends.
type Handler = Arc<dyn Fn(String, Command, DuplexStream, DuplexStream) -> Pin<Box<dyn Future<Output = i32> + Send>> + Send + Sync>;

#[derive(Default)]
struct World {
    volumes: HashMap<String, VolumeInfo>,
    sandboxes: HashMap<String, (SandboxSpec, State)>,
    snapshots: Vec<String>,
}

pub struct Fake {
    capabilities: Capabilities,
    world: Mutex<World>,
    programs: HashMap<String, Handler>,
}

impl Fake {
    pub fn new(capabilities: Capabilities) -> Self {
        Self { capabilities, world: Mutex::default(), programs: HashMap::new() }
    }

    /// Runs `handler` whenever a command names `program`, in place of the built-in programs, for both `spawn` and `run`.
    pub fn with_program<F, Fut>(mut self, program: &str, handler: F) -> Self
    where
        F: Fn(String, Command, DuplexStream, DuplexStream) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = i32> + Send + 'static,
    {
        self.programs.insert(program.to_string(), Arc::new(move |name, command, stdin, stdout| Box::pin(handler(name, command, stdin, stdout))));
        self
    }

    fn running(&self, name: &str) -> Result<()> {
        match self.world.lock().unwrap().sandboxes.get(name) {
            None => Err(Error::NotFound),
            Some((_, State::Running)) => Ok(()),
            Some(_) => Err(Error::Unavailable),
        }
    }
}

fn info(spec: &SandboxSpec, state: State) -> SandboxInfo {
    SandboxInfo { name: spec.name.clone(), state, labels: spec.labels.clone() }
}

impl SandboxProvider for Fake {
    fn capabilities(&self) -> Capabilities {
        self.capabilities.clone()
    }

    async fn create_volume(&self, spec: VolumeSpec) -> Result<VolumeInfo> {
        if !self.capabilities.persistent_volumes {
            return Err(Error::Unsupported("persistent volumes"));
        }
        if spec.name.is_empty() || spec.size_mib == 0 || spec.size_mib < self.capabilities.min_volume_mib {
            return Err(Error::Invalid("A volume needs a name and a size the backend can format.".into()));
        }
        let mut world = self.world.lock().unwrap();
        if let Some(existing) = world.volumes.get(&spec.name) {
            return if existing.size_mib == spec.size_mib { Ok(existing.clone()) } else { Err(Error::Conflict("The volume exists with another size.".into())) };
        }
        let made = VolumeInfo { name: spec.name.clone(), size_mib: spec.size_mib, path: None };
        world.volumes.insert(spec.name, made.clone());
        Ok(made)
    }

    async fn volume(&self, name: &str) -> Result<Option<VolumeInfo>> {
        Ok(self.world.lock().unwrap().volumes.get(name).cloned())
    }

    async fn remove_volume(&self, name: &str) -> Result<()> {
        let mut world = self.world.lock().unwrap();
        let mounted = world.sandboxes.values().any(|(spec, _)| spec.mounts.iter().any(|m| m.source == Source::Volume(name.into())));
        if mounted {
            return Err(Error::Conflict("A sandbox still mounts the volume.".into()));
        }
        world.volumes.remove(name);
        Ok(())
    }

    async fn create(&self, spec: SandboxSpec) -> Result<SandboxInfo> {
        if spec.name.is_empty() || spec.cpus == 0 || spec.memory_mib == 0 {
            return Err(Error::Invalid("A sandbox needs a name, cpus and memory.".into()));
        }
        if spec.gpu.is_some() && !self.capabilities.gpu {
            return Err(Error::Unsupported("gpu"));
        }
        if let Network::Allow(hosts) = &spec.network {
            if !self.capabilities.network_allowlist {
                return Err(Error::Unsupported("network allowlist"));
            }
            if hosts.iter().any(|h| h.is_empty() || h.contains(|c: char| c == ',' || c == '@' || c.is_whitespace())) {
                return Err(Error::Invalid("An allowlist entry is not a host.".into()));
            }
        }
        let mut world = self.world.lock().unwrap();
        if let Template::Snapshot(snapshot) = &spec.template {
            if !self.capabilities.snapshots {
                return Err(Error::Unsupported("snapshots"));
            }
            if !world.snapshots.contains(&snapshot.0) {
                return Err(Error::NotFound);
            }
        }
        for mount in &spec.mounts {
            if let Source::Volume(name) = &mount.source {
                if !world.volumes.contains_key(name) {
                    return Err(Error::NotFound);
                }
            }
        }
        if let Some((existing, state)) = world.sandboxes.get(&spec.name) {
            return if *existing == spec { Ok(info(existing, *state)) } else { Err(Error::Conflict("The name is in use with a different spec.".into())) };
        }
        let limit = self.capabilities.max_sandboxes as usize;
        if limit > 0 && world.sandboxes.len() >= limit {
            return Err(Error::Unavailable);
        }
        let made = info(&spec, State::Running);
        world.sandboxes.insert(spec.name.clone(), (spec, State::Running));
        Ok(made)
    }

    async fn get(&self, name: &str) -> Result<Option<SandboxInfo>> {
        Ok(self.world.lock().unwrap().sandboxes.get(name).map(|(spec, state)| info(spec, *state)))
    }

    async fn list(&self, selector: &Labels) -> Result<Vec<SandboxInfo>> {
        let world = self.world.lock().unwrap();
        let mut found: Vec<_> = world
            .sandboxes
            .values()
            .filter(|(spec, _)| selector.iter().all(|(k, v)| spec.labels.get(k) == Some(v)))
            .map(|(spec, state)| info(spec, *state))
            .collect();
        found.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(found)
    }

    async fn ping(&self, name: &str) -> Result<()> {
        self.running(name)
    }

    async fn stop(&self, name: &str) -> Result<()> {
        match self.world.lock().unwrap().sandboxes.get_mut(name) {
            Some((_, state)) => {
                *state = State::Stopped;
                Ok(())
            }
            None => Err(Error::NotFound),
        }
    }

    async fn remove(&self, name: &str) -> Result<()> {
        self.world.lock().unwrap().sandboxes.remove(name);
        Ok(())
    }

    async fn spawn(&self, name: &str, command: Command) -> Result<Process> {
        self.running(name)?;
        let (stdin, mut input) = tokio::io::duplex(64 * 1024);
        let (mut output, stdout) = tokio::io::duplex(64 * 1024);
        let (done, exit) = tokio::sync::oneshot::channel();
        if let Some(handler) = self.programs.get(&command.program).cloned() {
            let sandbox = name.to_string();
            tokio::spawn(async move {
                let _ = done.send(handler(sandbox, command, input, output).await);
            });
            return Ok(Process { stdin: Box::new(stdin), stdout: Box::new(stdout), exit });
        }
        tokio::spawn(async move {
            let status = match command.program.as_str() {
                "cat" => {
                    let _ = tokio::io::copy(&mut input, &mut output).await;
                    0
                }
                "echo" => {
                    let _ = output.write_all(format!("{}\n", command.args.join(" ")).as_bytes()).await;
                    0
                }
                _ => 127,
            };
            drop(output);
            let _ = done.send(status);
        });
        Ok(Process { stdin: Box::new(stdin), stdout: Box::new(stdout), exit })
    }

    async fn run(&self, name: &str, command: Command, limit: usize, within: Duration) -> Result<Output> {
        self.running(name)?;
        if let Some(handler) = self.programs.get(&command.program).cloned() {
            let (stdin, input) = tokio::io::duplex(64 * 1024);
            let (output, mut stdout) = tokio::io::duplex(64 * 1024);
            drop(stdin);
            let sandbox = name.to_string();
            let work = async move {
                let status = tokio::spawn(handler(sandbox, command, input, output));
                let mut captured = Vec::new();
                stdout.read_to_end(&mut captured).await.map_err(|_| Error::Unavailable)?;
                Ok::<_, Error>((status.await.map_err(|_| Error::Unavailable)?, captured))
            };
            let (status, captured) = tokio::time::timeout(within, work).await.map_err(|_| Error::Timeout)??;
            if captured.len() > limit {
                return Err(Error::Invalid("The output passed its limit.".into()));
            }
            return Ok(Output { status, stdout: captured, stderr: Vec::new() });
        }
        let work = async {
            match command.program.as_str() {
                "echo" => Ok(Output { status: 0, stdout: format!("{}\n", command.args.join(" ")).into_bytes(), stderr: Vec::new() }),
                "cat" => Ok(Output { status: 0, stdout: Vec::new(), stderr: Vec::new() }),
                "sleep" => {
                    let millis = command.args.first().and_then(|a| a.parse().ok()).unwrap_or(0);
                    tokio::time::sleep(Duration::from_millis(millis)).await;
                    Ok(Output { status: 0, stdout: Vec::new(), stderr: Vec::new() })
                }
                _ => Ok(Output { status: 127, stdout: Vec::new(), stderr: b"not found\n".to_vec() }),
            }
        };
        let output: Output = tokio::time::timeout(within, work).await.map_err(|_| Error::Timeout)??;
        if output.stdout.len() > limit || output.stderr.len() > limit {
            return Err(Error::Invalid("The output passed its limit.".into()));
        }
        Ok(output)
    }

    async fn detach(&self, name: &str, _command: Command) -> Result<()> {
        self.running(name)
    }

    async fn copy_in(&self, name: &str, host: PathBuf, _guest: &str) -> Result<()> {
        self.running(name)?;
        if std::fs::metadata(&host).is_err() {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    async fn snapshot(&self, name: &str) -> Result<SnapshotRef> {
        if !self.capabilities.snapshots {
            return Err(Error::Unsupported("snapshots"));
        }
        let mut world = self.world.lock().unwrap();
        if !world.sandboxes.contains_key(name) {
            return Err(Error::NotFound);
        }
        let made = format!("snap-{name}-{}", world.snapshots.len());
        world.snapshots.push(made.clone());
        Ok(SnapshotRef(made))
    }

    async fn remove_snapshot(&self, snapshot: &SnapshotRef) -> Result<()> {
        self.world.lock().unwrap().snapshots.retain(|s| *s != snapshot.0);
        Ok(())
    }

    async fn verify_snapshot(&self, snapshot: &SnapshotRef) -> Result<()> {
        if !self.capabilities.snapshots {
            return Err(Error::Unsupported("snapshots"));
        }
        if self.world.lock().unwrap().snapshots.contains(&snapshot.0) { Ok(()) } else { Err(Error::NotFound) }
    }
}
