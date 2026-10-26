use super::*;
use std::{ffi::OsString, process::Stdio, time::Duration};
use tokio::{
    io::AsyncReadExt,
    process::{Child, Command},
};

const OUTPUT: usize = 64 * 1024;
pub(crate) struct Process {
    pub child: Child,
    pid: Option<u32>,
}
impl Drop for Process {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.pid {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
}
impl Process {
    pub fn new(mut command: Command) -> Result<Self> {
        command.kill_on_drop(true);
        #[cfg(unix)]
        {
            command.process_group(0);
        }
        let child = command.spawn()?;
        let pid = child.id();
        Ok(Self { child, pid })
    }
    pub async fn finish(&mut self) -> Result<()> {
        let status = self.child.wait().await?;
        self.pid = None;
        if !status.success() {
            return Err(unavailable());
        }
        Ok(())
    }
}
pub(crate) fn msb(config: &Config) -> Command {
    let mut command = Command::new(&config.msb);
    command
        .env_clear()
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .env("MSB_BACKEND", "local");
    if let Some(home) = std::env::var_os("HOME") {
        command.env("HOME", home);
    }
    command
}
pub(crate) async fn capture(mut command: Command, seconds: u64) -> Result<Vec<u8>> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut process = Process::new(command)?;
    let mut out = process
        .child
        .stdout
        .take()
        .ok_or_else(unavailable)?
        .take((OUTPUT + 1) as u64);
    let mut err = process
        .child
        .stderr
        .take()
        .ok_or_else(unavailable)?
        .take((OUTPUT + 1) as u64);
    let work = async {
        let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
        let (_, _, status) = tokio::try_join!(
            out.read_to_end(&mut stdout),
            err.read_to_end(&mut stderr),
            process.child.wait()
        )?;
        if !status.success() || stdout.len() > OUTPUT || stderr.len() > OUTPUT {
            return Err(unavailable());
        }
        process.pid = None;
        Ok(stdout)
    };
    tokio::time::timeout(Duration::from_secs(seconds), work)
        .await
        .map_err(|_| unavailable())?
}
pub(crate) async fn call(
    config: &Config,
    args: impl IntoIterator<Item = impl Into<OsString>>,
    seconds: u64,
) -> Result<Vec<u8>> {
    let mut command = msb(config);
    command.args(args.into_iter().map(Into::into));
    capture(command, seconds).await
}
