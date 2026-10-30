use super::*;
use crate::msb::Msb;
use rayde_sandbox::{self as sb, SandboxProvider as _};
use serde::{Deserialize, Serialize};

const WORKSPACE_MIB: u32 = 1024;
const STATE_MIB: u32 = 512;

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Storage {
    workspace: String,
    state: String,
    identity: String,
}
impl Storage {
    pub fn new(instance: &str, id: &str) -> Self {
        let prefix = format!("rayde-{}-{id}", &instance[..16]);
        Self { workspace: format!("{prefix}-work"), state: format!("{prefix}-state"), identity: random() }
    }
    pub fn valid(&self, instance: &str, id: &str) -> bool {
        let prefix = format!("rayde-{}-{id}", &instance[..16]);
        self.workspace == format!("{prefix}-work") && self.state == format!("{prefix}-state")
            && self.identity.len() == 64 && self.identity.bytes().all(|byte| byte.is_ascii_hexdigit())
    }
    /// What a sandbox mounts. Creating the sandbox fails with `NotFound` for a volume that is missing, so a recovery never starts on empty disks.
    pub fn mounts(&self) -> Vec<sb::Mount> {
        [(&self.workspace, "/workspace"), (&self.state, "/state")]
            .map(|(name, destination)| sb::Mount { source: sb::Source::Volume(name.clone()), destination: destination.into(), read_only: false })
            .to_vec()
    }
    /// Creates the volumes a new workspace needs, keeping any that exist.
    pub async fn prepare(&self, backend: &Msb) -> Result<()> {
        for (name, size_mib) in [(&self.workspace, WORKSPACE_MIB), (&self.state, STATE_MIB)] {
            backend.create_volume(sb::VolumeSpec { name: name.clone(), size_mib }).await?;
        }
        Ok(())
    }
    /// Checks, from inside the guest, that each disk carries this workspace's identity, writing it first when `initialize`.
    pub async fn bind(&self, backend: &Msb, sandbox: &str, initialize: bool) -> Result<()> {
        let script = "for dir in /workspace /state; do if test -f \"$dir/.rayde-volume\"; then test \"$(cat \"$dir/.rayde-volume\")\" = \"$1\"; else test \"$2\" = initialize; printf '%s\\n' \"$1\" > \"$dir/.rayde-volume\"; fi; done; sync";
        let command = sb::Command {
            program: "/bin/sh".into(),
            args: ["-ec", script, "--", &self.identity, if initialize { "initialize" } else { "verify" }].map(String::from).to_vec(),
            env: Default::default(),
        };
        let output = backend.run(sandbox, command, 64 * 1024, std::time::Duration::from_secs(10)).await?;
        if output.status != 0 {
            return Err(unavailable());
        }
        Ok(())
    }
    pub async fn remove(&self, backend: &Msb) -> Result<()> {
        for name in [&self.workspace, &self.state] {
            backend.remove_volume(name).await.map_err(|error| match error {
                sb::Error::Conflict(_) => Failure(StatusCode::CONFLICT, "Workspace disk removal needs reconciliation."),
                other => other.into(),
            })?;
        }
        Ok(())
    }
}
