use super::*;
use base64::engine::general_purpose::STANDARD as B64;
use futures_util::lock::Mutex;
use rayde_session::checkpoint::{self, Checkpoint};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub(crate) const CHUNK: usize = 40 * 1024;
const MAX_RECORDS: usize = 512;
const MAX_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub version: u32,
    pub id: String,
    pub path: String,
    pub source: String,
    pub sha256: String,
    pub bytes: usize,
    pub chunks: usize,
    pub allocated: usize,
    pub saved: u64,
}
#[derive(Default, Serialize, Deserialize)]
pub(crate) struct Index {
    #[serde(default)]
    version: u32,
    pub ids: Vec<String>,
    pub bytes: usize,
    #[serde(default)]
    pub journal_bytes: usize,
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Usage {
    pub bytes: usize,
    pub journal_bytes: usize,
    records: usize,
}
pub(crate) async fn usage(storage: &Storage, index: &Index) -> AppResult<Usage> {
    let stored = storage.get::<Usage>("recovery-usage").await?;
    if stored.is_none() && index.version >= 2 {
        return Err(bad(503, "The recovery accounting is unavailable."));
    }
    Ok(stored.unwrap_or(Usage {
        bytes: index.bytes,
        journal_bytes: index.journal_bytes,
        records: index.ids.len(),
    }))
}

/// Existing records update only small counters; the ID registry changes on admission.
pub(crate) async fn reserve(
    storage: &Storage,
    id: &str,
    old: Option<usize>,
    bytes: usize,
    journal: bool,
) -> AppResult<BTreeMap<String, Value>> {
    let mut counters = storage.get::<Usage>("recovery-usage").await?;
    let mut index = if old.is_none() || counters.is_none() {
        Some(
            storage
                .get::<Index>("checkpoint-index")
                .await?
                .unwrap_or_default(),
        )
    } else {
        None
    };
    let migrating = counters.is_none();
    if migrating && index.as_ref().is_some_and(|index| index.version >= 2) {
        return Err(bad(503, "The recovery accounting is unavailable."));
    }
    let mut counters = counters.take().unwrap_or_else(|| {
        let index = index.as_ref().unwrap();
        Usage {
            bytes: index.bytes,
            journal_bytes: index.journal_bytes,
            records: index.ids.len(),
        }
    });
    let mut values = BTreeMap::new();
    if migrating {
        let index = index.as_mut().unwrap();
        index.version = 2;
        values.insert("checkpoint-index".into(), json!(index));
    }
    if old.is_none() {
        let index = index.as_mut().unwrap();
        index.version = 2;
        if counters.records >= MAX_RECORDS || index.ids.iter().any(|entry| entry == id) {
            return Err(bad(507, "The workspace checkpoint limit was reached."));
        }
        counters.records += 1;
        index.ids.push(id.into());
        values.insert("checkpoint-index".into(), json!(index));
    }
    counters.bytes = counters
        .bytes
        .checked_sub(old.unwrap_or(0))
        .and_then(|n| n.checked_add(bytes))
        .ok_or_else(|| bad(503, "The checkpoint index is invalid."))?;
    if counters.bytes > MAX_BYTES {
        return Err(bad(
            507,
            "The workspace recovery storage limit was reached.",
        ));
    }
    if journal {
        counters.journal_bytes = counters
            .journal_bytes
            .checked_sub(old.unwrap_or(0))
            .and_then(|n| n.checked_add(bytes))
            .ok_or_else(|| bad(503, "The checkpoint index is invalid."))?;
    }
    if counters.journal_bytes > counters.bytes || counters.records > MAX_RECORDS {
        return Err(bad(503, "The checkpoint index is invalid."));
    }
    values.insert("recovery-usage".into(), json!(counters));
    Ok(values)
}

pub struct Checkpoints {
    pub(crate) storage: Storage,
    pub(crate) gate: Mutex<()>,
}
impl Checkpoints {
    pub fn new(storage: Storage) -> Self {
        Self {
            storage,
            gate: Mutex::new(()),
        }
    }

    async fn bytes(&self, manifest: &Manifest) -> AppResult<Vec<u8>> {
        if manifest.version != 1
            || manifest.bytes > checkpoint::MAX_BYTES
            || manifest.chunks != manifest.bytes.div_ceil(CHUNK)
            || manifest.allocated < manifest.chunks
            || manifest.allocated > checkpoint::MAX_BYTES.div_ceil(CHUNK)
        {
            return Err(bad(503, "The saved checkpoint is unavailable."));
        }
        let mut bytes = Vec::with_capacity(manifest.bytes);
        for index in 0..manifest.chunks {
            let chunk = self
                .storage
                .get::<String>(&format!("checkpoint-data:{}:{index}", manifest.id))
                .await?
                .ok_or_else(|| bad(503, "The saved checkpoint is incomplete."))?;
            if chunk.len() > CHUNK.div_ceil(3) * 4 {
                return Err(bad(503, "The saved checkpoint is invalid."));
            }
            let chunk = B64
                .decode(chunk)
                .map_err(|_| bad(503, "The saved checkpoint is invalid."))?;
            if chunk.len() > CHUNK {
                return Err(bad(503, "The saved checkpoint is invalid."));
            }
            bytes.extend(chunk);
        }
        if bytes.len() != manifest.bytes || checkpoint::digest(&bytes) != manifest.sha256 {
            return Err(bad(503, "The saved checkpoint is invalid."));
        }
        Ok(bytes)
    }

    pub async fn save(
        &self,
        path: &str,
        source: &str,
        next: Checkpoint,
        confirmed: bool,
    ) -> AppResult<Manifest> {
        let path = rayde_session::store::clean(path)
            .map_err(|_| bad(400, "The checkpoint path is invalid."))?;
        if path.is_empty() || path.len() > 4096 || !workspace_id(source) {
            return Err(bad(400, "The checkpoint context is invalid."));
        }
        let candidate = checkpoint::unpack(&next)
            .map_err(|_| bad(422, "The workspace returned an invalid checkpoint."))?;
        drop(next);
        let candidate = if confirmed {
            checkpoint::merge(&candidate, &candidate)
                .map_err(|_| bad(422, "The workspace returned an invalid checkpoint."))?
        } else {
            candidate
        };
        let native_digest = confirmed.then(|| checkpoint::digest(&candidate));
        let _guard = self.gate.lock().await;
        let id = hash(&json!([source, path]).to_string());
        let key = format!("checkpoint:{id}");
        let old = self.storage.get::<Manifest>(&key).await?;
        let bytes = match &old {
            Some(old) => {
                checkpoint::merge(&self.bytes(old).await?, &candidate).map_err(|error| {
                    if error.code == "too-large" {
                        bad(413, "The document exceeds the durable checkpoint limit.")
                    } else {
                        bad(409, &error.message)
                    }
                })?
            }
            None => candidate,
        };
        let digest = checkpoint::digest(&bytes);
        if native_digest.is_some_and(|expected| expected != digest) {
            return Err(bad(
                409,
                "Saved recovery contains history missing from compute. Restore it before saving.",
            ));
        }
        if let Some(old) = &old {
            if old.sha256 == digest {
                if confirmed {
                    put(
                        &self.storage,
                        crate::recovery::confirm(
                            &self.storage,
                            source,
                            &path,
                            "checkpoint",
                            &id,
                            old.sha256.clone(),
                        )
                        .await?,
                    )
                    .await?;
                }
                return Ok(old.clone());
            }
        }
        let mut values = reserve(
            &self.storage,
            &id,
            old.as_ref().map(|entry| entry.bytes),
            bytes.len(),
            false,
        )
        .await?;
        let chunks = bytes.len().div_ceil(CHUNK);
        let manifest = Manifest {
            version: 1,
            id: id.clone(),
            path,
            source: source.into(),
            sha256: digest,
            bytes: bytes.len(),
            chunks,
            allocated: old.as_ref().map_or(chunks, |old| old.allocated.max(chunks)),
            saved: now(),
        };
        for (number, chunk) in bytes.chunks(CHUNK).enumerate() {
            values.insert(
                format!("checkpoint-data:{id}:{number}"),
                json!(B64.encode(chunk)),
            );
        }
        // Replacing obsolete chunks in the same write leaves no older payload behind the new manifest.
        for number in chunks..manifest.allocated {
            values.insert(format!("checkpoint-data:{id}:{number}"), json!(""));
        }
        values.insert(key, json!(&manifest));
        if confirmed {
            values.extend(
                crate::recovery::confirm(
                    &self.storage,
                    source,
                    &manifest.path,
                    "checkpoint",
                    &id,
                    manifest.sha256.clone(),
                )
                .await?,
            );
        } else {
            values.extend(
                crate::recovery::unconfirm(
                    &self.storage,
                    source,
                    &manifest.path,
                    "checkpoint",
                    &id,
                )
                .await?,
            );
        }
        put(&self.storage, values).await?;
        Ok(manifest)
    }

    pub async fn get(&self, id: &str) -> AppResult<Value> {
        if !workspace_id(id) {
            return Err(bad(400, "The checkpoint ID is invalid."));
        }
        let _guard = self.gate.lock().await;
        let manifest = self
            .storage
            .get::<Manifest>(&format!("checkpoint:{id}"))
            .await?
            .ok_or_else(|| bad(404, "Checkpoint not found."))?;
        let bytes = self.bytes(&manifest).await?;
        let checkpoint =
            checkpoint::pack(&bytes).map_err(|_| bad(503, "The saved checkpoint is invalid."))?;
        Ok(json!({"manifest":manifest,"checkpoint":checkpoint}))
    }

    pub async fn list(&self) -> AppResult<Value> {
        let _guard = self.gate.lock().await;
        let index = self
            .storage
            .get::<Index>("checkpoint-index")
            .await?
            .unwrap_or_default();
        let usage = usage(&self.storage, &index).await?;
        Ok(
            json!({"ids":index.ids.into_iter().filter(|id|!id.starts_with("journal:")).collect::<Vec<_>>(),"bytes":usage.bytes.saturating_sub(usage.journal_bytes),"totalBytes":usage.bytes}),
        )
    }
}

pub(crate) async fn put(storage: &Storage, values: BTreeMap<String, Value>) -> AppResult<()> {
    // Bulk storage consumes own string properties on a plain object.
    let object = worker::js_sys::Object::new();
    for (key, value) in values {
        let value = match value {
            Value::String(value) => worker::wasm_bindgen::JsValue::from_str(&value),
            value => worker::js_sys::JSON::parse(&value.to_string())
                .map_err(|_| bad(503, "The recovery record could not be encoded."))?,
        };
        worker::js_sys::Reflect::set(
            &object,
            &worker::wasm_bindgen::JsValue::from_str(&key),
            &value,
        )
        .map_err(|_| bad(503, "The recovery record could not be encoded."))?;
    }
    storage.put_multiple_raw(object).await?;
    Ok(())
}
