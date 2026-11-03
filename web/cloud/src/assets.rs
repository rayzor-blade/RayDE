use super::*;

pub(crate) fn is_origin(env: &Env, url: &Url) -> bool {
    config(env, "ASSETS_ORIGIN")
        .and_then(|value| Url::parse(&value).ok())
        .is_some_and(|assets| assets.origin() == url.origin())
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
    let key = if key.is_empty() { "index.html" } else { key };
    if key
        .split('/')
        .any(|part| part.is_empty() || part.starts_with('.') || part.contains('\\'))
    {
        return Err(bad(404, "Editor asset not found."));
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
    headers.set("Cache-Control", "public, max-age=0, must-revalidate")?;
    headers.set("X-Content-Type-Options", "nosniff")?;
    headers.set("Cross-Origin-Resource-Policy", "cross-origin")?;
    headers.set("Cross-Origin-Opener-Policy", "same-origin")?;
    headers.set("Cross-Origin-Embedder-Policy", "require-corp")?;
    headers.set("Access-Control-Allow-Origin", "*")?;
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
            Response::from_stream(
                object
                    .body()
                    .ok_or_else(|| bad(503, "Editor asset is unavailable."))?
                    .stream()?,
            )?
        }
    };
    Ok(Some(response.with_headers(headers)))
}
