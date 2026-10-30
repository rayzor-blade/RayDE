//! Who may do what to a synced workspace, and what revocation invalidates. Pure rules: the gateway and the session both call `authorize`
//! on every document, file, Git, process, extension, asset and export operation, so a hidden button or a client's read-only flag is never the check.
use crate::ids::{AccountId, WorkspaceId};
use serde::{Deserialize, Serialize};

/// What a participant is. The order is the order of authority.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Viewer,
    Editor,
    Owner,
}

/// Something a participant asks to do.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Operation {
    /// Source, history and previews.
    Read,
    /// Files, documents, directories and assets.
    Edit,
    /// Commit, checkout, reset and the rest of Git that changes state.
    GitMutate,
    /// Bulk download of the workspace.
    Export,
    /// Build, Run and preview execution: code written by one person run by another.
    Run,
    Terminal,
    /// Installing an extension or running one.
    Extensions,
    /// Members, link policy and invitations.
    Share,
    SetExpiry,
    SetAllocation,
    Delete,
    TransferOwnership,
}

impl Operation {
    /// The least role that may ever do this. Run, Terminal and Extensions also need a grant unless the participant is the owner.
    pub fn minimum(self) -> Role {
        match self {
            Operation::Read => Role::Viewer,
            Operation::Edit | Operation::GitMutate | Operation::Export | Operation::Run | Operation::Terminal | Operation::Extensions => Role::Editor,
            Operation::Share | Operation::SetExpiry | Operation::SetAllocation | Operation::Delete | Operation::TransferOwnership => Role::Owner,
        }
    }

    fn needs_grant(self) -> bool {
        matches!(self, Operation::Run | Operation::Terminal | Operation::Extensions)
    }
}

/// Execution is owner-only until the owner grants it, one kind at a time. A viewer can never hold one.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub struct Grants {
    pub run: bool,
    pub terminal: bool,
    pub extensions: bool,
}

impl Grants {
    fn allows(&self, op: Operation) -> bool {
        match op {
            Operation::Run => self.run,
            Operation::Terminal => self.terminal,
            Operation::Extensions => self.extensions,
            _ => false,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Member {
    pub account: AccountId,
    /// Viewer or Editor: there is one owner, kept apart from the members.
    pub role: Role,
    #[serde(default)]
    pub grants: Grants,
}

/// "Anyone with the link": still a signed-in RayDE account, and a link never carries execution grants.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct LinkPolicy {
    pub enabled: bool,
    pub role: Role,
    /// Changing it voids every link already handed out.
    pub rotation: u32,
}

/// The access control list. Every change that could reduce someone's access advances `acl_version`, which closes or downgrades
/// sockets, voids leases issued under the old version, and refuses a reconnect from a client that has not seen the new one.
#[derive(Clone, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub struct Sharing {
    pub members: Vec<Member>,
    pub link: Option<LinkPolicy>,
    pub acl_version: u64,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum SharingError {
    /// The owner is not a member of their own workspace.
    OwnerIsNotAMember,
    /// A member or a link is a Viewer or an Editor.
    NotAShareableRole,
}

impl Sharing {
    /// The default: restricted to the owner.
    pub fn restricted() -> Self {
        Sharing::default()
    }

    fn bump(&mut self) {
        self.acl_version += 1;
    }

    pub fn add_member(&mut self, owner: &AccountId, account: AccountId, role: Role) -> Result<(), SharingError> {
        if &account == owner {
            return Err(SharingError::OwnerIsNotAMember);
        }
        if role == Role::Owner {
            return Err(SharingError::NotAShareableRole);
        }
        match self.members.iter_mut().find(|m| m.account == account) {
            Some(m) if m.role == role => return Ok(()),
            Some(m) => {
                // Lowering a role must revoke what the old role allowed; raising one keeps grants.
                if role < m.role {
                    m.grants = Grants::default();
                }
                m.role = role;
            }
            None => self.members.push(Member { account, role, grants: Grants::default() }),
        }
        self.bump();
        Ok(())
    }

    pub fn remove_member(&mut self, account: &AccountId) -> bool {
        let before = self.members.len();
        self.members.retain(|m| &m.account != account);
        let removed = self.members.len() != before;
        if removed {
            self.bump();
        }
        removed
    }

    /// Sets what a member may run. A viewer holds none.
    pub fn set_grants(&mut self, account: &AccountId, grants: Grants) -> bool {
        let Some(m) = self.members.iter_mut().find(|m| &m.account == account) else { return false };
        let grants = if m.role == Role::Viewer { Grants::default() } else { grants };
        if m.grants == grants {
            return true;
        }
        let reduced = (m.grants.run && !grants.run) || (m.grants.terminal && !grants.terminal) || (m.grants.extensions && !grants.extensions);
        m.grants = grants;
        if reduced {
            self.bump();
        }
        true
    }

    pub fn set_link(&mut self, role: Role) -> Result<(), SharingError> {
        if role == Role::Owner {
            return Err(SharingError::NotAShareableRole);
        }
        let rotation = self.link.map_or(0, |l| l.rotation);
        let next = LinkPolicy { enabled: true, role, rotation };
        if self.link != Some(next) {
            self.link = Some(next);
            self.bump();
        }
        Ok(())
    }

    pub fn disable_link(&mut self) {
        if let Some(l) = self.link.as_mut().filter(|l| l.enabled) {
            l.enabled = false;
            self.bump();
        }
    }

    /// New links, and none of the old ones.
    pub fn rotate_link(&mut self) {
        if let Some(l) = self.link.as_mut() {
            l.rotation += 1;
            self.bump();
        }
    }
}

/// Who is asking: an authenticated account, and the rotation of the link they arrived by, if they did.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Principal {
    pub account: AccountId,
    pub link_rotation: Option<u32>,
}

/// What the policy needs to know about a workspace, from its Durable Object.
#[derive(Clone, Debug)]
pub struct Access<'a> {
    pub owner: &'a AccountId,
    pub sharing: &'a Sharing,
    /// Server time in milliseconds when cloud access ends, once the first sync has published.
    pub expires_at: Option<u64>,
    pub deleting: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Via {
    Owner,
    Member,
    Link,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Authorized {
    pub role: Role,
    pub via: Via,
    /// The ACL version this decision was made under; a lease records it.
    pub acl_version: u64,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Denied {
    /// Cloud access has ended; this is checked on every call, not left to a background job.
    Expired,
    Deleting,
    /// Anonymous viewing is not offered.
    SignInRequired,
    /// Signed in, but not shared with.
    NoAccess,
    /// Has access, but not enough for this: the role needed.
    NeedsRole(Role),
    /// Has the role, but the owner has not granted this kind of execution.
    NeedsGrant(Operation),
}

/// The decision for one operation. Expiry and deletion come first, then identity, then role, then grants.
pub fn authorize(access: &Access, principal: Option<&Principal>, op: Operation, now: u64) -> Result<Authorized, Denied> {
    if access.deleting {
        return Err(Denied::Deleting);
    }
    if access.expires_at.is_some_and(|end| now >= end) {
        return Err(Denied::Expired);
    }
    let principal = principal.ok_or(Denied::SignInRequired)?;
    let acl_version = access.sharing.acl_version;
    let (role, via, grants) = if &principal.account == access.owner {
        (Role::Owner, Via::Owner, Grants { run: true, terminal: true, extensions: true })
    } else {
        let member = access.sharing.members.iter().find(|m| m.account == principal.account);
        let link = access
            .sharing
            .link
            .filter(|l| l.enabled && principal.link_rotation == Some(l.rotation))
            .map(|l| l.role);
        match (member, link) {
            (None, None) => return Err(Denied::NoAccess),
            (Some(m), l) if l.is_none_or(|l| l <= m.role) => (m.role, Via::Member, m.grants),
            (m, Some(l)) => (l, Via::Link, m.map_or(Grants::default(), |m| m.grants)),
            (Some(m), None) => (m.role, Via::Member, m.grants),
        }
    };
    if role < op.minimum() {
        return Err(Denied::NeedsRole(op.minimum()));
    }
    if op.needs_grant() && via != Via::Owner && !grants.allows(op) {
        return Err(Denied::NeedsGrant(op));
    }
    Ok(Authorized { role, via, acl_version })
}

/// An invitation: scoped to one workspace and one role, expiring, revocable, and bound to an account when it names one.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Invitation {
    pub id: String,
    pub workspace: WorkspaceId,
    pub role: Role,
    pub for_account: Option<AccountId>,
    pub expires_at: u64,
    pub revoked: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InviteDenied {
    Expired,
    Revoked,
    /// Named for another account.
    WrongAccount,
    NotAShareableRole,
}

impl Invitation {
    /// The role it grants `claimant` at `now`, after they signed in.
    pub fn claim(&self, claimant: &AccountId, now: u64) -> Result<Role, InviteDenied> {
        if self.role == Role::Owner {
            return Err(InviteDenied::NotAShareableRole);
        }
        if self.revoked {
            return Err(InviteDenied::Revoked);
        }
        if now >= self.expires_at {
            return Err(InviteDenied::Expired);
        }
        if self.for_account.as_ref().is_some_and(|a| a != claimant) {
            return Err(InviteDenied::WrongAccount);
        }
        Ok(self.role)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LeaseKind {
    /// Permission to upload a generation.
    Publish,
    /// Permission for a compute sandbox to run for the workspace.
    Execution,
}

/// A time-limited, fenced permission, bound to the ACL version and the generation it was issued under.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct Lease {
    pub id: String,
    pub kind: LeaseKind,
    pub workspace: WorkspaceId,
    pub holder: AccountId,
    pub acl_version: u64,
    /// The generation the holder saw: a publish succeeds only if it is still current (compare and swap).
    pub base_generation: u64,
    pub expires_at: u64,
}

impl Lease {
    /// Whether the lease still holds. Revocation or a renewal elsewhere voids it; so does the clock.
    pub fn holds(&self, acl_version: u64, current_generation: u64, now: u64) -> bool {
        now < self.expires_at && self.acl_version == acl_version && (self.kind == LeaseKind::Execution || self.base_generation == current_generation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account(name: &str) -> AccountId {
        AccountId::parse(name).unwrap()
    }

    fn person(name: &str) -> Principal {
        Principal { account: account(name), link_rotation: None }
    }

    struct World {
        owner: AccountId,
        sharing: Sharing,
        expires_at: Option<u64>,
        deleting: bool,
    }

    impl World {
        fn new() -> Self {
            World { owner: account("owner"), sharing: Sharing::restricted(), expires_at: None, deleting: false }
        }

        fn ask(&self, who: Option<&Principal>, op: Operation, now: u64) -> Result<Authorized, Denied> {
            authorize(&Access { owner: &self.owner, sharing: &self.sharing, expires_at: self.expires_at, deleting: self.deleting }, who, op, now)
        }
    }

    const ALL: [Operation; 12] = [
        Operation::Read,
        Operation::Edit,
        Operation::GitMutate,
        Operation::Export,
        Operation::Run,
        Operation::Terminal,
        Operation::Extensions,
        Operation::Share,
        Operation::SetExpiry,
        Operation::SetAllocation,
        Operation::Delete,
        Operation::TransferOwnership,
    ];

    #[test]
    fn a_restricted_workspace_is_the_owners_alone() {
        let w = World::new();
        for op in ALL {
            assert!(w.ask(Some(&person("owner")), op, 0).is_ok(), "{op:?}");
            assert_eq!(w.ask(Some(&person("stranger")), op, 0), Err(Denied::NoAccess), "{op:?}");
            assert_eq!(w.ask(None, op, 0), Err(Denied::SignInRequired), "{op:?}");
        }
    }

    #[test]
    fn a_viewer_reads_and_nothing_else_even_with_grants() {
        let mut w = World::new();
        w.sharing.add_member(&w.owner.clone(), account("v"), Role::Viewer).unwrap();
        w.sharing.set_grants(&account("v"), Grants { run: true, terminal: true, extensions: true });
        for op in ALL {
            let got = w.ask(Some(&person("v")), op, 0);
            if op == Operation::Read {
                assert_eq!(got.unwrap().role, Role::Viewer);
            } else {
                assert!(matches!(got, Err(Denied::NeedsRole(_))), "{op:?}: {got:?}");
            }
        }
    }

    #[test]
    fn an_editor_changes_files_and_git_but_runs_nothing_until_granted() {
        let mut w = World::new();
        w.sharing.add_member(&w.owner.clone(), account("e"), Role::Editor).unwrap();
        for op in [Operation::Read, Operation::Edit, Operation::GitMutate, Operation::Export] {
            assert!(w.ask(Some(&person("e")), op, 0).is_ok(), "{op:?}");
        }
        for op in [Operation::Run, Operation::Terminal, Operation::Extensions] {
            assert_eq!(w.ask(Some(&person("e")), op, 0), Err(Denied::NeedsGrant(op)), "{op:?}");
        }
        for op in [Operation::Share, Operation::SetExpiry, Operation::SetAllocation, Operation::Delete, Operation::TransferOwnership] {
            assert_eq!(w.ask(Some(&person("e")), op, 0), Err(Denied::NeedsRole(Role::Owner)), "{op:?}");
        }
        w.sharing.set_grants(&account("e"), Grants { run: true, terminal: false, extensions: false });
        assert!(w.ask(Some(&person("e")), Operation::Run, 0).is_ok());
        assert_eq!(w.ask(Some(&person("e")), Operation::Terminal, 0), Err(Denied::NeedsGrant(Operation::Terminal)));
    }

    #[test]
    fn a_link_needs_the_current_rotation_a_signed_in_account_and_never_carries_grants() {
        let mut w = World::new();
        w.sharing.set_link(Role::Editor).unwrap();
        let by_link = |rotation| Principal { account: account("guest"), link_rotation: Some(rotation) };
        assert_eq!(w.ask(Some(&person("guest")), Operation::Read, 0), Err(Denied::NoAccess), "the URL alone grants nothing");
        assert_eq!(w.ask(Some(&by_link(0)), Operation::Edit, 0).unwrap().via, Via::Link);
        assert_eq!(w.ask(Some(&by_link(0)), Operation::Run, 0), Err(Denied::NeedsGrant(Operation::Run)));
        assert_eq!(w.ask(None, Operation::Read, 0), Err(Denied::SignInRequired));
        w.sharing.rotate_link();
        assert_eq!(w.ask(Some(&by_link(0)), Operation::Read, 0), Err(Denied::NoAccess), "an old link stops working");
        assert!(w.ask(Some(&by_link(1)), Operation::Read, 0).is_ok());
        w.sharing.disable_link();
        assert_eq!(w.ask(Some(&by_link(1)), Operation::Read, 0), Err(Denied::NoAccess));
    }

    #[test]
    fn the_higher_of_a_membership_and_a_link_applies() {
        let mut w = World::new();
        w.sharing.add_member(&w.owner.clone(), account("g"), Role::Editor).unwrap();
        w.sharing.set_link(Role::Viewer).unwrap();
        let by_link = Principal { account: account("g"), link_rotation: Some(0) };
        assert_eq!(w.ask(Some(&by_link), Operation::Edit, 0).unwrap().role, Role::Editor);
    }

    #[test]
    fn expiry_and_deletion_win_over_everything_and_are_checked_on_each_call() {
        let mut w = World::new();
        w.expires_at = Some(1_000);
        assert!(w.ask(Some(&person("owner")), Operation::Read, 999).is_ok());
        for op in ALL {
            assert_eq!(w.ask(Some(&person("owner")), op, 1_000), Err(Denied::Expired), "{op:?}");
        }
        w.expires_at = None;
        w.deleting = true;
        assert_eq!(w.ask(Some(&person("owner")), Operation::Read, 0), Err(Denied::Deleting));
    }

    #[test]
    fn changes_that_reduce_access_advance_the_acl_version_and_ones_that_do_not_leave_it() {
        let mut s = Sharing::restricted();
        let owner = account("owner");
        assert_eq!(s.acl_version, 0);
        s.add_member(&owner, account("e"), Role::Editor).unwrap();
        let v = s.acl_version;
        s.add_member(&owner, account("e"), Role::Editor).unwrap();
        assert_eq!(s.acl_version, v, "adding the same member again changes nothing");
        s.set_grants(&account("e"), Grants { run: true, ..Grants::default() });
        assert_eq!(s.acl_version, v, "granting more is not a reduction");
        s.set_grants(&account("e"), Grants::default());
        assert_eq!(s.acl_version, v + 1, "taking a grant away is");
        s.set_grants(&account("e"), Grants { run: true, ..Grants::default() });
        s.add_member(&owner, account("e"), Role::Viewer).unwrap();
        assert_eq!(s.members[0].grants, Grants::default(), "lowering a role drops its grants");
        let before = s.acl_version;
        assert!(s.remove_member(&account("e")));
        assert_eq!(s.acl_version, before + 1);
        assert!(!s.remove_member(&account("e")));
        assert_eq!(s.add_member(&owner, owner.clone(), Role::Editor), Err(SharingError::OwnerIsNotAMember));
        assert_eq!(s.add_member(&owner, account("x"), Role::Owner), Err(SharingError::NotAShareableRole));
        assert_eq!(s.set_link(Role::Owner), Err(SharingError::NotAShareableRole));
    }

    #[test]
    fn revocation_voids_the_leases_issued_before_it() {
        let ws = WorkspaceId::from_random(&[9; 32]);
        let mut s = Sharing::restricted();
        let owner = account("owner");
        s.add_member(&owner, account("e"), Role::Editor).unwrap();
        let publish = Lease { id: "l1".into(), kind: LeaseKind::Publish, workspace: ws.clone(), holder: account("e"), acl_version: s.acl_version, base_generation: 4, expires_at: 100 };
        let run = Lease { kind: LeaseKind::Execution, id: "l2".into(), ..publish.clone() };
        assert!(publish.holds(s.acl_version, 4, 50) && run.holds(s.acl_version, 9, 50));
        assert!(!publish.holds(s.acl_version, 5, 50), "another publish moved the generation");
        assert!(run.holds(s.acl_version, 5, 50), "an execution lease is not tied to a generation");
        assert!(!publish.holds(s.acl_version, 4, 100), "the clock ends it");
        s.remove_member(&account("e"));
        assert!(!publish.holds(s.acl_version, 4, 50) && !run.holds(s.acl_version, 4, 50), "revocation voids both");
    }

    #[test]
    fn an_invitation_is_scoped_expiring_revocable_and_bound_to_the_account_it_names() {
        let ws = WorkspaceId::from_random(&[3; 32]);
        let mut invitation = Invitation { id: "i".into(), workspace: ws, role: Role::Editor, for_account: Some(account("friend")), expires_at: 500, revoked: false };
        assert_eq!(invitation.claim(&account("friend"), 499), Ok(Role::Editor));
        assert_eq!(invitation.claim(&account("other"), 499), Err(InviteDenied::WrongAccount));
        assert_eq!(invitation.claim(&account("friend"), 500), Err(InviteDenied::Expired));
        invitation.for_account = None;
        assert_eq!(invitation.claim(&account("anyone"), 0), Ok(Role::Editor), "an open invitation is claimed by whoever signs in");
        invitation.revoked = true;
        assert_eq!(invitation.claim(&account("anyone"), 0), Err(InviteDenied::Revoked));
        invitation.revoked = false;
        invitation.role = Role::Owner;
        assert_eq!(invitation.claim(&account("anyone"), 0), Err(InviteDenied::NotAShareableRole));
    }
}
