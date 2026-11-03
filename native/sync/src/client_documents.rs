//! Transport for shared cloud document histories; callers schedule I/O away from the UI thread.
use super::*;
use crate::live::{self, Seed};
use base64::{Engine, engine::general_purpose::STANDARD as B64};

#[derive(Deserialize)]
struct Wire {
    seed: Seed,
    lineage: String,
    sequence: u64,
    vector: String,
    update: String,
    sha256: String,
    anchor: String,
}
pub struct Reply {
    pub seed: Seed,
    pub sequence: u64,
    pub vector: Vec<u8>,
    pub update: Vec<u8>,
    pub sha256: String,
    pub anchor: String,
}
fn invalid() -> Failure {
    Failure::new("protocol", "The shared document response is invalid.")
}
fn decode(value: &str, limit: usize) -> Result<Vec<u8>, Failure> {
    if value.len() > limit.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let bytes = B64.decode(value).map_err(|_| invalid())?;
    if bytes.len() > limit {
        return Err(invalid());
    }
    Ok(bytes)
}
fn request(config: &Config, path: &str, op: &str, body: Value) -> Result<Reply, Failure> {
    let (gateway, workspace) = connection(config)?;
    WorkspaceId::parse(&workspace).map_err(|_| invalid())?;
    if crate::manifest::path_problem(path, &crate::lifecycle::Limits::default()).is_some()
        || path.is_empty()
    {
        return Err(Failure::new("path", "Choose a workspace file."));
    }
    let bytes = gateway.call_limited(
        "POST",
        &format!("/workspaces/{workspace}/documents/{op}"),
        Some(&serde_json::to_vec(&body).unwrap()),
        Some(live::MAX_STATE.div_ceil(3)*4+128*1024),
    )?;
    if bytes.len() > live::MAX_STATE.div_ceil(3) * 4 + 128 * 1024 {
        return Err(invalid());
    }
    let wire: Wire = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    wire.seed.validate().map_err(|_| invalid())?;
    if wire.seed.workspace != workspace
        || wire.seed.path != path
        || wire.lineage != wire.seed.lineage
        || wire.sequence == 0
        || [&wire.sha256, &wire.anchor].iter().any(|s| {
            s.len() != 64
                || !s
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
    {
        return Err(invalid());
    }
    Ok(Reply {
        seed: wire.seed,
        sequence: wire.sequence,
        vector: decode(&wire.vector, live::MAX_VECTOR)?,
        update: decode(&wire.update, live::MAX_STATE)?,
        sha256: wire.sha256,
        anchor: wire.anchor,
    })
}
fn connection(config:&Config)->Result<(Gateway,String),Failure>{
    let (mut gateway,workspace)=existing_workspace(config)?;
    WorkspaceId::parse(&workspace).map_err(|_|invalid())?;
    gateway.agent=ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(5)).timeout(Duration::from_secs(15)).build();
    Ok((gateway,workspace))
}
pub fn manifest(config:&Config)->Result<Manifest,Failure>{
    let (gateway,workspace)=connection(config)?;
    Manifest::from_bytes(&gateway.call_limited("GET",&format!("/workspaces/{workspace}/export/manifest"),None,Some(16*1024*1024))?).map_err(|_|invalid())
}
pub fn open(config: &Config, path: &str, generation: u64) -> Result<Reply, Failure> {
    let reply = request(
        config,
        path,
        "open",
        json!({"path":path,"generation":generation}),
    )?;
    let document = live::Document::restore(reply.seed.clone(), &[reply.update.clone()])
        .map_err(|_| invalid())?;
    if !live::same_vector(&document.vector(), &reply.vector).map_err(|_| invalid())?
        || sha256_hex(document.text().as_bytes()) != reply.sha256
    {
        return Err(invalid());
    }
    Ok(reply)
}
pub fn exchange(
    config: &Config,
    seed: &Seed,
    from: &[u8],
    update: &[u8],
) -> Result<Reply, Failure> {
    if update.len() > live::MAX_STATE || from.len() > live::MAX_VECTOR {
        return Err(invalid());
    }
    let reply = request(
        config,
        &seed.path,
        "exchange",
        json!({"path":seed.path,"lineage":seed.lineage,"from":B64.encode(from),"update":B64.encode(update)}),
    )?;
    if reply.seed != *seed {
        return Err(Failure::new(
            "document-lineage",
            "The cloud document belongs to another history. Reopen it before exchanging edits.",
        ));
    }
    Ok(reply)
}
