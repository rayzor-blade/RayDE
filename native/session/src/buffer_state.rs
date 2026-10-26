use crate::{
    checkpoint,
    error::{Result, SessionError},
};
use serde::{Deserialize, Serialize};

const MAGIC: &[u8] = b"\xffrayde-buffer\0";
const MAX_HEADER: usize = 512;

#[derive(Serialize, Deserialize)]
pub(crate) struct Baseline {
    version: u32,
    pub disk: String,
    saving: Option<String>,
    graph: String,
}
pub(crate) fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn invalid() -> SessionError {
    SessionError::new(
        "bad-buffer-state",
        "The recovered buffer state is invalid or incomplete.",
    )
}
impl Baseline {
    pub fn accepts(&self, disk: &str) -> bool {
        self.disk == disk || self.saving.as_deref() == Some(disk)
    }
}

/// The graph and both sides of an in-progress Save share one atomic private record.
pub(crate) fn pack(state: &[u8], disk: &str, saving: Option<&str>) -> Result<Vec<u8>> {
    if state.len() > checkpoint::MAX_BYTES {
        return Err(SessionError::new(
            "too-large",
            "The recovered buffer exceeds the state size limit.",
        ));
    }
    if !digest(disk) || saving.is_some_and(|value| !digest(value)) {
        return Err(invalid());
    }
    let header = serde_json::to_vec(&Baseline {
        version: 1,
        disk: disk.into(),
        saving: saving.map(String::from),
        graph: checkpoint::digest(state),
    })
    .map_err(|_| invalid())?;
    let mut bytes = Vec::with_capacity(MAGIC.len() + 4 + header.len() + state.len());
    bytes.extend(MAGIC);
    bytes.extend((header.len() as u32).to_le_bytes());
    bytes.extend(header);
    bytes.extend(state);
    Ok(bytes)
}

pub(crate) fn unpack(bytes: &[u8]) -> Result<Option<(Baseline, &[u8])>> {
    if !bytes.starts_with(MAGIC) {
        return Ok(None);
    }
    let end = MAGIC.len() + 4;
    let size = u32::from_le_bytes(
        bytes
            .get(MAGIC.len()..end)
            .ok_or_else(invalid)?
            .try_into()
            .map_err(|_| invalid())?,
    ) as usize;
    if size > MAX_HEADER {
        return Err(invalid());
    }
    let header: Baseline = serde_json::from_slice(bytes.get(end..end + size).ok_or_else(invalid)?)
        .map_err(|_| invalid())?;
    let state = &bytes[end + size..];
    if header.version != 1
        || !digest(&header.disk)
        || header.saving.as_deref().is_some_and(|value| !digest(value))
        || state.len() > checkpoint::MAX_BYTES
        || checkpoint::digest(state) != header.graph
    {
        return Err(invalid());
    }
    let text = checkpoint::text(state).map_err(|_| invalid())?;
    if header
        .saving
        .as_deref()
        .is_some_and(|value| value != checkpoint::digest(text.as_bytes()))
    {
        return Err(invalid());
    }
    Ok(Some((header, state)))
}
