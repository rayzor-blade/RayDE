//! The gateway's state for one synced workspace: what it holds, the uploads in flight, and how a generation is published. No I/O; the Worker's
//! Durable Object stores this value and calls these methods, and supplies what only it can know (whether a chunk is durable in storage).
//!
//! An upload is a lease: `begin` reserves quota for the chunks the workspace does not hold, `record_chunk` notes each one as it lands,
//! and `publish` replaces the current generation in one step or not at all. A failed, cancelled or abandoned upload leaves the last valid
//! generation as it was and returns its reservation.
use crate::{
    chunk::MAX_CHUNK,
    ids::{AccountId, WorkspaceId},
    lifecycle::{Entitlement, Expiry, Limits, OverLimit, Usage, reserve},
    manifest::{ChunkRef, Manifest},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Uploads a workspace may have in flight at once.
pub const MAX_ACTIVE_UPLOADS: usize = 4;
/// How long an upload may sit before it is abandoned and its reservation returns.
pub const LEASE_MS: u64 = 60 * 60_000;

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum SyncError {
    /// The workspace has expired.
    Expired,
    TooManyUploads,
    /// A declared chunk is malformed: a hash that is not 64 lowercase hex characters, a size of zero or past the limit, or one hash with two sizes.
    BadChunk(String),
    OverLimit(OverLimit),
    UnknownLease,
    /// The upload sat past its lease.
    LeaseExpired,
    /// Access changed since the upload began, so its lease is void.
    AclChanged,
    /// The manifest was taken against a generation that is no longer current.
    StaleGeneration { current: u64 },
    WrongWorkspace,
    /// The checksum does not match, or validation found problems; the codes are those of `Manifest::validate`.
    ManifestInvalid(Vec<String>),
    /// The manifest names a chunk the upload did not declare and the workspace does not hold, or with another size.
    UndeclaredChunk(String),
    /// A declared chunk was never uploaded, or is not durable.
    ChunkMissing(String),
}

impl SyncError {
    /// A stable code for clients.
    pub fn code(&self) -> &'static str {
        match self {
            SyncError::Expired => "expired",
            SyncError::TooManyUploads => "too-many-uploads",
            SyncError::BadChunk(_) => "bad-chunk",
            SyncError::OverLimit(OverLimit::Workspace { .. }) => "workspace-over-allocation",
            SyncError::OverLimit(OverLimit::Account { .. }) => "account-over-quota",
            SyncError::UnknownLease => "unknown-lease",
            SyncError::LeaseExpired => "lease-expired",
            SyncError::AclChanged => "access-changed",
            SyncError::StaleGeneration { .. } => "stale-generation",
            SyncError::WrongWorkspace => "wrong-workspace",
            SyncError::ManifestInvalid(_) => "manifest-invalid",
            SyncError::UndeclaredChunk(_) => "undeclared-chunk",
            SyncError::ChunkMissing(_) => "chunk-missing",
        }
    }

    /// The HTTP status a gateway answers with.
    pub fn status(&self) -> u16 {
        match self {
            SyncError::Expired | SyncError::LeaseExpired => 410,
            SyncError::TooManyUploads => 429,
            SyncError::OverLimit(_) => 413,
            SyncError::UnknownLease => 404,
            SyncError::AclChanged => 403,
            SyncError::StaleGeneration { .. } => 409,
            SyncError::BadChunk(_) | SyncError::WrongWorkspace | SyncError::ManifestInvalid(_) | SyncError::UndeclaredChunk(_) | SyncError::ChunkMissing(_) => 422,
        }
    }
}

/// An upload in flight.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Upload {
    pub base_generation: u64,
    pub acl_version: u64,
    /// Bytes reserved for the chunks the workspace did not hold when the upload began.
    pub reserved: u64,
    /// Every chunk the upload declared, held or not, with its size.
    pub declared: BTreeMap<String, u32>,
    /// The declared chunks that were not held, which the upload has to send.
    pub needed: BTreeSet<String>,
    pub received: BTreeSet<String>,
    pub started_at: u64,
}

/// What `begin` hands the client.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Lease {
    pub base_generation: u64,
    pub acl_version: u64,
    /// The chunks to send, sorted. Resuming asks `pending` again.
    pub missing: Vec<String>,
    pub reserved: u64,
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Published {
    pub generation: u64,
    pub expires_at: Option<u64>,
    pub stored_bytes: u64,
    /// Chunks no longer referenced by any generation or upload, which the caller deletes from storage.
    pub garbage: Vec<String>,
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Status {
    pub generation: u64,
    pub usage: Usage,
    pub expires_at: Option<u64>,
    pub uploads: usize,
}

/// One synced workspace.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct SyncWorkspace {
    pub id: WorkspaceId,
    pub owner: AccountId,
    pub allocation_bytes: u64,
    pub expiry: Expiry,
    /// The current generation; 0 until the first publication.
    pub generation: u64,
    pub usage: Usage,
    /// Advanced by anything that could reduce someone's access; a lease from before it is void.
    pub acl_version: u64,
    /// The chunks the current generation references, with sizes.
    pub held: BTreeMap<String, u32>,
    pub manifest_checksum: Option<String>,
    pub uploads: BTreeMap<String, Upload>,
}

fn hash_ok(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl SyncWorkspace {
    /// A new workspace, empty at generation 0. Its allocation and expiry come from the plan and the owner's choice, within it.
    pub fn create(id: WorkspaceId, owner: AccountId, plan: &Entitlement, allocation_bytes: u64, duration_ms: u64) -> Self {
        SyncWorkspace {
            id,
            owner,
            allocation_bytes: allocation_bytes.min(plan.max_allocation_bytes),
            expiry: Expiry::new(duration_ms.min(plan.max_expiry_ms)),
            generation: 0,
            usage: Usage::default(),
            acl_version: 0,
            held: BTreeMap::new(),
            manifest_checksum: None,
            uploads: BTreeMap::new(),
        }
    }

    pub fn status(&self) -> Status {
        Status { generation: self.generation, usage: self.usage, expires_at: self.expiry.expires_at, uploads: self.uploads.len() }
    }

    /// Begins an upload of `declared`, the distinct chunks the new generation stores. Reserves quota for those not already held, against the
    /// workspace's allocation and the account's total (`others_bytes` is what the account's other workspaces use), and returns the lease.
    /// Nothing is reserved when it fails. `lease` is the caller's fresh identifier for the upload.
    pub fn begin(&mut self, now: u64, plan: &Entitlement, others_bytes: u64, declared: &[ChunkRef], lease: &str) -> Result<Lease, SyncError> {
        if self.expiry.is_expired(now) {
            return Err(SyncError::Expired);
        }
        self.sweep(now);
        if self.uploads.len() >= MAX_ACTIVE_UPLOADS {
            return Err(SyncError::TooManyUploads);
        }
        let mut sizes: BTreeMap<String, u32> = BTreeMap::new();
        for chunk in declared {
            if !hash_ok(&chunk.hash) {
                return Err(SyncError::BadChunk(chunk.hash.clone()));
            }
            if chunk.size == 0 || chunk.size as usize > MAX_CHUNK {
                return Err(SyncError::BadChunk(chunk.hash.clone()));
            }
            if sizes.insert(chunk.hash.clone(), chunk.size).is_some_and(|before| before != chunk.size) {
                return Err(SyncError::BadChunk(chunk.hash.clone()));
            }
        }
        let needed: BTreeSet<String> = sizes.keys().filter(|h| !self.held.contains_key(*h)).cloned().collect();
        let add: u64 = needed.iter().map(|h| sizes[h] as u64).sum();
        let usage = reserve(&self.usage, self.allocation_bytes, others_bytes.saturating_add(self.usage.total()), plan, add).map_err(SyncError::OverLimit)?;
        self.usage = usage;
        let missing: Vec<String> = needed.iter().cloned().collect();
        self.uploads.insert(
            lease.to_string(),
            Upload { base_generation: self.generation, acl_version: self.acl_version, reserved: add, declared: sizes, needed, received: BTreeSet::new(), started_at: now },
        );
        Ok(Lease { base_generation: self.generation, acl_version: self.acl_version, missing, reserved: add })
    }

    fn live(&mut self, now: u64, lease: &str) -> Result<&mut Upload, SyncError> {
        let upload = self.uploads.get(lease).ok_or(SyncError::UnknownLease)?;
        if now.saturating_sub(upload.started_at) > LEASE_MS {
            self.drop_upload(lease);
            return Err(SyncError::LeaseExpired);
        }
        if upload.acl_version != self.acl_version {
            self.drop_upload(lease);
            return Err(SyncError::AclChanged);
        }
        Ok(self.uploads.get_mut(lease).expect("the upload was just found"))
    }

    /// Removes an upload and returns its reservation. Reports the chunks it received that nothing else references.
    fn drop_upload(&mut self, lease: &str) -> Vec<String> {
        let Some(upload) = self.uploads.remove(lease) else { return vec![] };
        self.usage = self.usage.release(upload.reserved);
        upload.received.into_iter().filter(|h| !self.held.contains_key(h) && !self.uploads.values().any(|u| u.declared.contains_key(h))).collect()
    }

    /// Notes that a chunk of this upload has been stored. Idempotent: a chunk sent twice counts once. The caller has already checked its
    /// length and hash while receiving it.
    pub fn record_chunk(&mut self, now: u64, lease: &str, hash: &str, size: u32) -> Result<(), SyncError> {
        let upload = self.live(now, lease)?;
        match upload.declared.get(hash) {
            Some(declared) if *declared == size => {}
            Some(_) => return Err(SyncError::BadChunk(hash.to_string())),
            None => return Err(SyncError::UndeclaredChunk(hash.to_string())),
        }
        if upload.needed.contains(hash) {
            upload.received.insert(hash.to_string());
        }
        Ok(())
    }

    /// The chunks of this upload still to send: after a dropped connection a client asks here and sends only these.
    pub fn pending(&mut self, now: u64, lease: &str) -> Result<Vec<String>, SyncError> {
        let upload = self.live(now, lease)?;
        Ok(upload.needed.difference(&upload.received).cloned().collect())
    }

    /// Publishes the manifest as the next generation. It must verify and validate, be taken against the current generation, and name only
    /// chunks that are held or were declared; each declared chunk must have been received and be `durable`. On any refusal the workspace is
    /// unchanged and the last valid generation stays: the lease is kept, to retry, unless it was void or stale.
    pub fn publish(&mut self, now: u64, lease: &str, manifest: &Manifest, limits: &Limits, durable: &dyn Fn(&str) -> bool) -> Result<Published, SyncError> {
        if self.expiry.is_expired(now) {
            return Err(SyncError::Expired);
        }
        let upload = self.live(now, lease)?.clone();
        if manifest.workspace != self.id {
            return Err(SyncError::WrongWorkspace);
        }
        if !manifest.verify() {
            return Err(SyncError::ManifestInvalid(vec!["checksum".into()]));
        }
        let problems = manifest.validate(limits);
        if !problems.is_empty() {
            return Err(SyncError::ManifestInvalid(problems.iter().map(|p| p.code.to_string()).collect()));
        }
        if manifest.base_generation != self.generation || upload.base_generation != self.generation || manifest.generation != self.generation + 1 {
            return Err(SyncError::StaleGeneration { current: self.generation });
        }
        let stored = manifest.chunk_set();
        for (hash, size) in &stored {
            match (self.held.get(hash), upload.declared.get(hash)) {
                (Some(held), _) if held == size => {}
                (None, Some(declared)) if declared == size => {
                    if !upload.received.contains(hash) || !durable(hash) {
                        return Err(SyncError::ChunkMissing(hash.clone()));
                    }
                }
                _ => return Err(SyncError::UndeclaredChunk(hash.clone())),
            }
        }
        let stored_bytes: u64 = stored.values().map(|s| *s as u64).sum();
        // Garbage: what the old generation held and the new one does not, and what this upload received but the manifest left out.
        let mut garbage: Vec<String> = self.held.keys().filter(|h| !stored.contains_key(*h)).cloned().collect();
        garbage.extend(upload.received.iter().filter(|h| !stored.contains_key(*h) && !self.held.contains_key(*h)).cloned());
        garbage.retain(|h| !self.uploads.iter().any(|(id, other)| id != lease && other.declared.contains_key(h)));
        self.uploads.remove(lease);
        self.usage = Usage { referenced_bytes: stored_bytes, reserved_bytes: self.usage.reserved_bytes.saturating_sub(upload.reserved) };
        self.held = stored;
        self.generation += 1;
        self.manifest_checksum = Some(manifest.checksum.clone());
        self.expiry.published(now);
        Ok(Published { generation: self.generation, expires_at: self.expiry.expires_at, stored_bytes, garbage })
    }

    /// The owner cancels an upload. Returns the chunks it received that nothing else references, to delete.
    pub fn cancel(&mut self, lease: &str) -> Result<Vec<String>, SyncError> {
        if !self.uploads.contains_key(lease) {
            return Err(SyncError::UnknownLease);
        }
        Ok(self.drop_upload(lease))
    }

    /// Abandons the uploads that sat past their lease, returning their reservations. Reports the chunks to delete.
    pub fn sweep(&mut self, now: u64) -> Vec<String> {
        let stale: Vec<String> = self.uploads.iter().filter(|(_, u)| now.saturating_sub(u.started_at) > LEASE_MS).map(|(id, _)| id.clone()).collect();
        stale.iter().flat_map(|id| self.drop_upload(id)).collect()
    }

    /// Access was reduced: every upload in flight is void and its reservation returns.
    pub fn revoke(&mut self) -> Vec<String> {
        self.acl_version += 1;
        let all: Vec<String> = self.uploads.keys().cloned().collect();
        all.iter().flat_map(|id| self.drop_upload(id)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        chunk::sha256_hex,
        manifest::fixtures,
    };

    const T0: u64 = 1_800_000_000_000;

    fn id() -> WorkspaceId {
        WorkspaceId::from_random(&[42; 32])
    }

    fn owner() -> AccountId {
        AccountId::parse("account-1").unwrap()
    }

    fn workspace(plan: &Entitlement) -> SyncWorkspace {
        SyncWorkspace::create(id(), owner(), plan, plan.max_allocation_bytes, plan.max_expiry_ms)
    }

    /// The fixture manifest as the generation after `generation`.
    fn next(generation: u64) -> Manifest {
        let mut m = fixtures::manifest();
        m.generation = generation + 1;
        m.base_generation = generation;
        m.finalize();
        m
    }

    fn declared(m: &Manifest) -> Vec<ChunkRef> {
        m.chunk_set().into_iter().map(|(hash, size)| ChunkRef { hash, size }).collect()
    }

    fn all_durable(_: &str) -> bool {
        true
    }

    /// Begins an upload of `m` and sends every chunk.
    fn upload(w: &mut SyncWorkspace, plan: &Entitlement, lease: &str, m: &Manifest, now: u64) -> Lease {
        let lease_info = w.begin(now, plan, 0, &declared(m), lease).unwrap();
        for hash in &lease_info.missing {
            w.record_chunk(now, lease, hash, m.chunk_set()[hash]).unwrap();
        }
        lease_info
    }

    #[test]
    fn a_first_publication_starts_the_clock_and_turns_the_reservation_into_referenced_bytes() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let lease = upload(&mut w, &plan, "a", &m, T0);
        assert_eq!(lease.base_generation, 0);
        assert_eq!(w.usage.reserved_bytes, m.totals.stored_bytes);
        let done = w.publish(T0 + 5, "a", &m, &Limits::default(), &all_durable).unwrap();
        assert_eq!(done.generation, 1);
        assert_eq!(done.stored_bytes, m.totals.stored_bytes);
        assert_eq!(done.expires_at, Some(T0 + 5 + plan.max_expiry_ms));
        assert_eq!(w.usage, Usage { referenced_bytes: m.totals.stored_bytes, reserved_bytes: 0 });
        assert!(w.uploads.is_empty());
    }

    #[test]
    fn a_later_publication_never_moves_the_expiry() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let first = next(0);
        upload(&mut w, &plan, "a", &first, T0);
        let published = w.publish(T0, "a", &first, &Limits::default(), &all_durable).unwrap();
        let second = next(1);
        upload(&mut w, &plan, "b", &second, T0 + 1000);
        let again = w.publish(T0 + 1000, "b", &second, &Limits::default(), &all_durable).unwrap();
        assert_eq!(again.generation, 2);
        assert_eq!(again.expires_at, published.expires_at);
    }

    #[test]
    fn a_second_sync_of_the_same_content_sends_nothing_and_reserves_nothing() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        w.publish(T0, "a", &m, &Limits::default(), &all_durable).unwrap();
        let second = next(1);
        let lease = w.begin(T0 + 10, &plan, 0, &declared(&second), "b").unwrap();
        assert!(lease.missing.is_empty());
        assert_eq!(lease.reserved, 0);
        let done = w.publish(T0 + 10, "b", &second, &Limits::default(), &all_durable).unwrap();
        assert_eq!(done.generation, 2);
        assert!(done.garbage.is_empty());
    }

    #[test]
    fn content_that_changes_leaves_the_old_chunks_as_garbage_and_their_bytes_released() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let first = next(0);
        upload(&mut w, &plan, "a", &first, T0);
        w.publish(T0, "a", &first, &Limits::default(), &all_durable).unwrap();
        let mut second = next(1);
        second.files = vec![fixtures::file("src/Main.hx", b"class Main { static function main() {} }\n")];
        second.buffers.clear();
        second.git.index.clear();
        second.finalize();
        upload(&mut w, &plan, "b", &second, T0 + 10);
        let done = w.publish(T0 + 10, "b", &second, &Limits::default(), &all_durable).unwrap();
        assert!(!done.garbage.is_empty());
        for hash in &done.garbage {
            assert!(!w.held.contains_key(hash));
        }
        assert_eq!(w.usage.referenced_bytes, second.totals.stored_bytes);
    }

    #[test]
    fn a_chunk_with_the_wrong_size_or_one_never_declared_is_refused() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let lease = w.begin(T0, &plan, 0, &declared(&m), "a").unwrap();
        let hash = &lease.missing[0];
        assert_eq!(w.record_chunk(T0, "a", hash, m.chunk_set()[hash] + 1), Err(SyncError::BadChunk(hash.clone())));
        let stranger = sha256_hex(b"not declared");
        assert_eq!(w.record_chunk(T0, "a", &stranger, 12), Err(SyncError::UndeclaredChunk(stranger)));
    }

    #[test]
    fn a_chunk_sent_twice_counts_once_and_resume_lists_only_what_is_left() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let lease = w.begin(T0, &plan, 0, &declared(&m), "a").unwrap();
        let first = lease.missing[0].clone();
        w.record_chunk(T0, "a", &first, m.chunk_set()[&first]).unwrap();
        w.record_chunk(T0, "a", &first, m.chunk_set()[&first]).unwrap();
        let left = w.pending(T0, "a").unwrap();
        assert_eq!(left.len(), lease.missing.len() - 1);
        assert!(!left.contains(&first));
    }

    #[test]
    fn publishing_before_every_chunk_is_durable_is_refused_and_changes_nothing() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let lease = w.begin(T0, &plan, 0, &declared(&m), "a").unwrap();
        let before = w.clone();
        assert!(matches!(w.publish(T0, "a", &m, &Limits::default(), &all_durable), Err(SyncError::ChunkMissing(_))));
        assert_eq!(w, before);
        for hash in &lease.missing {
            w.record_chunk(T0, "a", hash, m.chunk_set()[hash]).unwrap();
        }
        let lost = lease.missing[0].clone();
        assert_eq!(w.publish(T0, "a", &m, &Limits::default(), &|h| h != lost), Err(SyncError::ChunkMissing(lost)));
        assert_eq!(w.generation, 0, "the last valid generation stays");
    }

    #[test]
    fn a_forged_or_invalid_manifest_is_refused() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        let mut forged = m.clone();
        forged.name = "other".into();
        assert_eq!(w.publish(T0, "a", &forged, &Limits::default(), &all_durable), Err(SyncError::ManifestInvalid(vec!["checksum".into()])));
        let mut elsewhere = m.clone();
        elsewhere.workspace = WorkspaceId::from_random(&[9; 32]);
        elsewhere.finalize();
        assert_eq!(w.publish(T0, "a", &elsewhere, &Limits::default(), &all_durable), Err(SyncError::WrongWorkspace));
        let mut tight = Limits::default();
        tight.max_files = 1;
        assert!(matches!(w.publish(T0, "a", &m, &tight, &all_durable), Err(SyncError::ManifestInvalid(codes)) if !codes.is_empty()));
        assert_eq!(w.generation, 0);
    }

    #[test]
    fn a_manifest_naming_a_chunk_the_upload_never_declared_is_refused() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let mut partial = declared(&m);
        let dropped = partial.pop().unwrap();
        let lease = w.begin(T0, &plan, 0, &partial, "a").unwrap();
        for hash in &lease.missing {
            w.record_chunk(T0, "a", hash, m.chunk_set()[hash]).unwrap();
        }
        assert_eq!(w.publish(T0, "a", &m, &Limits::default(), &all_durable), Err(SyncError::UndeclaredChunk(dropped.hash)));
    }

    #[test]
    fn two_uploads_from_the_same_generation_publish_one_and_the_other_is_stale() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        upload(&mut w, &plan, "b", &m, T0);
        w.publish(T0, "a", &m, &Limits::default(), &all_durable).unwrap();
        assert_eq!(w.publish(T0, "b", &m, &Limits::default(), &all_durable), Err(SyncError::StaleGeneration { current: 1 }));
        assert_eq!(w.generation, 1);
        // The stale upload still holds its reservation until it is cancelled.
        assert!(w.usage.reserved_bytes > 0);
        w.cancel("b").unwrap();
        assert_eq!(w.usage.reserved_bytes, 0);
    }

    #[test]
    fn two_concurrent_uploads_cannot_each_fit_alone_and_exceed_the_allocation_together() {
        let plan = Entitlement::free();
        let m = next(0);
        let one = m.totals.stored_bytes;
        let mut w = SyncWorkspace::create(id(), owner(), &plan, one + one / 2, plan.max_expiry_ms);
        w.begin(T0, &plan, 0, &declared(&m), "a").unwrap();
        let refused = w.begin(T0, &plan, 0, &declared(&m), "b").unwrap_err();
        assert!(matches!(refused, SyncError::OverLimit(OverLimit::Workspace { .. })));
        assert_eq!(refused.status(), 413);
        assert_eq!(w.uploads.len(), 1, "a refused upload reserves nothing");
        assert_eq!(w.usage.reserved_bytes, one);
    }

    #[test]
    fn the_account_total_limits_a_workspace_too() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let others = plan.max_account_bytes - 10;
        let refused = w.begin(T0, &plan, others, &declared(&m), "a").unwrap_err();
        assert!(matches!(refused, SyncError::OverLimit(OverLimit::Account { .. })));
    }

    #[test]
    fn an_upload_past_its_lease_is_abandoned_and_its_reservation_returns() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let lease = w.begin(T0, &plan, 0, &declared(&m), "a").unwrap();
        let hash = lease.missing[0].clone();
        assert_eq!(w.record_chunk(T0 + LEASE_MS + 1, "a", &hash, m.chunk_set()[&hash]), Err(SyncError::LeaseExpired));
        assert_eq!(w.usage.reserved_bytes, 0);
        assert_eq!(w.record_chunk(T0, "a", &hash, m.chunk_set()[&hash]), Err(SyncError::UnknownLease));
    }

    #[test]
    fn sweeping_abandons_stale_uploads_and_reports_their_chunks() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        let lease = w.begin(T0, &plan, 0, &declared(&m), "a").unwrap();
        let hash = lease.missing[0].clone();
        w.record_chunk(T0, "a", &hash, m.chunk_set()[&hash]).unwrap();
        assert!(w.sweep(T0 + LEASE_MS).is_empty(), "not yet past the lease");
        let garbage = w.sweep(T0 + LEASE_MS + 1);
        assert_eq!(garbage, vec![hash]);
        assert!(w.uploads.is_empty());
        assert_eq!(w.usage, Usage::default());
    }

    #[test]
    fn revoking_access_voids_every_upload_in_flight() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        let garbage = w.revoke();
        assert!(!garbage.is_empty());
        assert_eq!(w.acl_version, 1);
        assert_eq!(w.usage.reserved_bytes, 0);
        assert_eq!(w.publish(T0, "a", &m, &Limits::default(), &all_durable), Err(SyncError::UnknownLease));
    }

    #[test]
    fn a_lease_from_before_an_access_change_is_void_even_if_it_somehow_survived() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        w.acl_version += 1;
        assert_eq!(w.publish(T0, "a", &m, &Limits::default(), &all_durable), Err(SyncError::AclChanged));
        assert_eq!(w.usage.reserved_bytes, 0);
    }

    #[test]
    fn an_expired_workspace_takes_no_more_uploads() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        w.publish(T0, "a", &m, &Limits::default(), &all_durable).unwrap();
        let end = w.expiry.expires_at.unwrap();
        assert_eq!(w.begin(end, &plan, 0, &declared(&next(1)), "b"), Err(SyncError::Expired));
        assert_eq!(w.status().expires_at, Some(end));
    }

    #[test]
    fn malformed_declarations_and_too_many_uploads_are_refused() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let good = ChunkRef { hash: sha256_hex(b"x"), size: 1 };
        for bad in [
            ChunkRef { hash: "short".into(), size: 1 },
            ChunkRef { hash: "A".repeat(64), size: 1 },
            ChunkRef { hash: good.hash.clone(), size: 0 },
            ChunkRef { hash: good.hash.clone(), size: (MAX_CHUNK + 1) as u32 },
        ] {
            assert!(matches!(w.begin(T0, &plan, 0, &[bad], "a"), Err(SyncError::BadChunk(_))));
        }
        assert!(matches!(w.begin(T0, &plan, 0, &[good.clone(), ChunkRef { size: 2, ..good.clone() }], "a"), Err(SyncError::BadChunk(_))));
        for n in 0..MAX_ACTIVE_UPLOADS {
            w.begin(T0, &plan, 0, std::slice::from_ref(&good), &format!("lease-{n}")).unwrap();
        }
        assert_eq!(w.begin(T0, &plan, 0, std::slice::from_ref(&good), "one-more"), Err(SyncError::TooManyUploads));
    }

    #[test]
    fn the_state_survives_being_stored_and_loaded() {
        let plan = Entitlement::free();
        let mut w = workspace(&plan);
        let m = next(0);
        upload(&mut w, &plan, "a", &m, T0);
        let bytes = serde_json::to_vec(&w).unwrap();
        let mut loaded: SyncWorkspace = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(loaded, w);
        assert_eq!(loaded.publish(T0, "a", &m, &Limits::default(), &all_durable).unwrap().generation, 1);
    }
}
