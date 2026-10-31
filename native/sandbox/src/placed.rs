//! Two backends behind one `SandboxProvider`, with the choice of backend made here from what a sandbox needs.
//!
//! A request goes to the primary backend when it can do everything the spec asks, else to the secondary, else it fails with
//! `Unsupported` naming the feature; a request is never placed where a requirement would be silently dropped (an egress allowlist on a
//! backend that cannot enforce one). Later calls by name go to the backend that holds the sandbox.

use crate::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Primary,
    Secondary,
}

pub struct Placed<A, B> {
    primary: A,
    secondary: B,
}

/// What a spec needs from a backend.
fn missing(spec: &SandboxSpec, caps: &Capabilities) -> Option<&'static str> {
    if spec.gpu.is_some() && !caps.gpu {
        return Some("gpu");
    }
    if matches!(spec.network, Network::Allow(_)) && !caps.network_allowlist {
        return Some("network allowlist");
    }
    if matches!(spec.template, Template::Snapshot(_)) && !caps.snapshots {
        return Some("snapshots");
    }
    None
}

const SEPARATOR: char = '/';

/// A snapshot belongs to the backend that took it; its reference says which.
fn tag(side: Side, inner: SnapshotRef) -> SnapshotRef {
    SnapshotRef(format!("{}{SEPARATOR}{}", if side == Side::Primary { 'p' } else { 's' }, inner.0))
}

fn untag(snapshot: &SnapshotRef) -> Result<(Side, SnapshotRef)> {
    match snapshot.0.split_once(SEPARATOR) {
        Some(("p", inner)) => Ok((Side::Primary, SnapshotRef(inner.into()))),
        Some(("s", inner)) => Ok((Side::Secondary, SnapshotRef(inner.into()))),
        _ => Err(Error::NotFound),
    }
}

impl<A: SandboxProvider, B: SandboxProvider> Placed<A, B> {
    pub fn new(primary: A, secondary: B) -> Self {
        Self { primary, secondary }
    }

    async fn owner(&self, name: &str) -> Result<Option<Side>> {
        if self.primary.get(name).await?.is_some() {
            return Ok(Some(Side::Primary));
        }
        Ok(self.secondary.get(name).await?.map(|_| Side::Secondary))
    }

    async fn volume_owner(&self, name: &str) -> Result<Option<Side>> {
        if self.primary.volume(name).await?.is_some() {
            return Ok(Some(Side::Primary));
        }
        Ok(self.secondary.volume(name).await?.map(|_| Side::Secondary))
    }

    /// Where `spec` would run, without creating it.
    pub async fn place(&self, spec: &SandboxSpec) -> Result<Side> {
        let (first, second) = (missing(spec, &self.primary.capabilities()), missing(spec, &self.secondary.capabilities()));
        let mut side = match (first, second) {
            (None, _) => Side::Primary,
            (Some(_), None) => Side::Secondary,
            (Some(a), Some(b)) => {
                // Name the requirement the primary lacks, unless the secondary lacks that one too and the first is another.
                return Err(Error::Unsupported(if a == b { a } else { "a backend that has every requested feature" }));
            }
        };
        if let Template::Snapshot(snapshot) = &spec.template {
            let (owner, _) = untag(snapshot)?;
            if owner != side {
                return Err(Error::Conflict("The snapshot belongs to another backend than the one this sandbox needs.".into()));
            }
            side = owner;
        }
        for mount in &spec.mounts {
            if let Source::Volume(name) = &mount.source {
                if let Some(owner) = self.volume_owner(name).await? {
                    if owner != side {
                        return Err(Error::Conflict("The volume lives on another backend than the one this sandbox needs.".into()));
                    }
                }
            }
        }
        Ok(side)
    }
}

impl<A: SandboxProvider, B: SandboxProvider> SandboxProvider for Placed<A, B> {
    /// Each feature is on when either backend has it; a request needing several is placed on one backend or refused.
    fn capabilities(&self) -> Capabilities {
        let (a, b) = (self.primary.capabilities(), self.secondary.capabilities());
        Capabilities {
            persistent_volumes: a.persistent_volumes || b.persistent_volumes,
            min_volume_mib: match (a.persistent_volumes, b.persistent_volumes) {
                (true, true) => a.min_volume_mib.max(b.min_volume_mib),
                (true, false) => a.min_volume_mib,
                _ => b.min_volume_mib,
            },
            snapshots: a.snapshots || b.snapshots,
            fork: a.fork || b.fork,
            gpu: a.gpu || b.gpu,
            network_allowlist: a.network_allowlist || b.network_allowlist,
            warm_pool: a.warm_pool || b.warm_pool,
            max_sandboxes: if a.max_sandboxes == 0 || b.max_sandboxes == 0 { 0 } else { a.max_sandboxes + b.max_sandboxes },
        }
    }

    async fn create_volume(&self, spec: VolumeSpec) -> Result<VolumeInfo> {
        if let Some(side) = self.volume_owner(&spec.name).await? {
            return match side {
                Side::Primary => self.primary.create_volume(spec).await,
                Side::Secondary => self.secondary.create_volume(spec).await,
            };
        }
        if self.primary.capabilities().persistent_volumes { self.primary.create_volume(spec).await } else { self.secondary.create_volume(spec).await }
    }

    async fn volume(&self, name: &str) -> Result<Option<VolumeInfo>> {
        match self.volume_owner(name).await? {
            Some(Side::Primary) => self.primary.volume(name).await,
            Some(Side::Secondary) => self.secondary.volume(name).await,
            None => Ok(None),
        }
    }

    async fn remove_volume(&self, name: &str) -> Result<()> {
        match self.volume_owner(name).await? {
            Some(Side::Primary) => self.primary.remove_volume(name).await,
            Some(Side::Secondary) => self.secondary.remove_volume(name).await,
            None => Ok(()),
        }
    }

    async fn create(&self, mut spec: SandboxSpec) -> Result<SandboxInfo> {
        let side = self.place(&spec).await?;
        // A name held by the other backend is a conflict, not a second sandbox.
        match (self.owner(&spec.name).await?, side) {
            (Some(held), wanted) if held != wanted => return Err(Error::Conflict("The name is in use on another backend.".into())),
            _ => {}
        }
        if let Template::Snapshot(snapshot) = &spec.template {
            spec.template = Template::Snapshot(untag(snapshot)?.1);
        }
        match side {
            Side::Primary => self.primary.create(spec).await,
            Side::Secondary => self.secondary.create(spec).await,
        }
    }

    async fn get(&self, name: &str) -> Result<Option<SandboxInfo>> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.get(name).await,
            Some(Side::Secondary) => self.secondary.get(name).await,
            None => Ok(None),
        }
    }

    async fn list(&self, selector: &Labels) -> Result<Vec<SandboxInfo>> {
        let mut all = self.primary.list(selector).await?;
        all.extend(self.secondary.list(selector).await?);
        Ok(all)
    }

    async fn ping(&self, name: &str) -> Result<()> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.ping(name).await,
            Some(Side::Secondary) => self.secondary.ping(name).await,
            None => Err(Error::NotFound),
        }
    }

    async fn stop(&self, name: &str) -> Result<()> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.stop(name).await,
            Some(Side::Secondary) => self.secondary.stop(name).await,
            None => Err(Error::NotFound),
        }
    }

    async fn remove(&self, name: &str) -> Result<()> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.remove(name).await,
            Some(Side::Secondary) => self.secondary.remove(name).await,
            None => Ok(()),
        }
    }

    async fn spawn(&self, name: &str, command: Command) -> Result<Process> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.spawn(name, command).await,
            Some(Side::Secondary) => self.secondary.spawn(name, command).await,
            None => Err(Error::NotFound),
        }
    }

    async fn run(&self, name: &str, command: Command, limit: usize, within: Duration) -> Result<Output> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.run(name, command, limit, within).await,
            Some(Side::Secondary) => self.secondary.run(name, command, limit, within).await,
            None => Err(Error::NotFound),
        }
    }

    async fn detach(&self, name: &str, command: Command) -> Result<()> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.detach(name, command).await,
            Some(Side::Secondary) => self.secondary.detach(name, command).await,
            None => Err(Error::NotFound),
        }
    }

    async fn copy_in(&self, name: &str, host: PathBuf, guest: &str) -> Result<()> {
        match self.owner(name).await? {
            Some(Side::Primary) => self.primary.copy_in(name, host, guest).await,
            Some(Side::Secondary) => self.secondary.copy_in(name, host, guest).await,
            None => Err(Error::NotFound),
        }
    }

    async fn snapshot(&self, name: &str) -> Result<SnapshotRef> {
        match self.owner(name).await? {
            Some(Side::Primary) => Ok(tag(Side::Primary, self.primary.snapshot(name).await?)),
            Some(Side::Secondary) => Ok(tag(Side::Secondary, self.secondary.snapshot(name).await?)),
            None => Err(Error::NotFound),
        }
    }

    async fn verify_snapshot(&self, snapshot: &SnapshotRef) -> Result<()> {
        match untag(snapshot)? {
            (Side::Primary, inner) => self.primary.verify_snapshot(&inner).await,
            (Side::Secondary, inner) => self.secondary.verify_snapshot(&inner).await,
        }
    }

    async fn remove_snapshot(&self, snapshot: &SnapshotRef) -> Result<()> {
        match untag(snapshot) {
            Ok((Side::Primary, inner)) => self.primary.remove_snapshot(&inner).await,
            Ok((Side::Secondary, inner)) => self.secondary.remove_snapshot(&inner).await,
            Err(_) => Ok(()),
        }
    }
}
