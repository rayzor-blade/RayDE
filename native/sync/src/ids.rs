//! Identities: a workspace is named by a random 256-bit id that outlives sandboxes and logins; an account is named by the account directory.
use serde::{Deserialize, Serialize};
use std::fmt;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// A workspace id: 32 random bytes as 43 base64url characters, the form the gateway's routes already accept (`/{id}`).
/// It is not derived from the owner, the repository or the path, so it reveals nothing and cannot be guessed.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct WorkspaceId(String);

impl WorkspaceId {
    pub const LENGTH: usize = 43;

    /// From 32 bytes of randomness the caller took from the operating system.
    pub fn from_random(bytes: &[u8; 32]) -> Self {
        let mut out = String::with_capacity(Self::LENGTH);
        for chunk in bytes.chunks(3) {
            let n = chunk.iter().enumerate().fold(0u32, |acc, (i, b)| acc | (*b as u32) << (16 - 8 * i));
            let symbols = chunk.len() + 1;
            for i in 0..symbols {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            }
        }
        WorkspaceId(out)
    }

    pub fn parse(value: &str) -> Result<Self, IdError> {
        // 43 characters of base64url carry 258 bits for 256 of data, so the last symbol's low two bits must be zero.
        let valid = value.len() == Self::LENGTH && value.bytes().all(|b| ALPHABET.contains(&b));
        let canonical = valid && ALPHABET.iter().position(|a| *a == value.as_bytes()[42]).is_some_and(|v| v & 3 == 0);
        if canonical { Ok(WorkspaceId(value.to_string())) } else { Err(IdError::Workspace) }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for WorkspaceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "WorkspaceId({})", self.0)
    }
}

impl fmt::Display for WorkspaceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl TryFrom<String> for WorkspaceId {
    type Error = IdError;
    fn try_from(value: String) -> Result<Self, IdError> {
        WorkspaceId::parse(&value)
    }
}

impl From<WorkspaceId> for String {
    fn from(id: WorkspaceId) -> String {
        id.0
    }
}

/// A RayDE account, named by the account directory: not an OAuth session, an email address or a GitHub login, which can all change or be shared.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct AccountId(String);

impl AccountId {
    pub fn parse(value: &str) -> Result<Self, IdError> {
        let valid = !value.is_empty() && value.len() <= 64 && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b':');
        if valid { Ok(AccountId(value.to_string())) } else { Err(IdError::Account) }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for AccountId {
    type Error = IdError;
    fn try_from(value: String) -> Result<Self, IdError> {
        AccountId::parse(&value)
    }
}

impl From<AccountId> for String {
    fn from(id: AccountId) -> String {
        id.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdError {
    Workspace,
    Account,
}

impl fmt::Display for IdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            IdError::Workspace => "a workspace id is 43 base64url characters",
            IdError::Account => "an account id is 1 to 64 letters, digits, `_`, `-` or `:`",
        })
    }
}

impl std::error::Error for IdError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_random_id_is_43_characters_and_parses_back() {
        for seed in [0u8, 1, 127, 255] {
            let id = WorkspaceId::from_random(&[seed; 32]);
            assert_eq!(id.as_str().len(), 43);
            assert_eq!(WorkspaceId::parse(id.as_str()).unwrap(), id);
        }
        assert_eq!(WorkspaceId::from_random(&[0; 32]).as_str(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        assert_eq!(WorkspaceId::from_random(&[255; 32]).as_str(), "__________________________________________8");
    }

    #[test]
    fn ids_that_are_not_canonical_are_refused() {
        assert!(WorkspaceId::parse("short").is_err());
        assert!(WorkspaceId::parse(&"A".repeat(44)).is_err());
        assert!(WorkspaceId::parse(&format!("{}!", "A".repeat(42))).is_err());
        // Two ids that differ only in the unused bits of the last symbol would name one workspace twice.
        assert!(WorkspaceId::parse(&format!("{}B", "A".repeat(42))).is_err());
        assert!(AccountId::parse("").is_err());
        assert!(AccountId::parse("a/b").is_err());
        assert!(AccountId::parse("github:42").is_ok());
    }

    #[test]
    fn ids_travel_as_plain_strings_and_are_checked_on_the_way_in() {
        let id = WorkspaceId::from_random(&[7; 32]);
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(json, format!("\"{}\"", id.as_str()));
        assert_eq!(serde_json::from_str::<WorkspaceId>(&json).unwrap(), id);
        assert!(serde_json::from_str::<WorkspaceId>("\"nope\"").is_err());
    }
}
