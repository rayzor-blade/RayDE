use super::*;
use base64::engine::general_purpose::STANDARD as B64;
use futures_util::lock::Mutex;
use rayde_session::checkpoint::{self, Checkpoint};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const CHUNK: usize = 40 * 1024;
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
struct Index {
    ids: Vec<String>,
    bytes: usize,
}

pub struct Checkpoints {
    storage: Storage,
    gate: Mutex<()>,
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

    pub async fn save(&self, path: &str, source: &str, next: Checkpoint) -> AppResult<Manifest> {
        let path = rayde_session::store::clean(path)
            .map_err(|_| bad(400, "The checkpoint path is invalid."))?;
        if path.is_empty() || path.len() > 4096 || !workspace_id(source) {
            return Err(bad(400, "The checkpoint context is invalid."));
        }
        let candidate = checkpoint::unpack(&next)
            .map_err(|_| bad(422, "The workspace returned an invalid checkpoint."))?;
        drop(next);
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
        if let Some(old) = &old {
            if old.sha256 == digest {
                return Ok(old.clone());
            }
        }
        let mut index = self
            .storage
            .get::<Index>("checkpoint-index")
            .await?
            .unwrap_or_default();
        if !index.ids.contains(&id) {
            if old.is_some() || index.ids.len() >= MAX_RECORDS {
                return Err(bad(507, "The workspace checkpoint limit was reached."));
            }
            index.ids.push(id.clone());
        }
        index.bytes = index
            .bytes
            .checked_sub(old.as_ref().map_or(0, |entry| entry.bytes))
            .and_then(|size| size.checked_add(bytes.len()))
            .ok_or_else(|| bad(503, "The checkpoint index is invalid."))?;
        if index.bytes > MAX_BYTES {
            return Err(bad(
                507,
                "The workspace recovery storage limit was reached.",
            ));
        }
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
        let mut values = BTreeMap::new();
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
        values.insert("checkpoint-index".into(), json!(index));
        // Bulk storage consumes own string properties on a plain object.
        let object = worker::js_sys::Object::new();
        for (key, value) in values {
            let value = match value {
                Value::String(value) => worker::wasm_bindgen::JsValue::from_str(&value),
                value => worker::js_sys::JSON::parse(&value.to_string())
                    .map_err(|_| bad(503, "The checkpoint could not be encoded."))?,
            };
            worker::js_sys::Reflect::set(
                &object,
                &worker::wasm_bindgen::JsValue::from_str(&key),
                &value,
            )
            .map_err(|_| bad(503, "The checkpoint could not be encoded."))?;
        }
        self.storage.put_multiple_raw(object).await?;
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
        Ok(json!({"ids":index.ids,"bytes":index.bytes}))
    }
}
