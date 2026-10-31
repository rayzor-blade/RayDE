//! How long a synced workspace lives and how much it may hold. Workspace expiry, login expiry, invitation expiry, compute idle sleep and
//! paid retention are separate clocks; this module is the workspace's own, and the storage budget.
use serde::{Deserialize, Serialize};

/// The service's decimal gigabyte, as the plan says: 1 GB is 1,000,000,000 bytes.
pub const GB: u64 = 1_000_000_000;
pub const HOUR_MS: u64 = 3_600_000;
/// What a workspace may hold unless its owner chose and is entitled to more.
pub const DEFAULT_ALLOCATION_BYTES: u64 = GB;
/// Cloud access ends 24 hours after the first successful publication unless the owner chose otherwise.
pub const DEFAULT_EXPIRY_MS: u64 = 24 * HOUR_MS;
/// Retained allocations proposed for cost validation. These are design options, not approved prices or launch allowances.
pub const PROPOSED_RETAINED_GB: [u64; 4] = [1, 10, 50, 100];

/// What an account's plan allows. Versioned data from the entitlement catalog; the numbers here are the free pilot's.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Entitlement {
    pub max_expiry_ms: u64,
    pub max_allocation_bytes: u64,
    /// Across the account: more workspaces must not bypass the limits.
    pub max_workspaces: u32,
    /// Total bytes across every workspace the account owns.
    pub max_account_bytes: u64,
    /// Whether storage may outlive compute and stay until deleted.
    pub retained: bool,
    /// GPU session time the account may use in a billing period, metered apart from storage; 0 means the plan has no GPU class.
    #[serde(default)]
    pub gpu_ms_per_period: u64,
}

impl Entitlement {
    pub fn free() -> Self {
        Entitlement { max_expiry_ms: DEFAULT_EXPIRY_MS, max_allocation_bytes: DEFAULT_ALLOCATION_BYTES, max_workspaces: 3, max_account_bytes: 3 * GB, retained: false, gpu_ms_per_period: 0 }
    }
}

/// What a session's guest has. A workspace is the same either way: a restored snapshot can start in either class.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionClass {
    Cpu,
    Gpu,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SessionDenied {
    /// The plan has no GPU allowance.
    GpuNotInPlan,
    /// The period's GPU time is used up.
    GpuAllowanceUsed,
}

/// Whether the plan lets an account start a session of `class`, given the GPU time it has used this period. Returns the GPU time left, `None` for a CPU session.
pub fn admit(class: SessionClass, plan: &Entitlement, gpu_used_ms: u64) -> Result<Option<u64>, SessionDenied> {
    match class {
        SessionClass::Cpu => Ok(None),
        SessionClass::Gpu if plan.gpu_ms_per_period == 0 => Err(SessionDenied::GpuNotInPlan),
        SessionClass::Gpu => match plan.gpu_ms_per_period.saturating_sub(gpu_used_ms) {
            0 => Err(SessionDenied::GpuAllowanceUsed),
            left => Ok(Some(left)),
        },
    }
}

/// The caps a manifest is checked against before any byte is uploaded, so a small manifest or a compressed file cannot bypass the budget.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Limits {
    pub max_files: usize,
    pub max_file_bytes: u64,
    /// Expanded size of everything live in the workspace.
    pub max_expanded_bytes: u64,
    pub max_path_bytes: usize,
    pub max_path_depth: usize,
    /// The Git history export, if one is included.
    pub max_history_bytes: u64,
    pub max_buffers: usize,
    pub max_buffer_bytes: u64,
}

impl Limits {
    /// The caps for a workspace holding up to `allocation` bytes.
    pub fn for_allocation(allocation: u64) -> Self {
        Limits {
            max_files: 100_000,
            max_file_bytes: 100_000_000,
            max_expanded_bytes: allocation,
            max_path_bytes: 1024,
            max_path_depth: 64,
            max_history_bytes: allocation / 2,
            max_buffers: 256,
            max_buffer_bytes: 8 * 1024 * 1024,
        }
    }
}

impl Default for Limits {
    fn default() -> Self {
        Limits::for_allocation(DEFAULT_ALLOCATION_BYTES)
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ExpiryError {
    /// Nothing has been published, so there is nothing to expire.
    NotPublished,
    /// Longer than the plan allows.
    TooLong { allowed_ms: u64 },
    /// A duration that would already have ended.
    AlreadyPast,
    /// Shortening may not lengthen.
    NotShorter,
    NotRetainable,
}

/// A workspace's expiry. `expires_at` is server time, set once, at the first successful publication, and moved only by an explicit act by the owner:
/// viewing, restarting compute and silently retrying a sync never extend it.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Expiry {
    /// Length chosen by the owner, from the first publication.
    pub duration_ms: u64,
    pub first_published: Option<u64>,
    pub expires_at: Option<u64>,
    /// Retained storage that stays until deleted (needs the entitlement); `expires_at` is then empty.
    pub retained: bool,
    /// Advanced by every renewal, so a cleanup job queued under an older value cannot delete a renewed workspace.
    pub version: u64,
}

impl Expiry {
    pub fn new(duration_ms: u64) -> Self {
        Expiry { duration_ms, first_published: None, expires_at: None, retained: false, version: 0 }
    }

    /// A publication succeeded at `now`. Only the first one starts the clock.
    pub fn published(&mut self, now: u64) {
        if self.first_published.is_none() {
            self.first_published = Some(now);
            if !self.retained {
                self.expires_at = Some(now.saturating_add(self.duration_ms));
            }
        }
    }

    pub fn is_expired(&self, now: u64) -> bool {
        self.expires_at.is_some_and(|end| now >= end)
    }

    pub fn remaining(&self, now: u64) -> Option<u64> {
        self.expires_at.map(|end| end.saturating_sub(now))
    }

    /// Ends access sooner, counted from the first publication. Never lengthens.
    pub fn shorten(&mut self, now: u64, duration_ms: u64) -> Result<u64, ExpiryError> {
        let (start, end) = (self.first_published.ok_or(ExpiryError::NotPublished)?, self.expires_at.ok_or(ExpiryError::NotPublished)?);
        let wanted = start.saturating_add(duration_ms);
        if wanted >= end {
            return Err(ExpiryError::NotShorter);
        }
        if wanted <= now {
            return Err(ExpiryError::AlreadyPast);
        }
        self.duration_ms = duration_ms;
        self.expires_at = Some(wanted);
        self.version += 1;
        Ok(wanted)
    }

    /// The owner's explicit renewal: the workspace now lives `duration_ms` from `now`, within the plan.
    pub fn renew(&mut self, now: u64, duration_ms: u64, plan: &Entitlement) -> Result<u64, ExpiryError> {
        self.first_published.ok_or(ExpiryError::NotPublished)?;
        if duration_ms > plan.max_expiry_ms {
            return Err(ExpiryError::TooLong { allowed_ms: plan.max_expiry_ms });
        }
        let end = now.saturating_add(duration_ms);
        self.duration_ms = duration_ms;
        self.expires_at = Some(end);
        self.retained = false;
        self.version += 1;
        Ok(end)
    }

    /// Keeps the storage until it is deleted. Compute still sleeps; it is not an always-on promise.
    pub fn retain(&mut self, plan: &Entitlement) -> Result<(), ExpiryError> {
        if !plan.retained {
            return Err(ExpiryError::NotRetainable);
        }
        self.retained = true;
        self.expires_at = None;
        self.version += 1;
        Ok(())
    }

    /// Whether a cleanup job queued when the version was `queued_at` may delete: only if nothing renewed or changed the workspace since.
    pub fn cleanup_allowed(&self, queued_at: u64, now: u64) -> bool {
        self.version == queued_at && self.is_expired(now)
    }
}

/// What a workspace holds against its allocation: bytes its manifests reference, and bytes reserved for uploads in flight.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub struct Usage {
    pub referenced_bytes: u64,
    pub reserved_bytes: u64,
}

impl Usage {
    pub fn total(&self) -> u64 {
        self.referenced_bytes.saturating_add(self.reserved_bytes)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OverLimit {
    /// This workspace's allocation: bytes needed and bytes free.
    Workspace { needed: u64, available: u64 },
    /// The owner's total across all workspaces.
    Account { needed: u64, available: u64 },
}

/// Whether `add` bytes may be reserved before transfer. Both the workspace and the account budget must hold, and in-flight reservations count,
/// so two uploads cannot each fit alone and exceed the budget together. Nothing is charged automatically on refusal.
pub fn reserve(workspace: &Usage, allocation: u64, account_total: u64, plan: &Entitlement, add: u64) -> Result<Usage, OverLimit> {
    let allocation = allocation.min(plan.max_allocation_bytes);
    let free = allocation.saturating_sub(workspace.total());
    if add > free {
        return Err(OverLimit::Workspace { needed: add, available: free });
    }
    let account_free = plan.max_account_bytes.saturating_sub(account_total);
    if add > account_free {
        return Err(OverLimit::Account { needed: add, available: account_free });
    }
    Ok(Usage { referenced_bytes: workspace.referenced_bytes, reserved_bytes: workspace.reserved_bytes.saturating_add(add) })
}

impl Usage {
    /// A publication made `reserved` bytes referenced, and `released` bytes of older generations unreferenced.
    pub fn publish(&self, reserved: u64, released: u64) -> Usage {
        Usage { referenced_bytes: self.referenced_bytes.saturating_add(reserved).saturating_sub(released), reserved_bytes: self.reserved_bytes.saturating_sub(reserved) }
    }

    /// An upload was cancelled or abandoned: its reservation returns.
    pub fn release(&self, reserved: u64) -> Usage {
        Usage { referenced_bytes: self.referenced_bytes, reserved_bytes: self.reserved_bytes.saturating_sub(reserved) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cpu_session_is_always_admitted_and_a_gpu_one_needs_a_plan_with_time_left() {
        let free = Entitlement::free();
        assert_eq!(admit(SessionClass::Cpu, &free, u64::MAX), Ok(None));
        assert_eq!(admit(SessionClass::Gpu, &free, 0), Err(SessionDenied::GpuNotInPlan));
        let plan = Entitlement { gpu_ms_per_period: 60 * 60_000, ..Entitlement::free() };
        assert_eq!(admit(SessionClass::Gpu, &plan, 0), Ok(Some(60 * 60_000)));
        assert_eq!(admit(SessionClass::Gpu, &plan, 59 * 60_000), Ok(Some(60_000)));
        assert_eq!(admit(SessionClass::Gpu, &plan, 60 * 60_000), Err(SessionDenied::GpuAllowanceUsed));
        assert_eq!(admit(SessionClass::Gpu, &plan, u64::MAX), Err(SessionDenied::GpuAllowanceUsed));
    }

    #[test]
    fn an_entitlement_saved_before_the_gpu_class_has_no_gpu_time() {
        let old = r#"{"max_expiry_ms":86400000,"max_allocation_bytes":1000000000,"max_workspaces":3,"max_account_bytes":3000000000,"retained":false}"#;
        let plan: Entitlement = serde_json::from_str(old).unwrap();
        assert_eq!(plan, Entitlement::free());
    }

    #[test]
    fn the_clock_starts_at_the_first_publication_and_only_there() {
        let mut e = Expiry::new(DEFAULT_EXPIRY_MS);
        assert_eq!(e.expires_at, None);
        assert!(!e.is_expired(u64::MAX), "nothing published, nothing expires");
        e.published(1_000);
        assert_eq!(e.expires_at, Some(1_000 + DEFAULT_EXPIRY_MS));
        e.published(5_000_000);
        assert_eq!(e.expires_at, Some(1_000 + DEFAULT_EXPIRY_MS), "a later sync does not extend it");
        assert_eq!(e.remaining(1_000 + HOUR_MS), Some(23 * HOUR_MS));
        assert!(e.is_expired(1_000 + DEFAULT_EXPIRY_MS) && !e.is_expired(999 + DEFAULT_EXPIRY_MS));
    }

    #[test]
    fn shortening_never_lengthens_and_cannot_end_in_the_past() {
        let mut e = Expiry::new(DEFAULT_EXPIRY_MS);
        assert_eq!(e.shorten(0, HOUR_MS), Err(ExpiryError::NotPublished));
        e.published(0);
        assert_eq!(e.shorten(10, DEFAULT_EXPIRY_MS), Err(ExpiryError::NotShorter));
        assert_eq!(e.shorten(2 * HOUR_MS, HOUR_MS), Err(ExpiryError::AlreadyPast));
        assert_eq!(e.shorten(10, 2 * HOUR_MS), Ok(2 * HOUR_MS));
        assert_eq!(e.version, 1);
    }

    #[test]
    fn renewal_is_explicit_bounded_by_the_plan_and_fences_old_cleanup_jobs() {
        let plan = Entitlement::free();
        let mut e = Expiry::new(DEFAULT_EXPIRY_MS);
        assert_eq!(e.renew(0, HOUR_MS, &plan), Err(ExpiryError::NotPublished));
        e.published(0);
        let queued_at = e.version;
        assert!(!e.cleanup_allowed(queued_at, DEFAULT_EXPIRY_MS - 1));
        assert!(e.cleanup_allowed(queued_at, DEFAULT_EXPIRY_MS));
        assert_eq!(e.renew(DEFAULT_EXPIRY_MS - 5, 48 * HOUR_MS, &plan), Err(ExpiryError::TooLong { allowed_ms: DEFAULT_EXPIRY_MS }));
        let end = e.renew(DEFAULT_EXPIRY_MS - 5, HOUR_MS, &plan).unwrap();
        assert_eq!(end, DEFAULT_EXPIRY_MS - 5 + HOUR_MS);
        assert!(!e.cleanup_allowed(queued_at, DEFAULT_EXPIRY_MS + 10), "a cleanup queued before the renewal may not delete the renewed workspace");
        let mut paid = plan.clone();
        paid.max_expiry_ms = 30 * 24 * HOUR_MS;
        assert!(e.renew(0, 30 * 24 * HOUR_MS, &paid).is_ok(), "a longer plan allows a longer renewal");
    }

    #[test]
    fn retained_storage_needs_the_entitlement_and_has_no_deadline() {
        let mut e = Expiry::new(DEFAULT_EXPIRY_MS);
        e.published(0);
        assert_eq!(e.retain(&Entitlement::free()), Err(ExpiryError::NotRetainable));
        let plan = Entitlement { retained: true, ..Entitlement::free() };
        e.retain(&plan).unwrap();
        assert_eq!(e.expires_at, None);
        assert!(!e.is_expired(u64::MAX));
    }

    #[test]
    fn a_reservation_counts_what_is_in_flight_so_two_uploads_cannot_together_exceed_the_budget() {
        let plan = Entitlement::free();
        let empty = Usage::default();
        let first = reserve(&empty, GB, 0, &plan, 600_000_000).unwrap();
        assert_eq!(reserve(&first, GB, 600_000_000, &plan, 600_000_000), Err(OverLimit::Workspace { needed: 600_000_000, available: 400_000_000 }));
        let published = first.publish(600_000_000, 0);
        assert_eq!(published, Usage { referenced_bytes: 600_000_000, reserved_bytes: 0 });
        assert_eq!(reserve(&published, GB, 600_000_000, &plan, 400_000_000).map(|u| u.total()), Ok(GB));
        // A new generation replaces an older one: its bytes are released once the old manifest is no longer referenced.
        assert_eq!(published.publish(0, 200_000_000).referenced_bytes, 400_000_000);
    }

    #[test]
    fn the_account_total_binds_however_many_workspaces_there_are() {
        let plan = Entitlement::free();
        assert_eq!(reserve(&Usage::default(), GB, 3 * GB - 10, &plan, 100), Err(OverLimit::Account { needed: 100, available: 10 }));
        assert_eq!(reserve(&Usage::default(), 10 * GB, 0, &plan, 2 * GB), Err(OverLimit::Workspace { needed: 2 * GB, available: GB }), "an allocation above the plan is capped to it");
    }

    #[test]
    fn an_abandoned_upload_returns_its_reservation() {
        let plan = Entitlement::free();
        let held = reserve(&Usage::default(), GB, 0, &plan, 500).unwrap();
        assert_eq!(held.release(500), Usage::default());
        assert_eq!(held.release(10_000), Usage::default(), "never below zero");
    }

    #[test]
    fn limits_follow_the_allocation() {
        let l = Limits::for_allocation(10 * GB);
        assert_eq!(l.max_expanded_bytes, 10 * GB);
        assert_eq!(l.max_history_bytes, 5 * GB);
        assert_eq!(Limits::default().max_expanded_bytes, GB);
    }
}
