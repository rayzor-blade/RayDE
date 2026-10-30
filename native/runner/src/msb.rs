//! MSB as a `rayde_sandbox::SandboxProvider`: each call is the `msb` command the runner already runs for that need. The runner's own
//! service code does not use it yet.

use crate::{
    Config,
    command::{self, Process},
};
use rayde_sandbox as sb;
use std::{process::Stdio, time::Duration};
use tokio::io::AsyncReadExt;

/// The smallest disk volume MSB 0.7.11 formats (found by bisection on the NUC: 67 MiB fails, 68 works).
const MIN_VOLUME_MIB: u32 = 68;

pub struct Msb {
    config: Config,
}

impl Msb {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    async fn call(&self, args: Vec<String>, seconds: u64) -> sb::Result<Vec<u8>> {
        let shown = std::env::var_os("RAYDE_MSB_TRACE").map(|_| args.join(" "));
        let result = command::call(&self.config, args, seconds).await.map_err(|_| sb::Error::Unavailable);
        if let (Some(shown), Err(_)) = (shown, &result) {
            eprintln!("msb failed: {shown}");
        }
        result
    }

    /// `msb status` rows: name, state and sizing, but not labels (they filter server side only).
    async fn statuses(&self, selector: &sb::Labels) -> sb::Result<Vec<Row>> {
        let mut args = vec!["status".to_owned(), "--all".into(), "--format".into(), "json".into()];
        for (key, value) in selector {
            args.extend(["--label".into(), format!("{key}={value}")]);
        }
        parse_status(&self.call(args, 5).await?)
    }

    /// `NotFound` for a name MSB does not list, `Unavailable` for one that is stopped: MSB reports both as a failed command.
    async fn running(&self, name: &str) -> sb::Result<()> {
        match self.statuses(&sb::Labels::new()).await?.into_iter().find(|row| row.name == name) {
            None => Err(sb::Error::NotFound),
            Some(row) if row.state == sb::State::Stopped => Err(sb::Error::Unavailable),
            Some(_) => Ok(()),
        }
    }

    async fn snapshot_exists(&self, snapshot: &sb::SnapshotRef) -> sb::Result<bool> {
        let bytes = self.call(vec!["snapshot".into(), "list".into()], 10).await?;
        Ok(String::from_utf8_lossy(&bytes).lines().any(|line| line.split_whitespace().next() == Some(snapshot.0.as_str())))
    }

    /// Labels of one sandbox, which only `msb inspect` reports.
    async fn labels(&self, name: &str) -> sb::Result<sb::Labels> {
        parse_inspect(&self.call(vec!["inspect".into(), name.into(), "--format".into(), "json".into()], 5).await?)
    }

    async fn info(&self, row: Row) -> sb::Result<sb::SandboxInfo> {
        Ok(sb::SandboxInfo { labels: self.labels(&row.name).await?, name: row.name, state: row.state })
    }

    async fn volume_names(&self) -> sb::Result<Vec<String>> {
        let bytes = self.call(vec!["volume".into(), "list".into()], 5).await?;
        Ok(String::from_utf8_lossy(&bytes).lines().filter_map(|line| line.split_whitespace().next()).map(str::to_owned).collect())
    }
}

/// `volumes` holds the size of each named volume the spec mounts: MSB wants `kind=disk,size=` on every mount of one.
fn sandbox_flags(spec: &sb::SandboxSpec, volumes: &std::collections::BTreeMap<String, u32>) -> sb::Result<Vec<String>> {
    if spec.gpu.is_some() {
        return Err(sb::Error::Unsupported("gpu"));
    }
    let mut args = vec!["--name".into(), spec.name.clone(), "--cpus".into(), spec.cpus.to_string(), "--memory".into(), format!("{}M", spec.memory_mib)];
    match spec.security {
        sb::Security::Restricted => args.extend(["--security".into(), "restricted".into(), "--deployment-profile".into(), "multi-tenant".into()]),
        sb::Security::Standard => {}
    }
    match &spec.network {
        sb::Network::None => args.push("--no-net".into()),
        sb::Network::Open => {}
        // MSB has per-sandbox network rules (--net-rule, --net-default); their grammar is not mapped here yet.
        sb::Network::Allow(_) => return Err(sb::Error::Unsupported("network allowlist")),
    }
    for (key, value) in &spec.labels {
        args.extend(["--label".into(), format!("{key}={value}")]);
    }
    if let Some(limit) = spec.max_duration {
        args.extend(["--max-duration".into(), format!("{}s", limit.as_secs())]);
    }
    for mount in &spec.mounts {
        if mount.read_only {
            return Err(sb::Error::Unsupported("read-only mounts"));
        }
        let destination = &mount.destination;
        match &mount.source {
            sb::Source::Volume(name) => {
                let size = volumes.get(name).ok_or(sb::Error::NotFound)?;
                args.extend(["--mount-named".into(), format!("{name}:{destination}:kind=disk,size={size}M")]);
            }
            sb::Source::Host(path) => args.extend(["--mount-dir".into(), format!("{}:{destination}", path.display())]),
            sb::Source::Disk(path) => args.extend(["--mount-disk".into(), format!("{}:{destination}", path.display())]),
            sb::Source::Owned => args.extend(["--mount-owned".into(), destination.clone()]),
        }
    }
    Ok(args)
}

/// The arguments of `msb create` or `msb snapshot restore` for a spec. A restore cannot carry labels, so they follow in `modify`.
pub(crate) fn create_args(spec: &sb::SandboxSpec, volumes: &std::collections::BTreeMap<String, u32>) -> sb::Result<Vec<String>> {
    let flags = sandbox_flags(spec, volumes)?;
    Ok(match &spec.template {
        sb::Template::Image(image) => [vec!["create".to_owned(), image.clone()], flags].concat(),
        sb::Template::Snapshot(snapshot) => {
            // `snapshot restore` takes the sizing, network and mounts; the labels follow in `modify`, and the profile flags are create-only.
            let mut kept = Vec::new();
            let mut flags = flags.into_iter();
            while let Some(flag) = flags.next() {
                if matches!(flag.as_str(), "--label" | "--security" | "--deployment-profile") {
                    flags.next();
                } else {
                    kept.push(flag);
                }
            }
            [vec!["snapshot".to_owned(), "restore".into(), snapshot.0.clone()], kept].concat()
        }
    })
}

pub(crate) fn label_args(spec: &sb::SandboxSpec) -> Vec<String> {
    let mut args = vec!["modify".to_owned(), spec.name.clone()];
    for (key, value) in &spec.labels {
        args.extend(["--label".into(), format!("{key}={value}")]);
    }
    args
}

/// One `msb status` row.
pub(crate) struct Row {
    pub name: String,
    pub state: sb::State,
    pub cpus: u64,
    pub memory_mib: u64,
}

pub(crate) fn parse_status(bytes: &[u8]) -> sb::Result<Vec<Row>> {
    let items: Vec<serde_json::Value> = serde_json::from_slice(bytes).map_err(|_| sb::Error::Unavailable)?;
    items
        .iter()
        .map(|item| {
            let name = item["name"].as_str().ok_or(sb::Error::Unavailable)?.to_owned();
            let state = if item["status"] == "Stopped" { sb::State::Stopped } else { sb::State::Running };
            Ok(Row { name, state, cpus: item["cpus"].as_u64().unwrap_or(0), memory_mib: item["memory_mib"].as_u64().unwrap_or(0) })
        })
        .collect()
}

/// The labels in `msb inspect --format json`: the running configuration, or the stored one when the sandbox is stopped (`active_config` is null then).
pub(crate) fn parse_inspect(bytes: &[u8]) -> sb::Result<sb::Labels> {
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| sb::Error::Unavailable)?;
    let config = if value["active_config"].is_object() { &value["active_config"] } else { &value["config"] };
    let labels = config["labels"].as_object().ok_or(sb::Error::Unavailable)?;
    Ok(labels.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned()))).collect())
}

pub(crate) fn parse_volume(name: &str, text: &str) -> Option<sb::VolumeInfo> {
    let field = |key: &str| text.lines().find_map(|line| line.strip_prefix(key).map(str::trim));
    if field("Name:") != Some(name) || field("Kind:") != Some("disk") {
        return None;
    }
    let size_mib = field("Capacity:").and_then(parse_size).unwrap_or(0);
    Some(sb::VolumeInfo { name: name.to_owned(), size_mib, path: field("Path:").map(Into::into) })
}

/// "96.0 MiB" or "1.5 GiB" as whole MiB.
fn parse_size(text: &str) -> Option<u32> {
    let mut parts = text.split_whitespace();
    let value: f64 = parts.next()?.parse().ok()?;
    let factor = match parts.next()?.to_ascii_uppercase().as_str() {
        "MIB" | "MB" | "M" => 1.0,
        "GIB" | "GB" | "G" => 1024.0,
        _ => return None,
    };
    Some((value * factor).round() as u32)
}

pub(crate) fn exec_args(name: &str, command: &sb::Command, flags: &[&str]) -> Vec<String> {
    let mut args = vec!["exec".to_owned(), name.to_owned(), "--quiet".into()];
    args.extend(flags.iter().map(|f| f.to_string()));
    for (key, value) in &command.env {
        args.extend(["--env".into(), format!("{key}={value}")]);
    }
    args.push("--".into());
    args.push(command.program.clone());
    args.extend(command.args.iter().cloned());
    args
}

impl sb::SandboxProvider for Msb {
    fn capabilities(&self) -> sb::Capabilities {
        sb::Capabilities { persistent_volumes: true, min_volume_mib: MIN_VOLUME_MIB, snapshots: true, fork: false, gpu: false, network_allowlist: false, warm_pool: false, max_sandboxes: self.config.max_workspaces as u32 }
    }

    async fn create_volume(&self, spec: sb::VolumeSpec) -> sb::Result<sb::VolumeInfo> {
        if spec.name.is_empty() || spec.size_mib < MIN_VOLUME_MIB {
            return Err(sb::Error::Invalid("A volume needs a name and a size MSB can format.".into()));
        }
        if let Some(existing) = self.volume(&spec.name).await? {
            return if existing.size_mib == 0 || existing.size_mib == spec.size_mib { Ok(existing) } else { Err(sb::Error::Conflict("The volume exists with another size.".into())) };
        }
        let args = ["volume", "create", &spec.name, "--kind", "disk", "--size", &format!("{}M", spec.size_mib)].map(str::to_owned).to_vec();
        self.call(args, 15).await?;
        self.volume(&spec.name).await?.ok_or(sb::Error::Unavailable)
    }

    async fn volume(&self, name: &str) -> sb::Result<Option<sb::VolumeInfo>> {
        if !self.volume_names().await?.iter().any(|n| n == name) {
            return Ok(None);
        }
        let bytes = self.call(vec!["volume".into(), "inspect".into(), name.into()], 5).await?;
        parse_volume(name, &String::from_utf8_lossy(&bytes)).map(Some).ok_or_else(|| sb::Error::Conflict("The volume is not a disk volume.".into()))
    }

    async fn remove_volume(&self, name: &str) -> sb::Result<()> {
        if !self.volume_names().await?.iter().any(|n| n == name) {
            return Ok(());
        }
        let removed = self.call(vec!["volume".into(), "remove".into(), name.into()], 15).await;
        if self.volume_names().await?.iter().any(|n| n == name) {
            return Err(if removed.is_err() { sb::Error::Conflict("The volume could not be removed; a sandbox may still mount it.".into()) } else { sb::Error::Unavailable });
        }
        Ok(())
    }

    async fn create(&self, spec: sb::SandboxSpec) -> sb::Result<sb::SandboxInfo> {
        if spec.name.is_empty() || spec.cpus == 0 || spec.memory_mib == 0 {
            return Err(sb::Error::Invalid("A sandbox needs a name, cpus and memory.".into()));
        }
        let mut volumes = std::collections::BTreeMap::new();
        for mount in &spec.mounts {
            if let sb::Source::Volume(name) = &mount.source {
                let found = self.volume(name).await?.ok_or(sb::Error::NotFound)?;
                volumes.insert(name.clone(), found.size_mib);
            }
        }
        let args = create_args(&spec, &volumes)?;
        // The same spec is judged by what MSB reports: labels, cpus and memory.
        if let Some(row) = self.statuses(&sb::Labels::new()).await?.into_iter().find(|row| row.name == spec.name) {
            let same = row.cpus == spec.cpus as u64 && row.memory_mib == spec.memory_mib as u64;
            let existing = self.info(row).await?;
            return if same && existing.labels == spec.labels { Ok(existing) } else { Err(sb::Error::Conflict("The name is in use with a different spec.".into())) };
        }
        self.call(args, 45).await?;
        if matches!(spec.template, sb::Template::Snapshot(_)) {
            self.call(label_args(&spec), 5).await?;
        }
        self.get(&spec.name).await?.ok_or(sb::Error::Unavailable)
    }

    async fn get(&self, name: &str) -> sb::Result<Option<sb::SandboxInfo>> {
        match self.statuses(&sb::Labels::new()).await?.into_iter().find(|row| row.name == name) {
            Some(row) => Ok(Some(self.info(row).await?)),
            None => Ok(None),
        }
    }

    async fn list(&self, selector: &sb::Labels) -> sb::Result<Vec<sb::SandboxInfo>> {
        let mut found = Vec::new();
        for row in self.statuses(selector).await? {
            found.push(self.info(row).await?);
        }
        Ok(found)
    }

    async fn ping(&self, name: &str) -> sb::Result<()> {
        self.running(name).await?;
        self.call(vec!["ping".into(), name.into()], 5).await.map(|_| ())
    }

    async fn stop(&self, name: &str) -> sb::Result<()> {
        if self.get(name).await?.is_none() {
            return Err(sb::Error::NotFound);
        }
        self.call(vec!["stop".into(), name.into()], 30).await.map(|_| ())
    }

    async fn remove(&self, name: &str) -> sb::Result<()> {
        if self.get(name).await?.is_none() {
            return Ok(());
        }
        self.call(vec!["remove".into(), "--force".into(), name.into()], 30).await?;
        if self.get(name).await?.is_some() { Err(sb::Error::Unavailable) } else { Ok(()) }
    }

    async fn spawn(&self, name: &str, command: sb::Command) -> sb::Result<sb::Process> {
        self.running(name).await?;
        let mut process = command::msb(&self.config);
        process.args(exec_args(name, &command, &["--stream"])).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        let mut running = Process::new(process).map_err(|_| sb::Error::Unavailable)?;
        let stdin = running.child.stdin.take().ok_or(sb::Error::Unavailable)?;
        let stdout = running.child.stdout.take().ok_or(sb::Error::Unavailable)?;
        let (done, exit) = tokio::sync::oneshot::channel();
        // Dropping the receiver ends the select and the process, killing its group.
        tokio::spawn(async move {
            let mut done = done;
            let code = tokio::select! {
                status = running.child.wait() => status.ok().and_then(|s| s.code()).unwrap_or(-1),
                _ = done.closed() => return,
            };
            let _ = done.send(code);
        });
        Ok(sb::Process { stdin: Box::new(stdin), stdout: Box::new(stdout), exit })
    }

    async fn run(&self, name: &str, command: sb::Command, limit: usize, within: Duration) -> sb::Result<sb::Output> {
        self.running(name).await?;
        let mut process = command::msb(&self.config);
        process.args(exec_args(name, &command, &["--no-stdin"])).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut running = Process::new(process).map_err(|_| sb::Error::Unavailable)?;
        let mut out = running.child.stdout.take().ok_or(sb::Error::Unavailable)?.take(limit as u64 + 1);
        let mut err = running.child.stderr.take().ok_or(sb::Error::Unavailable)?.take(limit as u64 + 1);
        let work = async {
            let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
            let (_, _, status) = tokio::try_join!(out.read_to_end(&mut stdout), err.read_to_end(&mut stderr), running.child.wait()).map_err(|_| sb::Error::Unavailable)?;
            Ok::<_, sb::Error>((status.code().unwrap_or(-1), stdout, stderr))
        };
        let (status, stdout, stderr) = tokio::time::timeout(within, work).await.map_err(|_| sb::Error::Timeout)??;
        if stdout.len() > limit || stderr.len() > limit {
            return Err(sb::Error::Invalid("The output passed its limit.".into()));
        }
        Ok(sb::Output { status, stdout, stderr })
    }

    async fn detach(&self, name: &str, command: sb::Command) -> sb::Result<()> {
        self.running(name).await?;
        self.call(exec_args(name, &command, &["--detach", "--no-stdin"]), 10).await.map(|_| ())
    }

    async fn copy_in(&self, name: &str, host: std::path::PathBuf, guest: &str) -> sb::Result<()> {
        self.running(name).await?;
        if tokio::fs::metadata(&host).await.is_err() {
            return Err(sb::Error::NotFound);
        }
        self.call(vec!["copy".into(), host.display().to_string(), format!("{name}:{guest}")], 30).await.map(|_| ())
    }

    /// MSB names a snapshot `<sandbox>:<name>`; that whole string is the reference every other snapshot command takes.
    async fn snapshot(&self, name: &str) -> sb::Result<sb::SnapshotRef> {
        self.running(name).await?;
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| sb::Error::Unavailable)?.as_secs();
        let made = format!("{name}-{stamp}");
        self.call(["snapshot", "create", "--sandbox", name, "--name", &made].map(str::to_owned).to_vec(), 60).await?;
        Ok(sb::SnapshotRef(format!("{name}:{made}")))
    }

    async fn verify_snapshot(&self, snapshot: &sb::SnapshotRef) -> sb::Result<()> {
        match self.call(vec!["snapshot".into(), "verify".into(), snapshot.0.clone()], 30).await {
            Ok(_) => Ok(()),
            Err(error) => Err(if self.snapshot_exists(snapshot).await? { error } else { sb::Error::NotFound }),
        }
    }

    async fn remove_snapshot(&self, snapshot: &sb::SnapshotRef) -> sb::Result<()> {
        if !self.snapshot_exists(snapshot).await? {
            return Ok(());
        }
        // MSB chains snapshots in a group and refuses to remove one with children or the group head; that is a conflict, not a failure to retry.
        let removed = self.call(vec!["snapshot".into(), "remove".into(), snapshot.0.clone()], 30).await;
        if self.snapshot_exists(snapshot).await? {
            return Err(if removed.is_err() { sb::Error::Conflict("The snapshot has dependants or is its group's head.".into()) } else { sb::Error::Unavailable });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sizes() -> std::collections::BTreeMap<String, u32> {
        [("w-work".to_string(), 1024)].into()
    }

    fn spec() -> sb::SandboxSpec {
        sb::SandboxSpec {
            name: "rayde-x-1".into(),
            template: sb::Template::Image("alpine:3.23".into()),
            cpus: 1,
            memory_mib: 512,
            security: sb::Security::Restricted,
            network: sb::Network::None,
            gpu: None,
            labels: sb::Labels::from([("rayde.runner".to_string(), "r1".to_string()), ("rayde.workspace".to_string(), "w1".to_string())]),
            mounts: vec![sb::Mount { source: sb::Source::Volume("w-work".into()), destination: "/workspace".into(), read_only: false }, sb::Mount { source: sb::Source::Owned, destination: "/state".into(), read_only: false }],
            max_duration: Some(Duration::from_secs(3600)),
        }
    }

    #[test]
    fn a_restricted_image_sandbox_gets_the_flags_the_runner_uses() {
        let args = create_args(&spec(), &sizes()).unwrap().join(" ");
        assert_eq!(args, "create alpine:3.23 --name rayde-x-1 --cpus 1 --memory 512M --security restricted --deployment-profile multi-tenant --no-net --label rayde.runner=r1 --label rayde.workspace=w1 --max-duration 3600s --mount-named w-work:/workspace:kind=disk,size=1024M --mount-owned /state");
    }

    #[test]
    fn a_snapshot_restore_takes_sizing_and_mounts_and_labels_follow() {
        let mut restored = spec();
        restored.template = sb::Template::Snapshot(sb::SnapshotRef("toolchain".into()));
        restored.mounts = vec![sb::Mount { source: sb::Source::Disk("/v/work/disk.raw".into()), destination: "/workspace".into(), read_only: false }];
        let args = create_args(&restored, &sizes()).unwrap().join(" ");
        assert_eq!(args, "snapshot restore toolchain --name rayde-x-1 --cpus 1 --memory 512M --no-net --max-duration 3600s --mount-disk /v/work/disk.raw:/workspace");
        assert_eq!(label_args(&restored).join(" "), "modify rayde-x-1 --label rayde.runner=r1 --label rayde.workspace=w1");
    }

    #[test]
    fn a_named_volume_the_caller_did_not_size_is_not_found() {
        assert_eq!(create_args(&spec(), &Default::default()), Err(sb::Error::NotFound));
    }

    #[test]
    fn what_msb_cannot_express_is_refused_not_dropped() {
        let mut gpu = spec();
        gpu.gpu = Some(sb::Gpu { memory_mib: 1024, api: sb::GpuApi::Vulkan });
        assert_eq!(create_args(&gpu, &sizes()), Err(sb::Error::Unsupported("gpu")));
        let mut allow = spec();
        allow.network = sb::Network::Allow(vec!["api.example.com".into()]);
        assert_eq!(create_args(&allow, &sizes()), Err(sb::Error::Unsupported("network allowlist")));
        let mut readonly = spec();
        readonly.mounts[0].read_only = true;
        assert_eq!(create_args(&readonly, &sizes()), Err(sb::Error::Unsupported("read-only mounts")));
    }

    #[test]
    fn status_rows_carry_state_and_sizing_and_inspect_carries_labels() {
        let rows = parse_status(br#"[{"name":"a","status":"Running","cpus":1,"memory_mib":256},{"name":"b","status":"Stopped"}]"#).unwrap();
        assert_eq!((rows[0].name.as_str(), rows[0].state, rows[0].cpus, rows[0].memory_mib), ("a", sb::State::Running, 1, 256));
        assert_eq!(rows[1].state, sb::State::Stopped);
        assert!(parse_status(b"not json").is_err());
        let labels = parse_inspect(br#"{"active_config":{"labels":{"owner":"conformance"},"name":"a"}}"#).unwrap();
        assert_eq!(labels, sb::Labels::from([("owner".to_string(), "conformance".to_string())]));
        let stopped = parse_inspect(br#"{"active_config":null,"config":{"labels":{"owner":"conformance"}}}"#).unwrap();
        assert_eq!(stopped, labels);
        assert!(parse_inspect(br#"{"active_config":{}}"#).is_err());
    }

    #[test]
    fn volume_inspect_text_is_checked_for_name_and_kind() {
        let text = "Name:                 w-work\nKind:                 disk\nFormat:               raw\nFilesystem:           ext4\nCapacity:             1.0 GiB\nPath:                 /v/w-work/disk.raw\n";
        let volume = parse_volume("w-work", text).unwrap();
        assert_eq!((volume.size_mib, volume.path), (1024, Some("/v/w-work/disk.raw".into())));
        assert!(parse_volume("other", text).is_none());
        assert!(parse_volume("w-work", "Name: w-work\nKind: dir\n").is_none());
    }

    #[test]
    fn exec_commands_carry_flags_environment_and_the_program() {
        let command = sb::Command { program: "/opt/rayde-session".into(), args: vec!["bridge".into(), "--port".into(), "7071".into()], env: [("A".to_string(), "1".to_string())].into() };
        assert_eq!(exec_args("s", &command, &["--stream"]).join(" "), "exec s --quiet --stream --env A=1 -- /opt/rayde-session bridge --port 7071");
        assert_eq!(exec_args("s", &command, &["--detach", "--no-stdin"]).join(" "), "exec s --quiet --detach --no-stdin --env A=1 -- /opt/rayde-session bridge --port 7071");
    }

    /// Against a real MSB: set RAYDE_MSB_CONFIG to a runner config file (msb path, image, limits) on a KVM host and run with --ignored.
    #[tokio::test]
    #[ignore = "needs a host with MSB; creates and removes sandboxes"]
    async fn msb_conforms() {
        let path = std::env::var("RAYDE_MSB_CONFIG").expect("RAYDE_MSB_CONFIG");
        let config: Config = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        let prefix = format!("conf{}", std::process::id());
        sb::conformance::run_all(&Msb::new(config), &prefix).await.unwrap();
    }
}
