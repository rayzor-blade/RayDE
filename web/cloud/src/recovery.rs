use super::*;
use crate::checkpoints::{Checkpoints, put};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_MUTATIONS: u64 = 1024;
const MAX_HEADS: usize = 512;
const MAX_METADATA: usize = 1024 * 1024;

#[derive(Default, Serialize, Deserialize)]
struct Catalog {
    version: u32,
    revision: u64,
    mutations: u64,
    bytes: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    heads: Vec<String>,
    #[serde(default)]
    head_count: usize,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Head {
    source: String,
    path: String,
    kind: String,
    id: String,
    revision: u64,
    stamp: String,
    allocated: usize,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Mutation {
    pub id: u64,
    source: String,
    operation: String,
    path: String,
    to: Option<String>,
    revision: u64,
    outcome: String,
    code: Option<String>,
    allocated: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    payload: Option<crate::file_payloads::Payload>,
}
fn unavailable() -> Failure {
    bad(503, "The workspace recovery catalog is unavailable.")
}
fn path(value: &str) -> AppResult<String> {
    let path = rayde_session::store::clean(value)
        .map_err(|_| bad(400, "The recovery path is invalid."))?;
    if path.is_empty() || path.len() > 4096 {
        return Err(bad(400, "The recovery path is invalid."));
    }
    Ok(path)
}
pub(crate) fn normalize(mut request: Value) -> AppResult<Value> {
    let operation = text(&request, "op")?.to_owned();
    if operation == "fs.rename" {
        return Ok(
            json!({"op":operation,"from":path(text(&request,"from")?)?,"to":path(text(&request,"to")?)?}),
        );
    }
    let file = path(text(&request, "path")?)?;
    Ok(match operation.as_str() {
        "fs.write" => {
            if !request["data"].is_string() {
                return Err(bad(400, "The file data is invalid."));
            }
            let data = request.as_object_mut().unwrap().remove("data").unwrap();
            json!({"op":operation,"path":file,"data":data,"encoding":if request["encoding"]=="base64" {"base64"} else {"utf8"}})
        }
        "fs.remove" => {
            json!({"op":operation,"path":file,"recursive":request["recursive"].as_bool().unwrap_or(false)})
        }
        "fs.mkdir" => json!({"op":operation,"path":file}),
        _ => return Err(bad(400, "The file operation is invalid.")),
    })
}
async fn catalog(storage: &Storage) -> AppResult<Catalog> {
    match storage.get::<Catalog>("recovery-catalog").await? {
        Some(mut catalog)
            if matches!(catalog.version, 1 | 2)
                && catalog.mutations <= MAX_MUTATIONS
                && catalog.heads.len() <= MAX_HEADS
                && catalog.head_count <= MAX_HEADS
                && catalog.bytes <= MAX_METADATA =>
        {
            if catalog.version == 1 {
                catalog.head_count = catalog.heads.len();
            } else if !catalog.heads.is_empty() {
                return Err(unavailable());
            }
            Ok(catalog)
        }
        Some(_) => Err(unavailable()),
        None if storage
            .get::<bool>("recovery-catalog-initialized")
            .await?
            .unwrap_or(false) =>
        {
            Err(unavailable())
        }
        None => Ok(Catalog {
            version: 2,
            ..Catalog::default()
        }),
    }
}
fn advance(catalog: &mut Catalog) -> AppResult<()> {
    catalog.revision = catalog.revision.checked_add(1).ok_or_else(unavailable)?;
    Ok(())
}
fn root(values: &mut BTreeMap<String, Value>, mut catalog: Catalog) -> AppResult<()> {
    if catalog.version == 1 {
        values.insert(
            "recovery-heads".into(),
            json!(std::mem::take(&mut catalog.heads)),
        );
        catalog.version = 2;
    }
    if catalog
        .bytes
        .saturating_add(
            serde_json::to_vec(&catalog)
                .map_err(|_| unavailable())?
                .len(),
        )
        .saturating_add(catalog.head_count * 46 + 2)
        > MAX_METADATA
    {
        return Err(bad(
            507,
            "The workspace recovery metadata limit was reached.",
        ));
    }
    values.insert("recovery-catalog".into(), json!(catalog));
    values.insert("recovery-catalog-initialized".into(), json!(true));
    Ok(())
}

async fn head_ids(storage: &Storage, catalog: &Catalog) -> AppResult<Vec<String>> {
    let ids = if catalog.version == 1 {
        catalog.heads.clone()
    } else {
        storage
            .get::<Vec<String>>("recovery-heads")
            .await?
            .unwrap_or_default()
    };
    if ids.len() != catalog.head_count || ids.iter().any(|id| !workspace_id(id)) {
        return Err(unavailable());
    }
    Ok(ids)
}

/// The caller holds the recovery storage gate and commits these values with the payload.
pub(crate) async fn confirm(
    storage: &Storage,
    source: &str,
    file: &str,
    kind: &str,
    id: &str,
    stamp: String,
) -> AppResult<BTreeMap<String, Value>> {
    let file = path(file)?;
    if !workspace_id(source) || !workspace_id(id) || !matches!(kind, "checkpoint" | "journal") {
        return Err(unavailable());
    }
    let key = hash(&json!([source, file]).to_string());
    let mut catalog = catalog(storage).await?;
    let old = storage.get::<Head>(&format!("recovery-head:{key}")).await?;
    if old.is_some() && catalog.head_count == 0 {
        return Err(unavailable());
    }
    let mut values = BTreeMap::new();
    if old.is_none() {
        if catalog.head_count >= MAX_HEADS {
            return Err(bad(507, "The workspace recovery head limit was reached."));
        }
        let mut ids = head_ids(storage, &catalog).await?;
        if ids.contains(&key) {
            return Err(unavailable());
        }
        ids.push(key.clone());
        catalog.head_count = ids.len();
        if catalog.version == 1 {
            catalog.heads = ids;
        } else {
            values.insert("recovery-heads".into(), json!(ids));
        }
    }
    advance(&mut catalog)?;
    let mut head = Head {
        source: source.into(),
        path: file,
        kind: kind.into(),
        id: id.into(),
        revision: catalog.revision,
        stamp,
        allocated: 0,
    };
    let required = serde_json::to_vec(&head).map_err(|_| unavailable())?.len() + 64;
    head.allocated = old
        .as_ref()
        .map_or(required, |old| old.allocated.max(required));
    if serde_json::to_vec(&head).map_err(|_| unavailable())?.len() > head.allocated {
        return Err(unavailable());
    }
    catalog.bytes = catalog
        .bytes
        .checked_sub(old.as_ref().map_or(0, |old| old.allocated))
        .and_then(|bytes| bytes.checked_add(head.allocated))
        .ok_or_else(unavailable)?;
    values.insert(format!("recovery-head:{key}"), json!(head));
    root(&mut values, catalog)?;
    Ok(values)
}

pub(crate) async fn unconfirm(
    storage: &Storage,
    source: &str,
    file: &str,
    kind: &str,
    id: &str,
) -> AppResult<BTreeMap<String, Value>> {
    let key = hash(&json!([source, file]).to_string());
    let mut catalog = catalog(storage).await?;
    let mut values = BTreeMap::new();
    if let Some(mut head) = storage.get::<Head>(&format!("recovery-head:{key}")).await? {
        if head.kind == kind && head.id == id {
            advance(&mut catalog)?;
            head.stamp.clear();
            head.revision = catalog.revision;
            values.insert(format!("recovery-head:{key}"), json!(head));
            root(&mut values, catalog)?;
        }
    }
    Ok(values)
}

impl Checkpoints {
    pub async fn mutation_begin(&self, source: &str, request: &Value) -> AppResult<Mutation> {
        if !workspace_id(source) {
            return Err(unavailable());
        }
        let operation = text(request, "op")?;
        if !matches!(
            operation,
            "fs.write" | "fs.mkdir" | "fs.remove" | "fs.rename"
        ) {
            return Err(bad(400, "The file operation is invalid."));
        }
        let (file, to) = if operation == "fs.rename" {
            (
                path(text(request, "from")?)?,
                Some(path(text(request, "to")?)?),
            )
        } else {
            (path(text(request, "path")?)?, None)
        };
        let bytes = self.files.decode(request)?;
        let guard = self.gate.lock().await;
        let mut catalog = catalog(&self.storage).await?;
        if catalog.mutations >= MAX_MUTATIONS {
            return Err(bad(
                507,
                "The workspace recovery mutation limit was reached.",
            ));
        }
        advance(&mut catalog)?;
        catalog.mutations += 1;
        let (payload, mut values) = if let Some(bytes) = &bytes {
            let (payload, values) =
                crate::file_payloads::FilePayloads::reserve(&self.storage, bytes).await?;
            (Some(payload), values)
        } else {
            (None, BTreeMap::new())
        };
        let mut mutation = Mutation {
            id: catalog.mutations,
            source: source.into(),
            operation: operation.into(),
            path: file,
            to,
            revision: catalog.revision,
            outcome: "pending".into(),
            code: None,
            allocated: 0,
            payload,
        };
        mutation.allocated = serde_json::to_vec(&mutation)
            .map_err(|_| unavailable())?
            .len()
            + 256;
        catalog.bytes = catalog
            .bytes
            .checked_add(mutation.allocated)
            .ok_or_else(unavailable)?;
        values.insert(
            format!("recovery-mutation:{}", mutation.id),
            json!(&mutation),
        );
        root(&mut values, catalog)?;
        put(&self.storage, values).await?;
        drop(guard);
        if let (Some(payload), Some(bytes)) = (&mutation.payload, bytes) {
            let stored = crate::workspace::deadline(self.files.store(payload, bytes), 15)
                .await
                .unwrap_or_else(|_| Err(bad(503, "Workspace file recovery storage timed out.")));
            if let Err(error) = stored {
                self.finish_mutation(&mutation, None, Some("payload-unavailable"))
                    .await?;
                return Err(error);
            }
        }
        Ok(mutation)
    }

    pub async fn mutation_finish(
        &self,
        mutation: &Mutation,
        reply: Option<&Value>,
    ) -> AppResult<()> {
        self.finish_mutation(mutation, reply, None).await
    }

    pub(crate) async fn mutation_refuse(&self, mutation: &Mutation) -> AppResult<()> {
        self.finish_mutation(mutation, None, Some("session-expired"))
            .await
    }

    async fn finish_mutation(
        &self,
        mutation: &Mutation,
        reply: Option<&Value>,
        refused: Option<&str>,
    ) -> AppResult<()> {
        let _guard = self.gate.lock().await;
        let mut catalog = catalog(&self.storage).await?;
        let mut stored = self
            .storage
            .get::<Mutation>(&format!("recovery-mutation:{}", mutation.id))
            .await?
            .ok_or_else(unavailable)?;
        if stored.source != mutation.source
            || stored.revision != mutation.revision
            || stored.outcome != "pending"
        {
            return Err(unavailable());
        }
        stored.code = reply.and_then(|reply| reply["code"].as_str()).map(|code| {
            code.chars()
                .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
                .take(64)
                .collect::<String>()
        });
        stored.outcome = if let Some(code) = refused {
            stored.code = Some(code.into());
            "refused"
        } else if reply.is_some_and(|reply| reply["ok"] == true) {
            "applied"
        } else if matches!(
            stored.code.as_deref(),
            Some(
                "outside"
                    | "bad-request"
                    | "bad-path"
                    | "auth-required"
                    | "unauthorised"
                    | "document-open"
                    | "not-text"
                    | "buffer-dirty"
                    | "recovery-conflict"
                    | "bad-buffer-state"
            )
        ) {
            "refused"
        } else {
            "uncertain"
        }
        .into();
        if serde_json::to_vec(&stored)
            .map_err(|_| unavailable())?
            .len()
            > stored.allocated
        {
            return Err(unavailable());
        }
        advance(&mut catalog)?;
        let mut values = BTreeMap::new();
        values.insert(format!("recovery-mutation:{}", stored.id), json!(stored));
        root(&mut values, catalog)?;
        put(&self.storage, values).await
    }

    pub(crate) async fn file_operation(
        &self,
        source: &str,
        mutation: u64,
        revision: u64,
    ) -> AppResult<(crate::file_payloads::Payload, Mutation)> {
        if !workspace_id(source) || mutation == 0 {
            return Err(bad(400, "The file recovery context is invalid."));
        }
        let catalog = catalog(&self.storage).await?;
        if revision != catalog.revision {
            return Err(bad(409, "Workspace recovery changed. Request a new plan."));
        }
        let operation = self
            .storage
            .get::<Mutation>(&format!("recovery-mutation:{mutation}"))
            .await?
            .filter(|operation| operation.source == source && operation.id == mutation)
            .ok_or_else(|| bad(404, "File recovery operation not found."))?;
        if operation.operation != "fs.write" || operation.outcome != "applied" {
            return Err(bad(409, "The file operation is not confirmed."));
        }
        let payload = operation
            .payload
            .clone()
            .ok_or_else(|| bad(409, "The file operation has no recovery payload."))?;
        Ok((payload, operation))
    }

    pub async fn recovery_plan(&self, source: &str, expected: Option<u64>) -> AppResult<Value> {
        if !workspace_id(source) {
            return Err(bad(400, "The recovery source is invalid."));
        }
        let _guard = self.gate.lock().await;
        let catalog = catalog(&self.storage).await?;
        if expected.is_some_and(|revision| revision != catalog.revision) {
            return Err(bad(409, "Workspace recovery changed. Request a new plan."));
        }
        let mut mutations = Vec::new();
        for id in 1..=catalog.mutations {
            let mutation = self
                .storage
                .get::<Mutation>(&format!("recovery-mutation:{id}"))
                .await?
                .ok_or_else(unavailable)?;
            if mutation.id != id
                || !matches!(
                    mutation.outcome.as_str(),
                    "pending" | "applied" | "refused" | "uncertain"
                )
            {
                return Err(unavailable());
            }
            if mutation.source == source {
                mutations.push(mutation);
            }
        }
        let mut documents = Vec::new();
        let mut invalidated = Vec::new();
        for key in head_ids(&self.storage, &catalog).await? {
            let head = self
                .storage
                .get::<Head>(&format!("recovery-head:{key}"))
                .await?
                .ok_or_else(unavailable)?;
            if hash(&json!([head.source, head.path]).to_string()) != key {
                return Err(unavailable());
            }
            if head.source != source {
                continue;
            }
            if head.stamp.is_empty() {
                invalidated.push(json!({"document":head,"outcome":"unconfirmed-record-change"}));
                continue;
            }
            let inside =
                |root: &str| head.path == root || head.path.starts_with(&format!("{root}/"));
            let blocked = mutations
                .iter()
                .filter(|mutation| {
                    mutation.outcome != "refused"
                        && (inside(&mutation.path)
                            || mutation.to.as_ref().is_some_and(|to| inside(to)))
                        && (mutation.outcome != "applied" || mutation.revision > head.revision)
                })
                .max_by_key(|mutation| mutation.revision);
            if let Some(blocked) = blocked {
                invalidated.push(json!({"document":head,"mutation":blocked.id,"operation":blocked.operation,"outcome":blocked.outcome}));
            } else {
                documents.push(head);
            }
        }
        let payloads = crate::file_payloads::FilePayloads::info(&self.storage).await?;
        Ok(
            json!({"version":1,"source":source,"revision":catalog.revision,"scope":"confirmed-document-heads","automaticRestore":false,"requires":["complete-filesystem-state","external-change-reconciliation","compute-lease","stable-document-identities"],"documents":documents,"invalidated":invalidated,"mutations":mutations,"filesystemPayloads":payloads}),
        )
    }
}
