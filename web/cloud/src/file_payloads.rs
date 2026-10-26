use super::*;
use base64::engine::general_purpose::STANDARD as B64;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_FILE: usize = 12 * 1024 * 1024;
const MAX_BYTES: usize = 64 * 1024 * 1024;
const MAX_RECORDS: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Payload {
    pub sha256: String,
    pub bytes: usize,
}
#[derive(Default, Serialize, Deserialize)]
struct Usage {
    bytes: usize,
    records: usize,
}
pub(crate) struct FilePayloads {
    bucket: Option<Bucket>,
    prefix: String,
}
fn unavailable() -> Failure {
    bad(503, "The workspace file recovery payload is unavailable.")
}
fn validate(payload: &Payload) -> AppResult<()> {
    if !opaque(&payload.sha256) || payload.bytes > MAX_FILE {
        return Err(unavailable());
    }
    Ok(())
}
async fn usage(storage: &Storage) -> AppResult<Usage> {
    let usage = storage.get::<Usage>("file-payload-usage").await?;
    if usage.is_none()
        && storage
            .get::<bool>("file-payload-initialized")
            .await?
            .unwrap_or(false)
    {
        return Err(unavailable());
    }
    let usage = usage.unwrap_or_default();
    if usage.bytes > MAX_BYTES || usage.records > MAX_RECORDS {
        return Err(unavailable());
    }
    Ok(usage)
}
impl FilePayloads {
    pub fn new(bucket: Option<Bucket>, workspace: &str) -> Self {
        Self {
            bucket,
            prefix: format!("workspaces/{}/files/", hash(workspace)),
        }
    }

    pub fn decode(&self, request: &Value) -> AppResult<Option<Vec<u8>>> {
        if request["op"] != "fs.write" {
            return Ok(None);
        }
        if self.bucket.is_none() {
            return Err(bad(
                503,
                "Workspace file recovery storage is not configured.",
            ));
        }
        let value = text(request, "data")?;
        if value.len() > MAX_FILE.div_ceil(3) * 4 {
            return Err(bad(413, "The file exceeds the recovery payload limit."));
        }
        let bytes = if request["encoding"] == "base64" {
            B64.decode(value)
                .map_err(|_| bad(400, "The file data is not valid base64."))?
        } else {
            value.as_bytes().to_vec()
        };
        if bytes.len() > MAX_FILE {
            return Err(bad(413, "The file exceeds the recovery payload limit."));
        }
        Ok(Some(bytes))
    }

    /// Reserve possible uploads before R2 I/O; failed or interrupted puts remain accounted for.
    pub async fn reserve(
        storage: &Storage,
        bytes: &[u8],
    ) -> AppResult<(Payload, BTreeMap<String, Value>)> {
        let payload = Payload {
            sha256: rayde_session::checkpoint::digest(bytes),
            bytes: bytes.len(),
        };
        validate(&payload)?;
        let mut usage = usage(storage).await?;
        let key = format!("file-payload:{}", payload.sha256);
        let old = storage.get::<Payload>(&key).await?;
        let mut values = BTreeMap::new();
        if let Some(old) = old {
            if old != payload || usage.records == 0 || usage.bytes < payload.bytes {
                return Err(unavailable());
            }
        } else {
            usage.bytes = usage
                .bytes
                .checked_add(payload.bytes)
                .ok_or_else(unavailable)?;
            usage.records += 1;
            if usage.bytes > MAX_BYTES || usage.records > MAX_RECORDS {
                return Err(bad(
                    507,
                    "The workspace file recovery storage limit was reached.",
                ));
            }
            values.insert(key, json!(&payload));
            values.insert("file-payload-usage".into(), json!(usage));
            values.insert("file-payload-initialized".into(), json!(true));
        }
        Ok((payload, values))
    }

    pub async fn store(&self, payload: &Payload, bytes: Vec<u8>) -> AppResult<()> {
        validate(payload)?;
        let bucket = self.bucket.as_ref().ok_or_else(unavailable)?;
        let checksum = Sha256::digest(&bytes).to_vec();
        if bytes.len() != payload.bytes
            || checksum
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
                != payload.sha256
        {
            return Err(unavailable());
        }
        let written = bucket
            .put(format!("{}{}", self.prefix, payload.sha256), bytes)
            .sha256(checksum)
            .only_if(Conditional {
                etag_does_not_match: Some("*".into()),
                ..Default::default()
            })
            .execute()
            .await?;
        if written.is_none() {
            self.read(payload).await?;
        }
        Ok(())
    }

    pub async fn read(&self, payload: &Payload) -> AppResult<Vec<u8>> {
        validate(payload)?;
        let object = self
            .bucket
            .as_ref()
            .ok_or_else(unavailable)?
            .get(format!("{}{}", self.prefix, payload.sha256))
            .execute()
            .await?
            .ok_or_else(unavailable)?;
        if object.size() != payload.bytes as u64 {
            return Err(unavailable());
        }
        let bytes = object.body().ok_or_else(unavailable)?.bytes().await?;
        if bytes.len() != payload.bytes
            || rayde_session::checkpoint::digest(&bytes) != payload.sha256
        {
            return Err(unavailable());
        }
        Ok(bytes)
    }

    pub async fn info(storage: &Storage) -> AppResult<Value> {
        let usage = usage(storage).await?;
        Ok(
            json!({"bytes":usage.bytes,"records":usage.records,"maxBytes":MAX_BYTES,"maxFileBytes":MAX_FILE}),
        )
    }
}

impl crate::checkpoints::Checkpoints {
    pub async fn file_payload(
        &self,
        source: &str,
        mutation: u64,
        revision: u64,
    ) -> AppResult<Value> {
        let (payload, operation) = {
            let _guard = self.gate.lock().await;
            self.file_operation(source, mutation, revision).await?
        };
        let bytes = crate::workspace::deadline(self.files.read(&payload), 15)
            .await
            .map_err(|_| unavailable())??;
        // Object I/O does not hold the storage gate; reject a plan changed during the read.
        let _guard = self.gate.lock().await;
        self.file_operation(source, mutation, revision).await?;
        Ok(
            json!({"scope":"operation-payload","automaticRestore":false,"mutation":operation,"data":B64.encode(bytes),"encoding":"base64"}),
        )
    }
}
