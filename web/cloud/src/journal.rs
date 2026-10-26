use super::*;
use crate::checkpoints::{CHUNK, Checkpoints, Index, put, reserve, usage};
use base64::engine::general_purpose::STANDARD as B64;
use rayde_session::checkpoint::{self, Delta};
use serde::{Deserialize, Serialize};

const MAX_ENTRIES: usize = 64;
const COMPACT_BYTES: usize = 256 * 1024;
const MAX_CHUNKS: usize = checkpoint::MAX_BYTES.div_ceil(CHUNK) + MAX_ENTRIES;

#[derive(Clone, Serialize, Deserialize)]
struct Segment {
    first: usize,
    bytes: usize,
    sha256: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Manifest {
    version: u32,
    pub id: String,
    path: String,
    source: String,
    pub sequence: u64,
    vector: String,
    bytes: usize,
    allocated: usize,
    segments: Vec<Segment>,
    last: String,
    updated: u64,
}
fn context(path: &str, source: &str) -> AppResult<(String, String)> {
    let path =
        rayde_session::store::clean(path).map_err(|_| bad(400, "The journal path is invalid."))?;
    if path.is_empty() || path.len() > 4096 || !workspace_id(source) {
        return Err(bad(400, "The journal context is invalid."));
    }
    Ok((hash(&json!([source, path]).to_string()), path))
}
fn unavailable() -> Failure {
    bad(
        503,
        "The document recovery journal is invalid or incomplete.",
    )
}

impl Manifest {
    fn validate(&self) -> AppResult<()> {
        if self.version != 1
            || self.bytes > checkpoint::MAX_BYTES
            || self.segments.is_empty()
            || self.segments.len() > MAX_ENTRIES
            || self.allocated > MAX_CHUNKS
        {
            return Err(unavailable());
        }
        checkpoint::decode_vector(&self.vector).map_err(|_| unavailable())?;
        if context(&self.path, &self.source)
            .map_err(|_| unavailable())?
            .0
            != self.id
        {
            return Err(unavailable());
        }
        Ok(())
    }
}

impl Checkpoints {
    async fn journal_segments(&self, record: &Manifest) -> AppResult<Vec<Vec<u8>>> {
        record.validate()?;
        let (mut position, mut total) = (0, 0usize);
        let mut updates = Vec::new();
        for segment in &record.segments {
            if segment.first != position || segment.bytes > checkpoint::MAX_BYTES {
                return Err(unavailable());
            }
            let mut bytes = Vec::with_capacity(segment.bytes);
            for number in 0..segment.bytes.div_ceil(CHUNK) {
                let value = self
                    .storage
                    .get::<String>(&format!("journal-data:{}:{}", record.id, position + number))
                    .await?
                    .ok_or_else(unavailable)?;
                if value.len() > CHUNK.div_ceil(3) * 4 {
                    return Err(unavailable());
                }
                let chunk = B64.decode(value).map_err(|_| unavailable())?;
                if chunk.len() > CHUNK {
                    return Err(unavailable());
                }
                bytes.extend(chunk);
            }
            if bytes.len() != segment.bytes || checkpoint::digest(&bytes) != segment.sha256 {
                return Err(unavailable());
            }
            position += segment.bytes.div_ceil(CHUNK);
            total = total.checked_add(bytes.len()).ok_or_else(unavailable)?;
            if position > record.allocated || total > checkpoint::MAX_BYTES {
                return Err(unavailable());
            }
            updates.push(bytes);
        }
        if total != record.bytes {
            return Err(unavailable());
        }
        Ok(updates)
    }

    pub async fn journal_vector(&self, path: &str, source: &str) -> AppResult<String> {
        let (id, _) = context(path, source)?;
        let _guard = self.gate.lock().await;
        match self
            .storage
            .get::<Manifest>(&format!("journal:{id}"))
            .await?
        {
            Some(record) => {
                record.validate()?;
                if record.id != id {
                    return Err(unavailable());
                }
                Ok(record.vector)
            }
            None => Ok("AA==".into()),
        }
    }

    pub async fn journal_append(
        &self,
        path: &str,
        source: &str,
        expected: &str,
        delta: Delta,
    ) -> AppResult<Manifest> {
        let (id, path) = context(path, source)?;
        let mut bytes = checkpoint::unpack_delta(&delta)
            .map_err(|_| bad(422, "The workspace returned an invalid recovery delta."))?;
        let _guard = self.gate.lock().await;
        let key = format!("journal:{id}");
        let old = self.storage.get::<Manifest>(&key).await?;
        if let Some(record) = &old {
            record.validate()?;
            if record.id != id {
                return Err(unavailable());
            }
        }
        let current = old.as_ref().map_or("AA==", |record| record.vector.as_str());
        if current != expected
            || !checkpoint::follows(current, &delta.vector).map_err(|_| unavailable())?
        {
            return Err(bad(
                409,
                "The recovery journal changed. Reconnect before retrying.",
            ));
        }
        if let Some(old) = &old {
            if old.last == delta.sha256 && old.vector == delta.vector {
                put(
                    &self.storage,
                    crate::recovery::confirm(
                        &self.storage,
                        source,
                        &path,
                        "journal",
                        &id,
                        format!("{}:{}", old.sequence, old.last),
                    )
                    .await?,
                )
                .await?;
                return Ok(old.clone());
            }
        }
        let compact = old.as_ref().is_none_or(|record| {
            record.segments.len() >= MAX_ENTRIES
                || record
                    .bytes
                    .saturating_sub(record.segments[0].bytes)
                    .saturating_add(bytes.len())
                    >= COMPACT_BYTES
                || record.bytes.saturating_add(bytes.len()) > checkpoint::MAX_BYTES
        });
        let mut segments = old
            .as_ref()
            .map_or_else(Vec::new, |record| record.segments.clone());
        if compact {
            let mut updates = match &old {
                Some(record) => self.journal_segments(record).await?,
                None => Vec::new(),
            };
            updates.push(bytes);
            bytes = checkpoint::materialize(&updates, &delta.vector).map_err(|_| unavailable())?;
            segments.clear();
        }
        let first = segments
            .last()
            .map_or(0, |last| last.first + last.bytes.div_ceil(CHUNK));
        let chunks = first + bytes.len().div_ceil(CHUNK);
        if chunks > MAX_CHUNKS {
            return Err(unavailable());
        }
        let total = if compact {
            bytes.len()
        } else {
            old.as_ref()
                .map_or(0, |record| record.bytes)
                .saturating_add(bytes.len())
        };
        if total > checkpoint::MAX_BYTES {
            return Err(bad(413, "The document exceeds the recovery journal limit."));
        }
        segments.push(Segment {
            first,
            bytes: bytes.len(),
            sha256: checkpoint::digest(&bytes),
        });
        let record = Manifest {
            version: 1,
            id: id.clone(),
            path,
            source: source.into(),
            sequence: old
                .as_ref()
                .map_or(Ok(1), |r| r.sequence.checked_add(1).ok_or_else(unavailable))?,
            vector: delta.vector,
            bytes: total,
            allocated: old.as_ref().map_or(chunks, |r| r.allocated.max(chunks)),
            segments,
            last: delta.sha256,
            updated: now(),
        };
        let mut values = reserve(
            &self.storage,
            &key,
            old.as_ref().map(|r| r.bytes),
            record.bytes,
            true,
        )
        .await?;
        for (number, chunk) in bytes.chunks(CHUNK).enumerate() {
            values.insert(
                format!("journal-data:{id}:{}", first + number),
                json!(B64.encode(chunk)),
            );
        }
        if compact {
            for number in chunks..record.allocated {
                values.insert(format!("journal-data:{id}:{number}"), json!(""));
            }
        }
        values.insert(key, json!(&record));
        values.extend(
            crate::recovery::confirm(
                &self.storage,
                source,
                &record.path,
                "journal",
                &id,
                format!("{}:{}", record.sequence, record.last),
            )
            .await?,
        );
        put(&self.storage, values).await?;
        Ok(record)
    }

    pub async fn journal_get(&self, id: &str) -> AppResult<Value> {
        if !workspace_id(id) {
            return Err(bad(400, "The journal ID is invalid."));
        }
        let _guard = self.gate.lock().await;
        let record = self
            .storage
            .get::<Manifest>(&format!("journal:{id}"))
            .await?
            .ok_or_else(|| bad(404, "Journal not found."))?;
        if record.id != id {
            return Err(unavailable());
        }
        let updates = self.journal_segments(&record).await?;
        let state = checkpoint::materialize(&updates, &record.vector).map_err(|_| unavailable())?;
        let checkpoint = checkpoint::pack(&state).map_err(|_| unavailable())?;
        Ok(json!({"manifest":record,"checkpoint":checkpoint}))
    }

    pub async fn journal_list(&self) -> AppResult<Value> {
        let _guard = self.gate.lock().await;
        let index = self
            .storage
            .get::<Index>("checkpoint-index")
            .await?
            .unwrap_or_default();
        let usage = usage(&self.storage, &index).await?;
        Ok(
            json!({"ids":index.ids.iter().filter_map(|id|id.strip_prefix("journal:")).collect::<Vec<_>>(),"bytes":usage.journal_bytes,"totalBytes":usage.bytes}),
        )
    }
}
