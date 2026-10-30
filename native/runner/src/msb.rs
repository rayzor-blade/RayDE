//! MSB as a `rayde_sandbox::SandboxProvider`: each call is the `msb` command the runner already runs for that need. The runner's own
//! service code does not use it yet.

use crate::{
    Config,
    command::{self, Process},
};
use rayde_sandbox as sb;
use std::{process::Stdio, time::Duration};
use tokio::io::AsyncReadExt;

pub struct Msb {
    config: Config,
}

impl Msb {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    async fn call(&self, args: Vec<String>, seconds: u64) -> sb::Result<Vec<u8>> {
        command::call(&self.config, args, seconds).await.map_err(|_| sb::Error::Unavailable)
    }

    async fn statuses(&self, selector: &sb::Labels) -> sb::Result<Vec<sb::SandboxInfo>> {
        let mut args = vec!["status".to_owned(), "--all".into(), "--format".into(), "json".into()];
        for (key, value) in selector {
            args.extend(["--label".into(), format!("{key}={value}")]);
        }
        parse_status(&self.call(args, 5).await?)
    }

    async fn volume_names(&self) -> sb::Result<Vec<String>> {
        let bytes = self.call(vec!["volume".into(), "list".into()], 5).await?;
        Ok(String::from_utf8_lossy(&bytes).lines().filter_map(|line| line.split_whitespace().next()).map(str::to_owned).collect())
    }
}

fn sandbox_flags(spec: &sb::SandboxSpec) -> sb::Result<Vec<String>> {
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
            sb::Source::Volume(name) => args.extend(["--mount-named".into(), format!("{name}:{destination}")]),
            sb::Source::Host(path) => args.extend(["--mount-dir".into(), format!("{}:{destination}", path.display())]),
            sb::Source::Disk(path) => args.extend(["--mount-disk".into(), format!("{}:{destination}", path.display())]),
            sb::Source::Owned => args.extend(["--mount-owned".into(), destination.clone()]),
        }
    }
    Ok(args)
}

/// The arguments of `msb create` or `msb snapshot restore` for a spec. A restore cannot carry labels, so they follow in `modify`.
pub(crate) fn create_args(spec: &sb::SandboxSpec) -> sb::Result<Vec<String>> {
    let flags = sandbox_flags(spec)?;
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

pub(crate) fn parse_status(bytes: &[u8]) -> sb::Result<Vec<sb::SandboxInfo>> {
    let items: Vec<serde_json::Value> = serde_json::from_slice(bytes).map_err(|_| sb::Error::Unavailable)?;
    items
        .iter()
        .map(|item| {
            let name = item["name"].as_str().ok_or(sb::Error::Unavailable)?.to_owned();
            let state = if item["status"] == "Stopped" { sb::State::Stopped } else { sb::State::Running };
            let labels = item["labels"]
                .as_object()
                .map(|map| map.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned()))).collect())
                .unwrap_or_default();
            Ok(sb::SandboxInfo { name, state, labels })
        })
        .collect()
}

pub(crate) fn parse_volume(name: &str, text: &str) -> Option<sb::VolumeInfo> {
    let field = |key: &str| text.lines().find_map(|line| line.strip_prefix(key).map(str::trim));
    if field("Name:") != Some(name) || field("Kind:") != Some("disk") {
        return None;
    }
    let size_mib = field("Size:").and_then(parse_size).unwrap_or(0);
    Some(sb::VolumeInfo { name: name.to_owned(), size_mib, path: field("Path:").map(Into::into) })
}

fn parse_size(text: &str) -> Option<u32> {
    let (number, unit) = text.split_at(text.find(|c: char| !c.is_ascii_digit())?);
    let value: u32 = number.parse().ok()?;
    match unit.trim().to_ascii_uppercase().trim_end_matches('B').trim_end_matches('I') {
        "M" => Some(value),
        "G" => value.checked_mul(1024),
        _ => None,
    }
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
        sb::Capabilities { persistent_volumes: true, snapshots: true, fork: false, gpu: false, network_allowlist: false, warm_pool: false, max_sandboxes: self.config.max_workspaces as u32 }
    }

    async fn create_volume(&self, spec: sb::VolumeSpec) -> sb::Result<sb::VolumeInfo> {
        if spec.name.is_empty() || spec.size_mib == 0 {
            return Err(sb::Error::Invalid("A volume needs a name and a size.".into()));
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
        let args = create_args(&spec)?;
        // MSB does not keep the spec, so "the same spec" can only be checked by label.
        if let Some(existing) = self.get(&spec.name).await? {
            return if existing.labels == spec.labels { Ok(existing) } else { Err(sb::Error::Conflict("The name is in use with different labels.".into())) };
        }
        self.call(args, 45).await?;
        if matches!(spec.template, sb::Template::Snapshot(_)) {
            self.call(label_args(&spec), 5).await?;
        }
        self.get(&spec.name).await?.ok_or(sb::Error::Unavailable)
    }

    async fn get(&self, name: &str) -> sb::Result<Option<sb::SandboxInfo>> {
        Ok(self.statuses(&sb::Labels::new()).await?.into_iter().find(|s| s.name == name))
    }

    async fn list(&self, selector: &sb::Labels) -> sb::Result<Vec<sb::SandboxInfo>> {
        self.statuses(selector).await
    }

    async fn ping(&self, name: &str) -> sb::Result<()> {
        self.call(vec!["ping".into(), name.into()], 5).await.map(|_| ())
    }

    async fn stop(&self, name: &str) -> sb::Result<()> {
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
        self.call(exec_args(name, &command, &["--detach", "--no-stdin"]), 10).await.map(|_| ())
    }

    async fn copy_in(&self, name: &str, host: std::path::PathBuf, guest: &str) -> sb::Result<()> {
        if tokio::fs::metadata(&host).await.is_err() {
            return Err(sb::Error::NotFound);
        }
        self.call(vec!["copy".into(), host.display().to_string(), format!("{name}:{guest}")], 30).await.map(|_| ())
    }

    async fn snapshot(&self, name: &str) -> sb::Result<sb::SnapshotRef> {
        let snapshot = format!("{name}-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| sb::Error::Unavailable)?.as_secs());
        self.call(["snapshot", "create", "--sandbox", name, "--name", &snapshot].map(str::to_owned).to_vec(), 60).await?;
        Ok(sb::SnapshotRef(snapshot))
    }

    async fn verify_snapshot(&self, snapshot: &sb::SnapshotRef) -> sb::Result<()> {
        self.call(vec!["snapshot".into(), "verify".into(), snapshot.0.clone()], 30).await.map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let args = create_args(&spec()).unwrap().join(" ");
        assert_eq!(args, "create alpine:3.23 --name rayde-x-1 --cpus 1 --memory 512M --security restricted --deployment-profile multi-tenant --no-net --label rayde.runner=r1 --label rayde.workspace=w1 --max-duration 3600s --mount-named w-work:/workspace --mount-owned /state");
    }

    #[test]
    fn a_snapshot_restore_takes_sizing_and_mounts_and_labels_follow() {
        let mut restored = spec();
        restored.template = sb::Template::Snapshot(sb::SnapshotRef("toolchain".into()));
        restored.mounts = vec![sb::Mount { source: sb::Source::Disk("/v/work/disk.raw".into()), destination: "/workspace".into(), read_only: false }];
        let args = create_args(&restored).unwrap().join(" ");
        assert_eq!(args, "snapshot restore toolchain --name rayde-x-1 --cpus 1 --memory 512M --no-net --max-duration 3600s --mount-disk /v/work/disk.raw:/workspace");
        assert_eq!(label_args(&restored).join(" "), "modify rayde-x-1 --label rayde.runner=r1 --label rayde.workspace=w1");
    }

    #[test]
    fn what_msb_cannot_express_is_refused_not_dropped() {
        let mut gpu = spec();
        gpu.gpu = Some(sb::Gpu { memory_mib: 1024, api: sb::GpuApi::Vulkan });
        assert_eq!(create_args(&gpu), Err(sb::Error::Unsupported("gpu")));
        let mut allow = spec();
        allow.network = sb::Network::Allow(vec!["api.example.com".into()]);
        assert_eq!(create_args(&allow), Err(sb::Error::Unsupported("network allowlist")));
        let mut readonly = spec();
        readonly.mounts[0].read_only = true;
        assert_eq!(create_args(&readonly), Err(sb::Error::Unsupported("read-only mounts")));
    }

    #[test]
    fn status_json_becomes_sandbox_info() {
        let found = parse_status(br#"[{"name":"a","status":"Running","labels":{"k":"v"}},{"name":"b","status":"Stopped"}]"#).unwrap();
        assert_eq!(found[0], sb::SandboxInfo { name: "a".into(), state: sb::State::Running, labels: sb::Labels::from([("k".to_string(), "v".to_string())]) });
        assert_eq!((found[1].state, found[1].labels.len()), (sb::State::Stopped, 0));
        assert_eq!(parse_status(b"not json"), Err(sb::Error::Unavailable));
    }

    #[test]
    fn volume_inspect_text_is_checked_for_name_and_kind() {
        let text = "Name: w-work\nKind: disk\nFilesystem: ext4\nSize: 1G\nPath: /v/w-work/disk.raw\n";
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
