use crate::{
    checkpoint,
    error::{Result, SessionError},
};
use serde::{Deserialize, Serialize};

const MAGIC: &[u8] = b"\xffrayde-buffer\0";
pub(crate) const MAX_HEADER: usize = 8192;
pub(crate) const PREFIX: usize = MAGIC.len() + 4;

#[derive(Serialize, Deserialize)]
pub(crate) struct Baseline {
    version: u32,
    pub disk: String,
    saving: Option<String>,
    graph: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    binding: Option<String>,
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
    fn checksum(&self) -> Result<String> {
        Ok(checkpoint::digest(
            &serde_json::to_vec(&(
                self.version,
                &self.disk,
                &self.saving,
                &self.graph,
                &self.path,
            ))
            .map_err(|_| invalid())?,
        ))
    }
    pub fn accepts(&self, disk: &str) -> bool {
        self.disk == disk || self.saving.as_deref() == Some(disk)
    }
    #[cfg(feature = "server")]
    pub fn saving(&self, hash: &str) -> bool {
        self.saving.as_deref() == Some(hash)
    }
}

/// The graph and both sides of an in-progress Save share one atomic private record.
pub(crate) fn pack(state: &[u8], disk: &str, saving: Option<&str>, path: &str) -> Result<Vec<u8>> {
    if state.len() > checkpoint::MAX_BYTES {
        return Err(SessionError::new(
            "too-large",
            "The recovered buffer exceeds the state size limit.",
        ));
    }
    if !digest(disk)
        || saving.is_some_and(|value| !digest(value))
        || path.is_empty()
        || path.len() > 4096
        || path.contains('\0')
    {
        return Err(invalid());
    }
    let mut header = Baseline {
        version: 2,
        disk: disk.into(),
        saving: saving.map(String::from),
        graph: checkpoint::digest(state),
        path: Some(path.into()),
        binding: None,
    };
    header.binding = Some(header.checksum()?);
    let header = serde_json::to_vec(&header).map_err(|_| invalid())?;
    if header.len() > MAX_HEADER {
        return Err(invalid());
    }
    let mut bytes = Vec::with_capacity(PREFIX + header.len() + state.len());
    bytes.extend(MAGIC);
    bytes.extend((header.len() as u32).to_le_bytes());
    bytes.extend(header);
    bytes.extend(state);
    Ok(bytes)
}

/// The bounded header can be inspected without reading unrelated document graphs.
#[cfg(feature = "server")]
pub(crate) fn buffered(bytes: &[u8]) -> bool {
    bytes.starts_with(MAGIC) || !bytes.is_empty() && MAGIC.starts_with(bytes)
}

pub(crate) fn header(bytes: &[u8]) -> Result<Option<(Baseline, usize)>> {
    if !bytes.starts_with(MAGIC) {
        if !bytes.is_empty() && MAGIC.starts_with(bytes) {
            return Err(invalid());
        }
        return Ok(None);
    }
    let end = PREFIX;
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
    let mut header: Baseline =
        serde_json::from_slice(bytes.get(end..end + size).ok_or_else(invalid)?)
            .map_err(|_| invalid())?;
    if !matches!(header.version, 1 | 2)
        || header.version == 2
            && header
                .path
                .as_deref()
                .is_none_or(|path| path.is_empty() || path.len() > 4096 || path.contains('\0'))
        || !digest(&header.disk)
        || !digest(&header.graph)
        || header.saving.as_deref().is_some_and(|value| !digest(value))
    {
        return Err(invalid());
    }
    if header.version == 2 && header.binding.as_deref() != Some(header.checksum()?.as_str()) {
        return Err(invalid());
    }
    if header.version == 1 {
        header.path = None;
    }
    Ok(Some((header, end + size)))
}

pub(crate) fn unpack(bytes: &[u8]) -> Result<Option<(Baseline, &[u8])>> {
    let Some((header, start)) = header(bytes)? else {
        return Ok(None);
    };
    let state = &bytes[start..];
    if state.len() > checkpoint::MAX_BYTES || checkpoint::digest(state) != header.graph {
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
