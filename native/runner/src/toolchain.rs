use super::*;
use rayde_sandbox as sb;

pub(crate) fn identity(config: &Config) -> Option<String> {
    config.toolchain.as_ref().map(|toolchain| toolchain.digest.clone())
}

/// Runs `script` in the guest and returns its output; a nonzero exit is a failure.
async fn guest(backend: &impl sb::SandboxProvider, sandbox: &str, script: &str, seconds: u64) -> Result<Vec<u8>> {
    let command = sb::Command { program: "/bin/sh".into(), args: vec!["-ec".into(), script.into()], env: Default::default() };
    let output = backend.run(sandbox, command, 64 * 1024, std::time::Duration::from_secs(seconds)).await?;
    if output.status != 0 {
        return Err(unavailable());
    }
    Ok(output.stdout)
}

pub(crate) async fn restore(backend: &impl sb::SandboxProvider, config: &Config, sandbox: &str, labels: sb::Labels, mounts: Vec<sb::Mount>, network: sb::Network) -> Result<()> {
    let toolchain = config.toolchain.as_ref().ok_or_else(invalid)?;
    let snapshot = sb::SnapshotRef(toolchain.snapshot.clone());
    backend.verify_snapshot(&snapshot).await?;
    backend
        .create(sb::SandboxSpec {
            name: sandbox.into(),
            template: sb::Template::Snapshot(snapshot),
            cpus: config.cpus as u32,
            memory_mib: config.memory_mib,
            security: sb::Security::Restricted,
            network,
            gpu: None,
            labels,
            mounts,
            max_duration: Some(std::time::Duration::from_secs(config.max_duration_seconds)),
        })
        .await?;
    let digest = guest(backend, sandbox, "cd /opt/rayde; sha256sum -c SHA256SUMS >/dev/null; sha256sum toolchain.json", 30).await?;
    if String::from_utf8_lossy(&digest).split_whitespace().next() != Some(&toolchain.digest) {
        return Err(Failure(StatusCode::CONFLICT, "The guest toolchain identity does not match its configuration."));
    }
    guest(backend, sandbox, "export LD_LIBRARY_PATH=/opt/rayde/lib; /opt/rayde/bin/haxe --version; /opt/rayde/bin/ash --version; /opt/rayde/bin/rayzor --version; test -f /opt/rayde/haxe-std/StdTypes.hx; test -f /opt/rayde/environment.json; test -x /opt/rayde/bin/rayde-extension-host; test -f /opt/rayde/extensions/git/git.rayext; test -f /opt/rayde/extensions/markdown/markdown.rayext; test -f /opt/rayde/extensions/rayzor/rayzor.rayext", 15).await?;
    Ok(())
}

pub(crate) fn session_args(config: &Config) -> Vec<&'static str> {
    if config.toolchain.is_none() { return Vec::new(); }
    let mut args=vec!["--env-file", "/opt/rayde/environment.json", "--extension-host", "/opt/rayde/bin/rayde-extension-host", "--extensions", "/opt/rayde/extensions", "--read-root", "/opt/rayde/haxelib", "--read-root", "/opt/rayde/haxe-std", "--read-root", "/opt/rayde/haxe/std"];
    if config.toolchain.as_ref().is_some_and(|toolchain|toolchain.app_previews){args.extend(["--preview-tools","/opt/rayde/preview"]);}
    args
}

/// Only fresh matching public demos receive operator-prepared caches, before programs start.
pub(crate) async fn seed_demo(backend:&impl sb::SandboxProvider,config:&Config,sandbox:&str,reference:&DemoRef)->Result<()> {
    if !config.toolchain.as_ref().is_some_and(|toolchain|toolchain.demo_release.as_deref()==Some(reference.release.as_str())){return Ok(())}
    let command=sb::Command{program:"/usr/bin/python3".into(),args:vec!["/opt/rayde/demo_cache.py".into(),"restore".into(),"--release".into(),reference.release.clone()],env:Default::default()};
    let output=backend.run(sandbox,command,64*1024,std::time::Duration::from_secs(15)).await?;
    if output.status!=0{return Err(Failure(StatusCode::CONFLICT,"The prepared demo cache could not be verified."));}
    let report:serde_json::Value=serde_json::from_slice(&output.stdout).map_err(|_|unavailable())?;
    if !matches!(report["status"].as_str(),Some("restored"|"cold")){return Err(unavailable());}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sb::SandboxProvider;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn prepared_caches_are_opt_in_and_bound_to_one_public_release() {
        let calls=std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let observed=calls.clone();
        let fake=sb::fake::Fake::new(Default::default()).with_program("/usr/bin/python3",move |_,command,_,mut stdout| {
            let observed=observed.clone();
            async move {
                observed.lock().unwrap().push(command.args);
                stdout.write_all(br#"{"status":"restored","files":1}"#).await.unwrap();
                0
            }
        });
        fake.create(sb::SandboxSpec{name:"demo".into(),template:sb::Template::Image("fixture".into()),cpus:1,memory_mib:512,
            security:sb::Security::Restricted,network:sb::Network::None,gpu:None,labels:Default::default(),mounts:vec![],max_duration:None}).await.unwrap();
        let mut config:Config=serde_json::from_value(serde_json::json!({
            "listen":"127.0.0.1:0","stateRoot":"/tmp/state","msb":"/bin/msb","sessionBinary":"/bin/session","secretFile":"/tmp/secret",
            "toolchain":{"snapshot":"group:template","digest":"a".repeat(64)}
        })).unwrap();
        let reference=DemoRef{release:"b".repeat(64),lease:"x".repeat(43),expires:demo::now().unwrap()+60};
        for release in [None,Some("c".repeat(64)),Some(reference.release.clone())] {
            config.toolchain.as_mut().unwrap().demo_release=release;
            seed_demo(&fake,&config,"demo",&reference).await.unwrap();
        }
        let calls=calls.lock().unwrap();
        assert_eq!(calls.len(),1);
        assert_eq!(calls[0],vec!["/opt/rayde/demo_cache.py","restore","--release",reference.release.as_str()]);
    }

    #[tokio::test]
    async fn toolchain_guests_keep_the_workspaces_network_policy() {
        let digest = "a".repeat(64);
        let output = digest.clone();
        let fake = sb::fake::Fake::new(sb::Capabilities { snapshots: true, network_allowlist: true, ..Default::default() })
            .with_program("/bin/sh", move |_, command, _, mut stdout| {
                let output = output.clone();
                async move {
                    if command.args.iter().any(|arg| arg.contains("sha256sum toolchain.json")) {
                        stdout.write_all(format!("{output}  toolchain.json\n").as_bytes()).await.unwrap();
                    }
                    0
                }
            });
        fake.create(sb::SandboxSpec {
            name: "seed".into(), template: sb::Template::Image("fixture".into()), cpus: 1, memory_mib: 512,
            security: sb::Security::Restricted, network: sb::Network::None, gpu: None, labels: Default::default(), mounts: vec![], max_duration: None,
        }).await.unwrap();
        let snapshot = fake.snapshot("seed").await.unwrap();
        let config: Config = serde_json::from_value(serde_json::json!({
            "listen":"127.0.0.1:0", "stateRoot":"/tmp/state", "msb":"/bin/msb", "sessionBinary":"/bin/session", "secretFile":"/tmp/secret",
            "toolchain":{"snapshot":snapshot.0,"digest":digest},
            "syncGateway":{"url":"https://sync.example.test","secret":"gateway-test-secret"}
        })).unwrap();
        for (name, synced) in [("code", false), ("synced", true)] {
            let network = config.workspace_network(synced).unwrap();
            restore(&fake, &config, name, Default::default(), vec![], network.clone()).await.unwrap();
            assert_eq!(fake.spec(name).unwrap().network, network);
        }
    }
}
