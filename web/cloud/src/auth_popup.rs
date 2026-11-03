use super::*;

pub(crate) fn completion(channel: &str, succeeded: bool) -> AppResult<Response> {
    if !opaque(channel) {
        return Err(bad(400, "Invalid sign-in window."));
    }
    let nonce = random()?;
    let status = if succeeded { "success" } else { "failed" };
    let script = format!(
        "const channel = '{channel}'; const status = '{status}';\n{}",
        include_str!("auth_popup.js")
    );
    let message = if succeeded {
        "Signed in. You can close this window."
    } else {
        "Sign-in was not completed. Return to the editor to try again."
    };
    let mut response = Response::from_html(format!(
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>RayDE sign-in</title><body><p>{message}</p><script nonce=\"{nonce}\">{script}</script></body></html>"
    ))?;
    for (name, value) in [
        ("Cache-Control", "no-store".to_string()),
        ("Referrer-Policy", "no-referrer".to_string()),
        ("Cross-Origin-Opener-Policy", "same-origin".to_string()),
        ("Cross-Origin-Embedder-Policy", "require-corp".to_string()),
        (
            "Content-Security-Policy",
            format!(
                "default-src 'none'; script-src 'nonce-{nonce}'; base-uri 'none'; frame-ancestors 'none'"
            ),
        ),
    ] {
        response.headers_mut().set(name, &value)?;
    }
    Ok(response)
}

pub(crate) async fn account(env: &Env, url: &Url, flow: &Value, code: &str) -> AppResult<String> {
    let mut exchange = request(
        "https://github.com/login/oauth/access_token",
        &json!({"client_id":config(env,"GITHUB_CLIENT_ID"),"client_secret":config(env,"GITHUB_CLIENT_SECRET"),"code":code,"redirect_uri":format!("{}/auth/github/callback",url.origin().ascii_serialization()),"code_verifier":flow["verifier"]}),
    )?;
    exchange.headers_mut()?.set("Accept", "application/json")?;
    let mut response = github(env, exchange).await?;
    let result: Value = response.json().await?;
    if response.status_code() >= 400 || result["access_token"].as_str().is_none() {
        return Err(bad(401, "GitHub sign-in failed."));
    }
    let user = api(env, text(&result, "access_token")?, "/user").await?;
    if user["id"].as_u64().is_none() || user["login"].as_str().is_none() {
        return Err(bad(502, "GitHub returned an invalid account."));
    }
    let sid = random()?;
    rpc(env,"ACCOUNTS",&sid,"put",&json!({"kind":"account","user":{"id":user["id"],"login":user["login"],"avatarUrl":user["avatar_url"]},"csrf":random()?,"expires":now()+7*DAY,"tokens":{"access":result["access_token"],"refresh":result["refresh_token"],"expires":result["expires_in"].as_u64().map(|s|now()+s*1000)}})).await?;
    Ok(sid)
}
