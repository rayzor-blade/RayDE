//! What every backend must do the same way. A backend's tests call `run_all` with a unique `prefix` so repeated runs do not collide;
//! features it does not advertise must answer `Error::Unsupported`, and the suite checks that too.

use crate::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn check(ok: bool, message: &str) -> std::result::Result<(), String> {
    if ok { Ok(()) } else { Err(message.to_string()) }
}

fn spec(name: &str, mounts: Vec<Mount>) -> SandboxSpec {
    SandboxSpec {
        name: name.into(),
        template: Template::Image("alpine:3.23".into()),
        cpus: 1,
        memory_mib: 256,
        security: Security::Restricted,
        network: Network::None,
        gpu: None,
        labels: Labels::from([("owner".to_string(), "conformance".to_string())]),
        mounts,
        max_duration: Some(Duration::from_secs(60)),
    }
}

fn command(program: &str, args: &[&str]) -> Command {
    Command { program: program.into(), args: args.iter().map(|a| a.to_string()).collect(), env: Default::default() }
}

pub async fn run_all<P: SandboxProvider>(p: &P, prefix: &str) -> std::result::Result<(), String> {
    let caps = p.capabilities();
    let (a, b, vol) = (format!("{prefix}-a"), format!("{prefix}-b"), format!("{prefix}-vol"));

    // Creation is idempotent for the same spec and refuses a different one under the same name.
    let first = p.create(spec(&a, vec![])).await.map_err(|e| format!("create: {e:?}"))?;
    check(first.state == State::Running, "A new sandbox is running")?;
    check(p.create(spec(&a, vec![])).await.as_ref() == Ok(&first), "Creating twice with one spec returns the same sandbox")?;
    let mut other = spec(&a, vec![]);
    other.memory_mib = 512;
    check(matches!(p.create(other).await, Err(Error::Conflict(_))), "A different spec under a used name is a conflict")?;
    check(matches!(p.create(SandboxSpec { cpus: 0, ..spec(&b, vec![]) }).await, Err(Error::Invalid(_))), "Zero cpus is invalid")?;

    // Labels select sandboxes.
    let mut selector = Labels::new();
    selector.insert("owner".into(), "conformance".into());
    check(p.list(&selector).await.map_err(|e| format!("list: {e:?}"))?.iter().any(|s| s.name == a), "list finds a sandbox by label")?;
    selector.insert("owner".into(), "nobody".into());
    check(p.list(&selector).await.map_err(|e| format!("list: {e:?}"))?.is_empty(), "list excludes other labels")?;

    // Commands: piped stdio round trip, bounded capture, deadline.
    p.ping(&a).await.map_err(|e| format!("ping: {e:?}"))?;
    let mut cat = p.spawn(&a, command("cat", &[])).await.map_err(|e| format!("spawn: {e:?}"))?;
    cat.stdin.write_all(b"hello").await.map_err(|e| e.to_string())?;
    drop(cat.stdin);
    let mut echoed = Vec::new();
    cat.stdout.read_to_end(&mut echoed).await.map_err(|e| e.to_string())?;
    check(echoed == b"hello", "spawn relays stdin to stdout")?;
    check(cat.exit.await == Ok(0), "spawn reports the exit status")?;
    let out = p.run(&a, command("echo", &["hi"]), 1024, Duration::from_secs(5)).await.map_err(|e| format!("run: {e:?}"))?;
    check(out.status == 0 && out.stdout == b"hi\n", "run captures output")?;
    check(matches!(p.run(&a, command("echo", &["too long"]), 3, Duration::from_secs(5)).await, Err(Error::Invalid(_))), "run refuses output past its limit")?;
    check(matches!(p.run(&a, command("sleep", &["2000"]), 16, Duration::from_millis(50)).await, Err(Error::Timeout)), "run stops at its deadline")?;
    p.detach(&a, command("sleep", &["10"])).await.map_err(|e| format!("detach: {e:?}"))?;
    check(matches!(p.detach(&format!("{prefix}-missing"), command("sleep", &["10"])).await, Err(Error::NotFound)), "detach on a missing sandbox is NotFound")?;
    check(matches!(p.copy_in(&a, PathBuf::from("/definitely/not/here"), "/x").await, Err(Error::NotFound)), "copy_in of a missing file is NotFound")?;

    // Volumes outlive the sandboxes that mount them; removal is idempotent and refused while mounted.
    let (size, larger) = (caps.min_volume_mib.max(64), caps.min_volume_mib.max(64) * 2);
    if caps.persistent_volumes {
        check(caps.min_volume_mib == 0 || matches!(p.create_volume(VolumeSpec { name: vol.clone(), size_mib: caps.min_volume_mib - 1 }).await, Err(Error::Invalid(_))), "A volume under the minimum is invalid")?;
        let made = p.create_volume(VolumeSpec { name: vol.clone(), size_mib: size }).await.map_err(|e| format!("volume: {e:?}"))?;
        check(p.create_volume(VolumeSpec { name: vol.clone(), size_mib: size }).await == Ok(made.clone()), "Creating a volume twice is idempotent")?;
        check(matches!(p.create_volume(VolumeSpec { name: vol.clone(), size_mib: larger }).await, Err(Error::Conflict(_))), "A volume of another size under a used name is a conflict")?;
        let mount = Mount { source: Source::Volume(vol.clone()), destination: "/workspace".into(), read_only: false };
        p.create(spec(&b, vec![mount])).await.map_err(|e| format!("create with volume: {e:?}"))?;
        check(matches!(p.remove_volume(&vol).await, Err(Error::Conflict(_))), "A mounted volume cannot be removed")?;
        p.remove(&b).await.map_err(|e| format!("remove: {e:?}"))?;
        check(p.volume(&vol).await == Ok(Some(made)), "A volume survives its sandbox")?;
        p.remove_volume(&vol).await.map_err(|e| format!("remove_volume: {e:?}"))?;
        p.remove_volume(&vol).await.map_err(|e| format!("remove_volume again: {e:?}"))?;
        check(p.volume(&vol).await == Ok(None), "A removed volume is gone")?;
    } else {
        check(matches!(p.create_volume(VolumeSpec { name: vol.clone(), size_mib: size }).await, Err(Error::Unsupported(_))), "Volumes answer Unsupported when not advertised")?;
    }

    // Features a backend does not advertise are refused, not ignored.
    if !caps.gpu {
        let mut gpu = spec(&b, vec![]);
        gpu.gpu = Some(Gpu { memory_mib: 1024, api: GpuApi::Vulkan });
        check(matches!(p.create(gpu).await, Err(Error::Unsupported(_))), "A GPU request answers Unsupported when not advertised")?;
    }
    if !caps.network_allowlist {
        let mut net = spec(&b, vec![]);
        net.network = Network::Allow(vec!["api.example.com".into()]);
        check(matches!(p.create(net).await, Err(Error::Unsupported(_))), "An allowlist answers Unsupported when not advertised")?;
    }
    if caps.snapshots {
        let snapshot = p.snapshot(&a).await.map_err(|e| format!("snapshot: {e:?}"))?;
        p.verify_snapshot(&snapshot).await.map_err(|e| format!("verify: {e:?}"))?;
        let mut restored = spec(&b, vec![]);
        restored.template = Template::Snapshot(snapshot.clone());
        p.create(restored).await.map_err(|e| format!("restore: {e:?}"))?;
        p.remove(&b).await.map_err(|e| format!("remove: {e:?}"))?;
        p.remove_snapshot(&snapshot).await.map_err(|e| format!("remove_snapshot: {e:?}"))?;
        p.remove_snapshot(&snapshot).await.map_err(|e| format!("remove_snapshot again: {e:?}"))?;
        check(matches!(p.verify_snapshot(&snapshot).await, Err(Error::NotFound)), "A removed snapshot no longer verifies")?;
    } else {
        check(matches!(p.snapshot(&a).await, Err(Error::Unsupported(_))), "Snapshots answer Unsupported when not advertised")?;
    }

    // A stopped sandbox does not answer; removal is idempotent.
    p.stop(&a).await.map_err(|e| format!("stop: {e:?}"))?;
    check(p.ping(&a).await.is_err(), "A stopped sandbox does not answer ping")?;
    p.remove(&a).await.map_err(|e| format!("remove: {e:?}"))?;
    p.remove(&a).await.map_err(|e| format!("remove again: {e:?}"))?;
    check(p.get(&a).await == Ok(None), "A removed sandbox is gone")?;
    Ok(())
}
