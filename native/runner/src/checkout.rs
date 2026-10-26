use super::*;
use base64::engine::general_purpose::STANDARD;
use std::{path::Component, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
};

const MAX_BYTES: u64 = 64 * 1024 * 1024;
const MAX_ARCHIVE: u64 = MAX_BYTES + 16 * 1024 * 1024;
const MAX_FILES: usize = 10000;

fn git(root: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", root)
        .env("LANG", "C")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_ATTR_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0");
    command.args([
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "credential.helper=",
        "-c",
        "http.followRedirects=false",
        "-c",
        "http.lowSpeedLimit=1024",
        "-c",
        "http.lowSpeedTime=15",
    ]);
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            let limit = libc::rlimit {
                rlim_cur: MAX_ARCHIVE,
                rlim_max: MAX_ARCHIVE,
            };
            if libc::setrlimit(libc::RLIMIT_FSIZE, &limit) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command
}

pub(crate) async fn authorize(
    config: &Config,
    request: &Open,
    http: &reqwest::Client,
) -> Result<Option<PathBuf>> {
    if let Some(source) = config
        .local_repositories
        .iter()
        .find(|repo| repo.owner == request.owner && repo.repository == request.repository.id)
    {
        return Ok(Some(tokio::fs::canonicalize(&source.path).await?));
    }
    if request.checkout.access_token.is_empty()
        || request.checkout.access_token.len() > 4096
        || request.checkout.access_token.contains(['\r', '\n', '\0'])
    {
        return Err(invalid());
    }
    async fn api(http: &reqwest::Client, token: &str, path: &str) -> Result<serde_json::Value> {
        let mut response = http
            .get(format!("https://api.github.com{path}"))
            .bearer_auth(token)
            .header("User-Agent", "RayDE-runner")
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .map_err(|_| unavailable())?;
        if !response.status().is_success() {
            return Err(Failure(
                StatusCode::FORBIDDEN,
                "Repository access could not be verified.",
            ));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
            if bytes.len() + chunk.len() > 64 * 1024 {
                return Err(unavailable());
            }
            bytes.extend(chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| unavailable())
    }
    let user = api(http, &request.checkout.access_token, "/user").await?;
    let repo = api(
        http,
        &request.checkout.access_token,
        &format!("/repos/{}", request.repository.full_name),
    )
    .await?;
    if user["id"] != request.owner
        || repo["id"] != request.repository.id
        || repo["full_name"] != request.repository.full_name
        || repo["clone_url"] != request.repository.clone_url
        || repo["default_branch"] != request.repository.branch
        || repo["permissions"]["pull"] != true
    {
        return Err(Failure(
            StatusCode::FORBIDDEN,
            "Repository access does not match this workspace.",
        ));
    }
    Ok(None)
}

/// Bare clone and bounded archive extraction never run repository hooks, filters or project programs on the host.
pub(crate) async fn prepare(
    root: &Path,
    request: &Open,
    local: Option<PathBuf>,
    work: Option<std::sync::Arc<crate::registry::Work>>,
) -> Result<PathBuf> {
    if tokio::fs::try_exists(root).await? {
        tokio::fs::remove_dir_all(root).await?;
    }
    private_dir(root).await?;
    let (bare, project, archive) = (
        root.join("bare"),
        root.join("project"),
        root.join("checkout.tar"),
    );
    let mut clone = git(root);
    if local.is_some() {
        clone.args(["-c", "protocol.file.allow=always"]);
    } else {
        clone
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader")
            .env(
                "GIT_CONFIG_VALUE_0",
                format!(
                    "Authorization: Basic {}",
                    STANDARD.encode(format!("x-access-token:{}", request.checkout.access_token))
                ),
            );
    }
    clone.args([
        "clone",
        "--bare",
        "--depth=1",
        "--single-branch",
        "--template=",
        "--no-local",
        "--branch",
        &request.repository.branch,
        "--",
    ]);
    clone
        .arg(local.unwrap_or_else(|| PathBuf::from(&request.repository.clone_url)))
        .arg(&bare);
    command::capture(clone, 90).await?;
    tokio::fs::create_dir_all(bare.join("info")).await?;
    tokio::fs::write(
        bare.join("info/attributes"),
        b"* -export-ignore -export-subst\n",
    )
    .await?;
    let mut export = git(root);
    export
        .arg("--git-dir")
        .arg(&bare)
        .args(["archive", "--format=tar", "HEAD"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut process = command::Process::new(export)?;
    let mut stdout = process
        .child
        .stdout
        .take()
        .ok_or_else(unavailable)?
        .take(MAX_ARCHIVE + 1);
    let mut file = tokio::fs::File::create(&archive).await?;
    let copied = tokio::time::timeout(
        Duration::from_secs(30),
        tokio::io::copy(&mut stdout, &mut file),
    )
    .await
    .map_err(|_| unavailable())??;
    file.flush().await?;
    drop(file);
    if copied > MAX_ARCHIVE {
        return Err(Failure(
            StatusCode::PAYLOAD_TOO_LARGE,
            "The repository exceeds the checkout limit.",
        ));
    }
    tokio::time::timeout(Duration::from_secs(5), process.finish())
        .await
        .map_err(|_| unavailable())??;
    let (archive_, project_) = (archive.clone(), project.clone());
    tokio::task::spawn_blocking(move || {
        let result = extract(&archive_, &project_);
        drop(work);
        result
    })
    .await
    .map_err(|_| unavailable())??;
    tokio::fs::rename(&bare, project.join(".git")).await?;
    for args in [
        vec!["config", "core.bare", "false"],
        vec![
            "config",
            "remote.origin.url",
            request.repository.clone_url.as_str(),
        ],
        vec!["read-tree", "HEAD"],
    ] {
        let mut config = git(root);
        config
            .arg("--git-dir")
            .arg(project.join(".git"))
            .arg("--work-tree")
            .arg(&project)
            .args(args);
        command::capture(config, 10).await?;
    }
    Ok(project)
}

fn extract(archive: &Path, root: &Path) -> Result<()> {
    std::fs::create_dir(root)?;
    let mut input = tar::Archive::new(std::fs::File::open(archive)?);
    let (mut bytes, mut files) = (0u64, 0usize);
    for entry in input.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();
        let kind = entry.header().entry_type();
        if kind.is_pax_global_extensions() {
            if entry.size() > 4096 {
                return Err(invalid());
            }
            continue;
        }
        files += 1;
        if files > MAX_FILES
            || path.as_os_str().len() > 4096
            || path
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
            || path.components().any(|part| {
                part.as_os_str()
                    .as_encoded_bytes()
                    .eq_ignore_ascii_case(b".git")
            })
            || (!kind.is_file() && !kind.is_dir())
        {
            return Err(Failure(
                StatusCode::UNPROCESSABLE_ENTITY,
                "The repository contains an unsupported filesystem entry.",
            ));
        }
        bytes = bytes.checked_add(entry.size()).ok_or_else(invalid)?;
        if bytes > MAX_BYTES {
            return Err(Failure(
                StatusCode::PAYLOAD_TOO_LARGE,
                "The repository exceeds the checkout limit.",
            ));
        }
        let target = root.join(path);
        if kind.is_dir() {
            std::fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut output = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&target)?;
        std::io::copy(&mut entry, &mut output)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = if entry.header().mode()? & 0o111 != 0 {
                0o755
            } else {
                0o644
            };
            output.set_permissions(std::fs::Permissions::from_mode(mode))?;
        }
    }
    Ok(())
}
