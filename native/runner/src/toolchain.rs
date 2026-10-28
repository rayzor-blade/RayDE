use super::*;

pub(crate) fn identity(config: &Config) -> Option<String> {
    config.toolchain.as_ref().map(|toolchain| toolchain.digest.clone())
}

pub(crate) async fn restore(config: &Config, sandbox: &str, runner: &str, workspace: &str, mounts: Option<&crate::volumes::Mounts>) -> Result<()> {
    let toolchain = config.toolchain.as_ref().ok_or_else(invalid)?;
    command::call(config, ["snapshot", "verify", &toolchain.snapshot], 30).await?;
    let mut args = vec!["snapshot".to_owned(), "restore".into(), toolchain.snapshot.clone(), "--name".into(), sandbox.into(),
        "--cpus".into(), config.cpus.to_string(), "--memory".into(), format!("{}M", config.memory_mib),
        "--security".into(), "restricted".into(), "--no-net".into(), "--max-duration".into(), format!("{}s", config.max_duration_seconds)];
    if let Some(mounts) = mounts {args.extend(["--mount-disk".into(), format!("{}:/workspace", mounts.workspace.display()), "--mount-disk".into(), format!("{}:/state", mounts.state.display())]);}
    command::call(config, args, 45).await?;
    command::call(config, ["modify", sandbox, "--label", runner, "--label", workspace], 5).await?;
    let digest = command::call(config, [
        "exec", sandbox, "--quiet", "--no-stdin", "--", "/bin/sh", "-ec",
        "cd /opt/rayde; sha256sum -c SHA256SUMS >/dev/null; sha256sum toolchain.json",
    ], 30).await?;
    if String::from_utf8_lossy(&digest).split_whitespace().next() != Some(&toolchain.digest) {
        return Err(Failure(StatusCode::CONFLICT, "The guest toolchain identity does not match its configuration."));
    }
    command::call(config, [
        "exec", sandbox, "--quiet", "--no-stdin", "--", "/bin/sh", "-ec",
        "export LD_LIBRARY_PATH=/opt/rayde/lib; /opt/rayde/bin/haxe --version; /opt/rayde/bin/ash --version; /opt/rayde/bin/rayzor --version; test -f /opt/rayde/haxe-std/StdTypes.hx; test -f /opt/rayde/environment.json; test -x /opt/rayde/bin/rayde-extension-host; test -f /opt/rayde/extensions/git/git.rayext; test -f /opt/rayde/extensions/markdown/markdown.rayext; test -f /opt/rayde/extensions/rayzor/rayzor.rayext",
    ], 15).await?;
    Ok(())
}

pub(crate) fn session_args(config: &Config) -> Vec<&'static str> {
    if config.toolchain.is_none() { return Vec::new(); }
    vec!["--env-file", "/opt/rayde/environment.json", "--extension-host", "/opt/rayde/bin/rayde-extension-host", "--extensions", "/opt/rayde/extensions", "--read-root", "/opt/rayde/haxelib", "--read-root", "/opt/rayde/haxe-std", "--read-root", "/opt/rayde/haxe/std"]
}
