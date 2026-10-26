//! Complete, checksummed Yrs snapshots for durable Save and compute restoration.
use crate::error::{Result, SessionError};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use yrs::{
    ClientID, Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Transact, Update,
    updates::decoder::Decode,
};

pub const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_VECTOR: usize = 64 * 1024;

#[derive(Clone, Serialize, Deserialize)]
pub struct Checkpoint {
    pub version: u32,
    pub update: String,
    pub sha256: String,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Delta {
    pub version: u32,
    pub update: String,
    pub vector: String,
    pub sha256: String,
}

pub fn decode_vector(encoded: &str) -> Result<StateVector> {
    if encoded.len() > MAX_VECTOR.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let bytes = B64.decode(encoded).map_err(|_| invalid())?;
    StateVector::decode_v1(&bytes).map_err(|_| invalid())
}

pub fn pack_delta(bytes: &[u8], vector: &[u8]) -> Result<Delta> {
    if bytes.len() > MAX_BYTES || vector.len() > MAX_VECTOR {
        return Err(SessionError::new(
            "too-large",
            "The document exceeds the recovery size limit.",
        ));
    }
    Ok(Delta {
        version: 1,
        update: B64.encode(bytes),
        vector: B64.encode(vector),
        sha256: digest(bytes),
    })
}

pub fn unpack_delta(delta: &Delta) -> Result<Vec<u8>> {
    if delta.version != 1 || delta.update.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let bytes = B64.decode(&delta.update).map_err(|_| invalid())?;
    if bytes.len() > MAX_BYTES || digest(&bytes) != delta.sha256 {
        return Err(invalid());
    }
    decode_vector(&delta.vector)?;
    Update::decode_v1(&bytes).map_err(|_| invalid())?;
    Ok(bytes)
}

pub fn follows(current: &str, next: &str) -> Result<bool> {
    Ok(matches!(
        decode_vector(next)?.partial_cmp(&decode_vector(current)?),
        Some(std::cmp::Ordering::Equal | std::cmp::Ordering::Greater)
    ))
}

/// Rebuild a complete graph from a baseline and its ordered journal deltas.
pub fn materialize(updates: &[Vec<u8>], vector: &str) -> Result<Vec<u8>> {
    let expected = decode_vector(vector)?;
    let doc = Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::with_client_id(ClientID::new(0))
    });
    for bytes in updates {
        if bytes.len() > MAX_BYTES {
            return Err(invalid());
        }
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
    }
    let txn = doc.transact();
    if txn.has_missing_updates() || txn.state_vector() != expected {
        return Err(invalid());
    }
    let state = txn.encode_state_as_update_v1(&StateVector::default());
    if state.len() > MAX_BYTES {
        return Err(SessionError::new(
            "too-large",
            "The document exceeds the recovery size limit.",
        ));
    }
    Ok(state)
}

pub fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn invalid() -> SessionError {
    SessionError::new(
        "bad-checkpoint",
        "The document checkpoint is invalid or incomplete.",
    )
}

fn document(bytes: &[u8]) -> Result<Doc> {
    if bytes.len() > MAX_BYTES {
        return Err(SessionError::new(
            "too-large",
            "The document checkpoint exceeds the recovery size limit.",
        ));
    }
    let doc = Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::with_client_id(ClientID::new(0))
    });
    let update = Update::decode_v1(bytes).map_err(|_| invalid())?;
    doc.transact_mut()
        .apply_update(update)
        .map_err(|_| invalid())?;
    if doc.transact().has_missing_updates() {
        return Err(invalid());
    }
    Ok(doc)
}

pub fn pack(bytes: &[u8]) -> Result<Checkpoint> {
    document(bytes)?;
    Ok(Checkpoint {
        version: 1,
        update: B64.encode(bytes),
        sha256: digest(bytes),
    })
}

pub fn unpack(checkpoint: &Checkpoint) -> Result<Vec<u8>> {
    if checkpoint.version != 1 || checkpoint.update.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let bytes = B64.decode(&checkpoint.update).map_err(|_| invalid())?;
    if digest(&bytes) != checkpoint.sha256 {
        return Err(invalid());
    }
    document(&bytes)?;
    Ok(bytes)
}

pub fn text(bytes: &[u8]) -> Result<String> {
    let doc = document(bytes)?;
    let text = doc.get_or_insert_text("text");
    Ok(text.get_string(&doc.transact()))
}

/// Saved snapshots from one recovery generation join even when their replies arrive out of order.
pub fn merge(current: &[u8], next: &[u8]) -> Result<Vec<u8>> {
    let candidate = document(next)?;
    let candidate_vector = candidate.transact().state_vector();
    drop(candidate);
    let doc = document(current)?;
    // One compute authority emits complete snapshots on a single causal chain.
    if doc
        .transact()
        .state_vector()
        .partial_cmp(&candidate_vector)
        .is_none()
    {
        return Err(SessionError::new(
            "checkpoint-conflict",
            "The checkpoint belongs to a different document history.",
        ));
    }
    doc.transact_mut()
        .apply_update(Update::decode_v1(next).map_err(|_| invalid())?)
        .map_err(|_| invalid())?;
    let bytes = doc
        .transact()
        .encode_state_as_update_v1(&StateVector::default());
    document(&bytes)?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::Text;
    #[test]
    fn reordered_snapshots_preserve_deletions_and_reject_corruption_or_fragments() {
        let doc = Doc::with_client_id(1);
        let value = doc.get_or_insert_text("text");
        value.insert(&mut doc.transact_mut(), 0, "abc");
        let before = doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let vector = doc.transact().state_vector();
        value.remove_range(&mut doc.transact_mut(), 1, 1);
        let after = doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        assert_eq!(text(&merge(&after, &before).unwrap()).unwrap(), "ac");
        assert_eq!(text(&merge(&before, &after).unwrap()).unwrap(), "ac");
        assert!(pack(&doc.transact().encode_state_as_update_v1(&vector)).is_err());
        let mut saved = pack(&after).unwrap();
        assert_eq!(unpack(&saved).unwrap(), after);
        saved.sha256 = "wrong".into();
        assert!(unpack(&saved).is_err());
        assert!(pack(&[255]).is_err());
        assert!(pack(&vec![0; MAX_BYTES + 1]).is_err());
        let fork = Doc::with_client_id(2);
        fork.get_or_insert_text("text")
            .insert(&mut fork.transact_mut(), 0, "different history");
        assert_eq!(
            merge(
                &after,
                &fork
                    .transact()
                    .encode_state_as_update_v1(&StateVector::default())
            )
            .unwrap_err()
            .code,
            "checkpoint-conflict"
        );
    }
}
