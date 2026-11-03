//! Cloud Sync text histories. The workspace gate serializes journal commits with snapshot publication.
use super::*;
use crate::checkpoints::{CHUNK, put};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use rayde_sync::{
    live::{self, Document, Seed},
    manifest::{FileKind, Manifest},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_DOCUMENTS: usize = 256;
pub const MAX_BYTES: usize = 64 * 1024 * 1024;
const COMPACT: usize = 256 * 1024;
const INDEX: &str = "sync-documents:v1";
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Index {
    entries: BTreeMap<String, Usage>,
    bytes: usize,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Usage {
    bytes: usize,
    checksum: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Segment {
    first: usize,
    bytes: usize,
    sha256: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    seed: Seed,
    anchor: String,
    head: String,
    sequence: u64,
    vector: String,
    segments: Vec<Segment>,
    bytes: usize,
    allocated: usize,
}
pub struct Documents {
    storage: Storage,
}
#[derive(Clone,Serialize,Deserialize)]
pub(crate) struct Head{pub path:String,pub lineage:String,pub sequence:u64}
fn unavailable() -> Failure {
    bad(
        503,
        "The shared document history is invalid or incomplete. Its previous state has been kept.",
    )
}
fn conflict() -> Failure {
    bad(
        409,
        "Shared document history changed. Reopen the document before exchanging edits.",
    )
}
fn invalid(error: live::Error) -> Failure {
    match error {
        live::Error::Limit => bad(413, "The shared document exceeds its history limit."),
        live::Error::Lineage | live::Error::Missing => conflict(),
        _ => bad(422, "The shared document update is invalid."),
    }
}
fn key(id: &str) -> String {
    format!("sync-document:{id}")
}
fn chunk(id: &str, number: usize) -> String {
    format!("sync-document-data:{id}:{number}")
}
fn checksum<T: Serialize>(value: &T) -> String {
    rayde_sync::chunk::sha256_hex(&serde_json::to_vec(value).unwrap())
}
fn decode(value: &str, limit: usize) -> AppResult<Vec<u8>> {
    if value.len() > limit.div_ceil(3) * 4 {
        return Err(bad(413, "The shared document request is too large."));
    }
    let bytes = B64
        .decode(value)
        .map_err(|_| bad(422, "The shared document encoding is invalid."))?;
    if bytes.len() > limit {
        return Err(bad(413, "The shared document request is too large."));
    }
    Ok(bytes)
}
fn path(data: &Value) -> AppResult<&str> {
    let value = text(data, "path")?;
    if value.is_empty()
        || rayde_sync::manifest::path_problem(value, &rayde_sync::lifecycle::Limits::default())
            .is_some()
    {
        return Err(bad(400, "Choose a workspace file."));
    }
    Ok(value)
}
impl Documents {
    pub fn new(storage: Storage) -> Self {
        Self { storage }
    }
    async fn index(&self) -> AppResult<Index> {
        let index: Index = self.storage.get(INDEX).await?.unwrap_or_default();
        if index.entries.len() > MAX_DOCUMENTS
            || index.bytes > MAX_BYTES
            || index
                .entries
                .values()
                .try_fold(0usize, |sum, e| sum.checked_add(e.bytes))
                != Some(index.bytes)
        {
            return Err(unavailable());
        }
        Ok(index)
    }
    pub async fn usage(&self) -> AppResult<usize> {
        Ok(self.index().await?.bytes)
    }
    pub(crate) async fn head(&self,path:&str)->AppResult<Option<Head>>{
        let index=self.index().await?;
        Ok(self.record(&index,&hash(path)).await?.map(|record|Head{path:path.into(),lineage:record.seed.lineage,sequence:record.sequence}))
    }
    async fn record(&self, index: &Index, id: &str) -> AppResult<Option<Record>> {
        let Some(usage) = index.entries.get(id).filter(|e| e.checksum.is_some()) else {
            return Ok(None);
        };
        let record: Record = self.storage.get(&key(id)).await?.ok_or_else(unavailable)?;
        if Some(checksum(&record)) != usage.checksum
            || record.bytes != usage.bytes
            || record.bytes > live::MAX_STATE
            || record.segments.is_empty()
            || record.segments.len() > 64
            || record.seed.validate().is_err()
            || hash(&record.seed.path) != id
            || record.sequence == 0
            || record.allocated > live::MAX_STATE.div_ceil(CHUNK) + 64
            || decode(&record.vector, live::MAX_VECTOR).is_err()
        {
            return Err(unavailable());
        }
        Ok(Some(record))
    }
    async fn graph(&self, record: &Record, id: &str) -> AppResult<Document> {
        let mut updates = Vec::new();
        let (mut position, mut total) = (0, 0usize);
        for segment in &record.segments {
            if segment.first != position || segment.bytes > live::MAX_STATE {
                return Err(unavailable());
            }
            let mut bytes = Vec::new();
            for _ in 0..segment.bytes.div_ceil(CHUNK) {
                let value = self
                    .storage
                    .get::<String>(&chunk(id, position))
                    .await?
                    .ok_or_else(unavailable)?;
                let part = decode(&value, CHUNK).map_err(|_| unavailable())?;
                bytes.extend(part);
                position += 1;
            }
            if bytes.len() != segment.bytes
                || rayde_sync::chunk::sha256_hex(&bytes) != segment.sha256
            {
                return Err(unavailable());
            }
            total = total.checked_add(bytes.len()).ok_or_else(unavailable)?;
            if total > live::MAX_STATE || position > record.allocated {
                return Err(unavailable());
            }
            updates.push(bytes);
        }
        if total != record.bytes || position != record.allocated {
            return Err(unavailable());
        }
        let document =
            Document::restore(record.seed.clone(), &updates).map_err(|_| unavailable())?;
        if !live::same_vector(
            &document.vector(),
            &decode(&record.vector, live::MAX_VECTOR)?,
        )
        .map_err(|_| unavailable())?
            || rayde_sync::chunk::sha256_hex(document.text().as_bytes()) != record.head
        {
            return Err(unavailable());
        }
        Ok(document)
    }
    fn response(record: &Record, update: Vec<u8>) -> Value {
        json!({"seed":record.seed,"lineage":record.seed.lineage,"sequence":record.sequence,"vector":record.vector,"update":B64.encode(update),"sha256":record.head,"anchor":record.anchor})
    }
    async fn write(
        &self,
        mut index: Index,
        id: &str,
        old: Option<&Record>,
        mut record: Record,
        payload: &[u8],
        compact: bool,
        budget: usize,
    ) -> AppResult<()> {
        let mut values = BTreeMap::new();
        let first = if compact { 0 } else { record.allocated };
        if compact {
            record.segments.clear();
            record.bytes = 0;
        }
        for (number, bytes) in payload.chunks(CHUNK).enumerate() {
            values.insert(chunk(id, first + number), json!(B64.encode(bytes)));
        }
        record.allocated = first + payload.len().div_ceil(CHUNK);
        record.bytes += payload.len();
        record.segments.push(Segment {
            first,
            bytes: payload.len(),
            sha256: rayde_sync::chunk::sha256_hex(payload),
        });
        if record.bytes > live::MAX_STATE
            || record.segments.len() > 64
            || serde_json::to_vec(&record).unwrap().len() > 120 * 1024
        {
            return Err(bad(413, "The shared document exceeds its history limit."));
        }
        for number in record.allocated..old.map_or(0, |r| r.allocated) {
            values.insert(chunk(id, number), Value::Null);
        }
        index.bytes = index
            .bytes
            .saturating_sub(index.entries.get(id).map_or(0, |e| e.bytes))
            .checked_add(record.bytes)
            .ok_or_else(unavailable)?;
        index.entries.insert(
            id.into(),
            Usage {
                bytes: record.bytes,
                checksum: Some(checksum(&record)),
            },
        );
        if index.entries.len() > MAX_DOCUMENTS || index.bytes > MAX_BYTES || index.bytes > budget {
            return Err(bad(
                413,
                "The workspace has no room for more shared document history.",
            ));
        }
        values.insert(key(id), json!(record));
        values.insert(INDEX.into(), json!(index));
        put(&self.storage, values).await
    }
    pub async fn request(
        &self,
        op: &str,
        data: &Value,
        manifest: &Manifest,
        bucket: &Bucket,
        budget: usize,
    ) -> AppResult<Value> {
        let path = path(data)?;
        let id = hash(path);
        let index = self.index().await?;
        let file = manifest
            .files
            .iter()
            .find(|file| {
                file.path == path
                    && matches!(file.kind, FileKind::Regular | FileKind::Executable)
                    && file.size <= live::MAX_TEXT as u64
            })
            .ok_or_else(|| {
                bad(
                    404,
                    "This published file is not available for shared text editing.",
                )
            })?;
        let stored = self.record(&index, &id).await?;
        if stored.as_ref().is_some_and(|r| {
            r.anchor != file.hash || r.seed.workspace != manifest.workspace.as_str()
        }) {
            return Err(conflict());
        }
        if op == "/document-open" {
            if data["generation"].as_u64() != Some(manifest.generation) {
                return Err(conflict());
            }
            if let Some(record) = stored {
                let document = self.graph(&record, &id).await?;
                return Ok(Self::response(&record, document.state()));
            }
            let mut bytes = Vec::new();
            for part in &file.chunks {
                let object = bucket
                    .get(format!(
                        "sync/{}/chunks/{}",
                        manifest.workspace.as_str(),
                        part.hash
                    ))
                    .execute()
                    .await?
                    .ok_or_else(unavailable)?;
                let content = object.body().ok_or_else(unavailable)?.bytes().await?;
                if content.len() != part.size as usize
                    || rayde_sync::chunk::sha256_hex(&content) != part.hash
                    || bytes.len() + content.len() > live::MAX_TEXT
                {
                    return Err(unavailable());
                }
                bytes.extend(content);
            }
            if bytes.len() as u64 != file.size || rayde_sync::chunk::sha256_hex(&bytes) != file.hash
            {
                return Err(unavailable());
            }
            let text = std::str::from_utf8(&bytes)
                .map_err(|_| bad(422, "The published file is not UTF-8 text."))?;
            let document =
                Document::new(manifest.workspace.as_str(), path, manifest.generation, text)
                    .map_err(invalid)?;
            let state = document.state();
            let record = Record {
                seed: document.seed.clone(),
                anchor: file.hash.clone(),
                head: file.hash.clone(),
                sequence: 1,
                vector: B64.encode(document.vector()),
                segments: vec![],
                bytes: 0,
                allocated: 0,
            };
            self.write(index, &id, None, record.clone(), &state, true, budget)
                .await?;
            return Ok(Self::response(&record, state));
        }
        let record = stored.ok_or_else(conflict)?;
        let document = self.graph(&record, &id).await?;
        let update = decode(text(data, "update")?, live::MAX_STATE)?;
        let from = decode(text(data, "from")?, live::MAX_VECTOR)?;
        let exchanged = document
            .exchange(text(data, "lineage")?, &from, &update)
            .map_err(invalid)?;
        let mut next = record.clone();
        if exchanged.changed {
            next.sequence = next.sequence.checked_add(1).ok_or_else(unavailable)?;
            next.vector = B64.encode(exchanged.vector);
            next.head = exchanged.text_sha256;
            let compact = record.segments.len() >= 64
                || record.bytes - record.segments[0].bytes + update.len() >= COMPACT
                || record.bytes + update.len() > live::MAX_STATE;
            self.write(
                index,
                &id,
                Some(&record),
                next.clone(),
                if compact { &exchanged.state } else { &update },
                compact,
                budget,
            )
            .await?;
        }
        Ok(Self::response(&next, exchanged.update))
    }
    /// Fence snapshots against pending text, and rebind an integrated head without reseeding its graph.
    pub async fn publication(&self, manifest: &Manifest) -> AppResult<BTreeMap<String, Value>> {
        let mut index = self.index().await?;
        let mut values = BTreeMap::new();
        for id in index.entries.keys().cloned().collect::<Vec<_>>() {
            let Some(mut record) = self.record(&index, &id).await? else {
                continue;
            };
            let file = manifest.files.iter().find(|f| {
                f.path == record.seed.path
                    && matches!(f.kind, FileKind::Regular | FileKind::Executable)
            });
            if file.is_some_and(|f| f.hash == record.anchor) {
                continue;
            }
            if let Some(file) = file.filter(|f| f.hash == record.head) {
                record.anchor = file.hash.clone();
                index.entries.get_mut(&id).unwrap().checksum = Some(checksum(&record));
                values.insert(key(&id), json!(record));
                continue;
            }
            if record.head != record.anchor {
                return Err(bad(
                    409,
                    "The snapshot would replace pending shared document edits. Integrate those edits before publishing.",
                ));
            }
            for number in 0..record.allocated {
                values.insert(chunk(&id, number), Value::Null);
            }
            index.bytes -= record.bytes;
            index.entries.insert(
                id.clone(),
                Usage {
                    bytes: 0,
                    checksum: None,
                },
            );
            values.insert(key(&id), Value::Null);
        }
        values.insert(INDEX.into(), json!(index));
        Ok(values)
    }
}
