//! Shared text lineage and validated Yrs exchange, independent of transport and storage.
use crate::{chunk::sha256_hex, ids::WorkspaceId, lifecycle::Limits, manifest::path_problem};
use serde::{Deserialize, Serialize};
use yrs::{
    ClientID, Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, Transact, Update,
    updates::{decoder::Decode, encoder::Encode},
};

pub const MAX_TEXT: usize = 1024 * 1024;
pub const MAX_STATE: usize = 4 * 1024 * 1024;
pub const MAX_VECTOR: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Lineage,
    Missing,
    Limit,
}
impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Invalid => "bad-document",
            Self::Lineage => "document-lineage",
            Self::Missing => "document-history",
            Self::Limit => "document-limit",
        }
    }
}
type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Seed {
    pub version: u32,
    pub workspace: String,
    pub path: String,
    pub generation: u64,
    pub sha256: String,
    pub units: u32,
    pub lineage: String,
}
impl Seed {
    fn id(&self) -> String {
        sha256_hex(
            &serde_json::to_vec(&(
                self.version,
                &self.workspace,
                &self.path,
                self.generation,
                &self.sha256,
                self.units,
            ))
            .unwrap(),
        )
    }
    pub fn validate(&self) -> Result<()> {
        if self.version != 1
            || WorkspaceId::parse(&self.workspace).is_err()
            || self.path.is_empty()
            || path_problem(&self.path, &Limits::default()).is_some()
            || self.generation == 0
            || self.units as usize > MAX_TEXT
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || self.lineage != self.id()
        {
            return Err(Error::Lineage);
        }
        Ok(())
    }
}
fn blank() -> Doc {
    Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::with_client_id(ClientID::new(0))
    })
}
fn state(doc: &Doc) -> Vec<u8> {
    doc.transact()
        .encode_state_as_update_v1(&StateVector::default())
}
fn vector(bytes: &[u8]) -> Result<StateVector> {
    if bytes.len() > MAX_VECTOR {
        return Err(Error::Limit);
    }
    // Reject impossible counts before the decoder reserves its client table.
    let mut count = 0u32;
    for (position, byte) in bytes.iter().take(5).enumerate() {
        if position == 4 && byte & 0xf0 != 0 {
            return Err(Error::Invalid);
        }
        count |= ((byte & 0x7f) as u32) << (position * 7);
        if byte & 0x80 == 0 {
            if count as usize > (bytes.len() - position - 1) / 2 {
                return Err(Error::Invalid);
            }
            return StateVector::decode_v1(bytes).map_err(|_| Error::Invalid);
        }
    }
    Err(Error::Invalid)
}
pub fn same_vector(left: &[u8], right: &[u8]) -> Result<bool> {
    Ok(vector(left)? == vector(right)?)
}
fn seeded(seed: &Seed, from: &StateVector) -> bool {
    from.get(&ClientID::new(0)) == seed.units
}

/// A graph is materialized only while handling an exchange; idle storage retains encoded updates.
pub struct Document {
    pub seed: Seed,
    doc: Doc,
}
pub struct Exchange {
    pub changed: bool,
    pub update: Vec<u8>,
    pub vector: Vec<u8>,
    pub state: Vec<u8>,
    pub text_sha256: String,
}
impl Document {
    pub fn new(workspace: &str, path: &str, generation: u64, text: &str) -> Result<Self> {
        if text.len() > MAX_TEXT {
            return Err(Error::Limit);
        }
        let mut seed = Seed {
            version: 1,
            workspace: workspace.into(),
            path: path.into(),
            generation,
            sha256: sha256_hex(text.as_bytes()),
            units: text.encode_utf16().count() as u32,
            lineage: String::new(),
        };
        seed.lineage = seed.id();
        seed.validate()?;
        let doc = blank();
        let value = doc.get_or_insert_text("text");
        value.insert(&mut doc.transact_mut(), 0, text);
        Ok(Self { seed, doc })
    }
    pub fn restore(seed: Seed, updates: &[Vec<u8>]) -> Result<Self> {
        seed.validate()?;
        if updates.is_empty()
            || updates.len() > 65
            || updates
                .iter()
                .try_fold(0usize, |sum, b| sum.checked_add(b.len()))
                .is_none_or(|n| n > MAX_STATE)
        {
            return Err(Error::Limit);
        }
        let doc = blank();
        for bytes in updates {
            doc.transact_mut()
                .apply_update(Update::decode_v1(bytes).map_err(|_| Error::Invalid)?)
                .map_err(|_| Error::Invalid)?;
        }
        let value = doc.get_or_insert_text("text");
        {
            let txn = doc.transact();
            if txn.has_missing_updates() || !seeded(&seed, &txn.state_vector()) {
                return Err(Error::Missing);
            }
            if value.get_string(&txn).len() > MAX_TEXT {
                return Err(Error::Limit);
            }
        }
        Ok(Self { seed, doc })
    }
    pub fn state(&self) -> Vec<u8> {
        state(&self.doc)
    }
    pub fn vector(&self) -> Vec<u8> {
        self.doc.transact().state_vector().encode_v1()
    }
    pub fn text(&self) -> String {
        self.doc
            .get_or_insert_text("text")
            .get_string(&self.doc.transact())
    }
    pub fn exchange(&self, lineage: &str, from: &[u8], update: &[u8]) -> Result<Exchange> {
        if lineage != self.seed.lineage {
            return Err(Error::Lineage);
        }
        if update.len() > MAX_STATE {
            return Err(Error::Limit);
        }
        let from = vector(from)?;
        if !seeded(&self.seed, &from)
            || !matches!(
                self.doc.transact().state_vector().partial_cmp(&from),
                Some(std::cmp::Ordering::Greater | std::cmp::Ordering::Equal)
            )
        {
            return Err(Error::Missing);
        }
        let doc = Self::restore(self.seed.clone(), &[self.state()])?.doc;
        let before = state(&doc);
        doc.transact_mut()
            .apply_update(Update::decode_v1(update).map_err(|_| Error::Invalid)?)
            .map_err(|_| Error::Invalid)?;
        let text = doc.get_or_insert_text("text");
        let txn = doc.transact();
        if txn.has_missing_updates() || !seeded(&self.seed, &txn.state_vector()) {
            return Err(Error::Missing);
        }
        let text = text.get_string(&txn);
        if text.len() > MAX_TEXT {
            return Err(Error::Limit);
        }
        let state = txn.encode_state_as_update_v1(&StateVector::default());
        if state.len() > MAX_STATE {
            return Err(Error::Limit);
        }
        Ok(Exchange {
            changed: before != state,
            update: txn.encode_state_as_update_v1(&from),
            vector: txn.state_vector().encode_v1(),
            state,
            text_sha256: sha256_hex(text.as_bytes()),
        })
    }
}

#[cfg(test)]
mod tests;
