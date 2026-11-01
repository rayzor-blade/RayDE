//! Restores a Cloud Sync snapshot into a workspace's project directory: the manifest and chunks come from the gateway's runner routes, every chunk is
//! checked against its size and SHA-256 before it is written, and nothing is written outside the project directory.
use super::*;
use rayde_sync::{
    chunk::sha256_hex,
    lifecycle::Limits,
    manifest::{FileKind, Manifest},
};
use std::path::Component;

const MAX_BYTES: u64 = 64 * 1024 * 1024;
const MAX_FILES: usize = 10000;
const MAX_MANIFEST: usize = 16 * 1024 * 1024;
const MAX_CHUNK: usize = 8 * 1024 * 1024;

fn refused(message: &'static str) -> Failure {
    Failure(StatusCode::UNPROCESSABLE_ENTITY, message)
}

/// One GET to the gateway as the runner, with the body bounded so a hostile or broken gateway cannot fill memory.
async fn fetch(config: &Config, http: &reqwest::Client, path: &str, limit: usize) -> Result<Vec<u8>> {
    let gateway = config.sync_gateway.as_ref().ok_or_else(unavailable)?;
    let mut response = http
        .get(format!("{}/api/sync/runner/{path}", gateway.url.trim_end_matches('/')))
        .bearer_auth(&gateway.secret)
        .send()
        .await
        .map_err(|_| unavailable())?;
    if !response.status().is_success() {
        return Err(unavailable());
    }
    let mut bytes = Vec::new();
    while let Some(part) = response.chunk().await.map_err(|_| unavailable())? {
        if bytes.len() + part.len() > limit {
            return Err(Failure(StatusCode::PAYLOAD_TOO_LARGE, "The snapshot exceeds the restore limit."));
        }
        bytes.extend_from_slice(&part);
    }
    Ok(bytes)
}

/// A relative path of plain components that names nothing inside a `.git` directory.
fn safe(path: &str) -> bool {
    let path = Path::new(path);
    !path.as_os_str().is_empty()
        && path.as_os_str().len() <= 4096
        && path.components().all(|part| matches!(part, Component::Normal(_)))
        && !path.components().any(|part| part.as_os_str().as_encoded_bytes().eq_ignore_ascii_case(b".git"))
}

/// Returns the project directory and the generation it is a copy of.
pub(crate) async fn restore(config: &Config, http: &reqwest::Client, root: &Path, request: &Open) -> Result<(PathBuf, u64)> {
    if tokio::fs::try_exists(root).await? {
        tokio::fs::remove_dir_all(root).await?;
    }
    private_dir(root).await?;
    let id = &request.id;
    let manifest = Manifest::from_bytes(&fetch(config, http, &format!("{id}/manifest"), MAX_MANIFEST).await?)
        .map_err(|_| refused("The snapshot manifest is not readable."))?;
    if manifest.workspace.as_str() != id
        || !manifest.validate(&Limits::for_allocation(MAX_BYTES)).is_empty()
        || manifest.files.len() > MAX_FILES
        || manifest.files.iter().try_fold(0u64, |total, file| total.checked_add(file.size)).is_none_or(|total| total > MAX_BYTES)
    {
        return Err(refused("The snapshot does not match this workspace or exceeds the restore limit."));
    }
    let project = root.join("project");
    tokio::fs::create_dir(&project).await?;
    for file in &manifest.files {
        if !safe(&file.path) {
            return Err(refused("The snapshot contains an unsupported path."));
        }
        let target = project.join(&file.path);
        if let Some(parent) = target.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        match file.kind {
            FileKind::Symlink => {
                // The manifest check keeps the target relative and inside the tree; the link is never followed here.
                #[cfg(unix)]
                tokio::fs::symlink(file.link.as_deref().ok_or_else(|| refused("The snapshot has a link with no target."))?, &target).await?;
                #[cfg(not(unix))]
                return Err(refused("The snapshot contains a link this host cannot restore."));
            }
            FileKind::Regular | FileKind::Executable => {
                let mut content = Vec::with_capacity(file.size as usize);
                for chunk in &file.chunks {
                    let bytes = fetch(config, http, &format!("{id}/chunks/{}", chunk.hash), MAX_CHUNK).await?;
                    if bytes.len() != chunk.size as usize || sha256_hex(&bytes) != chunk.hash {
                        return Err(refused("A snapshot chunk failed its check."));
                    }
                    content.extend_from_slice(&bytes);
                }
                if content.len() as u64 != file.size || sha256_hex(&content) != file.hash {
                    return Err(refused("A snapshot file failed its check."));
                }
                let mut output = tokio::fs::OpenOptions::new().create_new(true).write(true).open(&target).await?;
                tokio::io::AsyncWriteExt::write_all(&mut output, &content).await?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let mode = if file.kind == FileKind::Executable { 0o755 } else { 0o644 };
                    output.set_permissions(std::fs::Permissions::from_mode(mode)).await?;
                }
            }
        }
    }
    Ok((project, manifest.generation))
}
