use super::*;

pub(crate) fn is_origin(env: &Env, url: &Url) -> bool {
    config(env, "ASSETS_ORIGIN")
        .and_then(|value| Url::parse(&value).ok())
        .is_some_and(|assets| assets.origin() == url.origin())
}

pub(crate) fn is_landing(env: &Env, url: &Url) -> bool {
    config(env, "LANDING_ORIGIN")
        .and_then(|value| Url::parse(&value).ok())
        .is_some_and(|landing| landing.origin() == url.origin())
}

const POINTER: &str = "editor-release.json";

fn release_path(key: &str) -> AppResult<Option<(&str, &str)>> {
    let Some(rest) = key.strip_prefix("releases/") else { return Ok(None); };
    let (release, file) = rest.split_once('/').ok_or_else(|| bad(404, "Editor asset not found."))?;
    if !opaque(release) || file.is_empty() { return Err(bad(404, "Editor asset not found.")); }
    Ok(Some((release, file)))
}

async fn current(bucket: &worker::Bucket) -> AppResult<Option<String>> {
    let Some(object) = bucket.get(POINTER).execute().await? else { return Ok(None); };
    if object.size() > 4096 { return Err(bad(503, "The editor release is invalid.")); }
    let bytes = object.body().ok_or_else(|| bad(503, "The editor release is unavailable."))?.bytes().await?;
    let pointer: Value = serde_json::from_slice(&bytes).map_err(|_| bad(503, "The editor release is invalid."))?;
    let release = pointer["release"].as_str().filter(|value| opaque(value))
        .filter(|_| pointer["version"] == 1).ok_or_else(|| bad(503, "The editor release is invalid."))?;
    let manifest = bucket.get(format!("releases/{release}/manifest.json")).execute().await?
        .ok_or_else(|| bad(503, "The editor release is incomplete."))?;
    if manifest.size() > 1024 * 1024 { return Err(bad(503, "The editor release is invalid.")); }
    let bytes = manifest.body().ok_or_else(|| bad(503, "The editor release is unavailable."))?.bytes().await?;
    let digest: String = Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect();
    if digest != release { return Err(bad(503, "The editor release manifest changed.")); }
    let manifest: Value = serde_json::from_slice(&bytes).map_err(|_| bad(503, "The editor release is invalid."))?;
    if manifest["version"] != 1 || !manifest["files"]["dist/index.html"].is_object() || !manifest["files"]["index.html"].is_object() {
        return Err(bad(503, "The editor release is incomplete."));
    }
    Ok(Some(release.into()))
}

fn isolated(headers: &Headers) -> AppResult<()> {
    headers.set("X-Content-Type-Options", "nosniff")?;
    headers.set("Cross-Origin-Resource-Policy", "cross-origin")?;
    headers.set("Cross-Origin-Opener-Policy", "same-origin")?;
    headers.set("Cross-Origin-Embedder-Policy", "require-corp")?;
    headers.set("Access-Control-Allow-Origin", "*")?;
    Ok(())
}

async fn entry(req: &Request, env: &Env, bucket: &worker::Bucket, release: &str, landing: bool) -> AppResult<Response> {
    let directory = if landing { "" } else { "dist/" };
    let key = format!("releases/{release}/{directory}index.html");
    let object = bucket.get(key).execute().await?.ok_or_else(|| bad(503, "The editor release is incomplete."))?;
    if object.size() > 1024 * 1024 { return Err(bad(503, "The editor page is too large.")); }
    let mut html = object.body().ok_or_else(|| bad(503, "The editor page is unavailable."))?.text().await?;
    let lower = html.to_ascii_lowercase();
    if lower.contains("<base") { return Err(bad(503, "The editor page already declares an asset base.")); }
    let at = if let Some(head) = lower.find("<head>") { head + 6 } else {
        lower.find("<html").and_then(|start| lower[start..].find('>').map(|end| start + end + 1))
            .ok_or_else(|| bad(503, "The editor page is invalid."))?
    };
    let prefix = format!("/releases/{release}/{directory}");
    // Pin relative assets without changing fragment links or the workspace document URL.
    html = html.replace("=\"./", &format!("=\"{prefix}")).replace("='./", &format!("='{prefix}"));
    let mut metadata = format!("<meta name=\"rayde-release\" content=\"{release}\">");
    if !landing {
        if let Some(origin) = preview_origin(env) {
            metadata.push_str(&format!("<meta name=\"rayde-preview-origin\" content=\"{}\">", origin.replace('&', "&amp;").replace('"', "&quot;").replace('<', "&lt;")));
        }
    }
    html.insert_str(at, &metadata);
    let headers = Headers::new();
    isolated(&headers)?;
    headers.set("Content-Type", "text/html; charset=utf-8")?;
    headers.set("Cache-Control", "no-store")?;
    headers.set("Content-Length", &html.len().to_string())?;
    headers.set("X-RayDE-Release", release)?;
    Ok(if req.method() == Method::Head { Response::empty()? } else { Response::from_html(html)? }.with_headers(headers))
}

fn pinned(req: &Request, release: &str, file: &str) -> AppResult<Response> {
    let mut url = req.url()?;
    url.set_path(&format!("/releases/{release}/{file}"));
    let mut response = Response::empty()?.with_status(307);
    let headers = response.headers_mut();
    headers.set("Location", url.as_str())?;
    headers.set("Cache-Control", "no-store")?;
    headers.set("X-RayDE-Release", release)?;
    isolated(headers)?;
    Ok(response)
}

pub(crate) async fn landing(req: &Request, env: &Env, path: &str) -> AppResult<Response> {
    if !matches!(req.method(), Method::Get | Method::Head) { return Err(bad(405, "Site assets only support GET and HEAD.")); }
    let key = path.trim_start_matches('/');
    if key.split('/').any(|part| part.starts_with('.') || part.contains('\\')) { return Err(bad(404, "Site asset not found.")); }
    if key.starts_with("releases/") {
        return get(req, env, path).await?.ok_or_else(|| bad(503, "Site asset storage is not configured."));
    }
    if key.starts_with("api/") || key.starts_with("auth/") { return Err(bad(404, "Not found.")); }
    let bucket = env.bucket("EDITOR_ASSETS").map_err(|_| bad(503, "Site asset storage is not configured."))?;
    let release = current(&bucket).await?.ok_or_else(|| bad(503, "No site release has been published."))?;
    if key.is_empty() || key == "index.html" { return entry(req, env, &bucket, &release, true).await; }
    let key = if key.ends_with('/') { format!("{key}index.html") } else { key.into() };
    pinned(req, &release, &key)
}

fn mime(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "wasm" => "application/wasm",
        "json" => "application/json",
        "css" => "text/css; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "webp" => "image/webp",
        "jpg" | "jpeg" => "image/jpeg",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "ttf" => "font/ttf",
        "ico" => "image/x-icon",
        _ => "application/octet-stream",
    }
}

// The public editor bundle has its own bucket, separate from private workspace payloads.
pub(crate) async fn get(req: &Request, env: &Env, path: &str) -> AppResult<Option<Response>> {
    if config(env, "LOCAL_DEV").as_deref() == Some("1")
        && config(env, "EDITOR_ASSETS_SOURCE").as_deref() == Some("origin")
    {
        return Ok(None);
    }
    let Ok(bucket) = env.bucket("EDITOR_ASSETS") else {
        return Ok(None);
    };
    if !matches!(req.method(), Method::Get | Method::Head) {
        return Err(bad(405, "Editor assets only support GET and HEAD."));
    }
    let key = path.trim_start_matches('/');
    let normalized = if key.is_empty() { "index.html".into() } else if key.ends_with('/') { format!("{key}index.html") } else { key.to_owned() };
    let key = normalized.as_str();
    if key
        .split('/')
        .any(|part| part.is_empty() || part.starts_with('.') || part.contains('\\'))
    {
        return Err(bad(404, "Editor asset not found."));
    }
    if key.starts_with("api/") || key.starts_with("auth/") { return Err(bad(404, "Editor asset not found.")); }
    let versioned = release_path(key)?;
    if let Some((release, file)) = versioned {
        if file == "index.html" || file == "dist/index.html" {
            return Ok(Some(entry(req, env, &bucket, release, file == "index.html").await?));
        }
    } else if key != POINTER && !key.starts_with("demo/") {
        if let Some(release) = current(&bucket).await? {
            if key == "index.html" { return Ok(Some(entry(req, env, &bucket, &release, false).await?)); }
            return Ok(Some(pinned(req, &release, &format!("dist/{key}"))?));
        }
    }
    let object = if req.method() == Method::Head {
        bucket.head(key).await?
    } else {
        bucket.get(key).execute().await?
    }
    .ok_or_else(|| bad(404, "Editor asset not found."))?;
    let headers = Headers::new();
    let metadata = object.http_metadata();
    let content_type = match mime(key) {
        "application/octet-stream" => metadata
            .content_type
            .as_deref()
            .unwrap_or("application/octet-stream"),
        known => known,
    };
    headers.set("Content-Type", content_type)?;
    if let Some(encoding) = metadata.content_encoding {
        headers.set("Content-Encoding", &encoding)?;
    }
    headers.set("ETag", &object.http_etag())?;
    let immutable=versioned.is_some() || key.strip_prefix("demo/").and_then(|rest|rest.split('/').next()).is_some_and(opaque);
    headers.set("Cache-Control", if immutable {"public, max-age=31536000, immutable"} else {"public, max-age=0, must-revalidate"})?;
    isolated(&headers)?;
    if let Some((release, _)) = versioned { headers.set("X-RayDE-Release", release)?; }
    let unchanged = req.headers().get("If-None-Match")?.is_some_and(|value| {
        value.split(',').any(|etag| {
            etag.trim() == "*" || etag.trim().trim_start_matches("W/") == object.http_etag()
        })
    });
    let response = if unchanged {
        Response::empty()?.with_status(304)
    } else {
        headers.set("Content-Length", &object.size().to_string())?;
        if req.method() == Method::Head {
            Response::empty()?
        } else {
            // Let the runtime forward R2 bytes without copying each chunk through WASM.
            Response::from_body(
                object
                    .body()
                    .ok_or_else(|| bad(503, "Editor asset is unavailable."))?
                    .response_body()?,
            )?
        }
    };
    Ok(Some(response.with_headers(headers)))
}
