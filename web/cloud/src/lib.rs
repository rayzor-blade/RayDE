mod account;
mod assets;
mod demo;
mod demo_container;
mod auth_popup;
mod projects;
mod workspace;
mod checkpoints;
mod journal;
mod recovery;
mod file_payloads;
mod sync;
mod sync_documents;
mod sync_watch;
pub use account::AccountSession;
pub use workspace::{WorkspaceSession,DemoWorkspaceSession};
pub use demo::DemoAdmissions;
pub use demo_container::DemoContainer;

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use worker::*;

const DAY: u64 = 86_400_000;
type AppResult<T> = std::result::Result<T, Failure>;
#[derive(Debug)]
struct Failure {
    status: u16,
    message: String,
}
impl From<worker::Error> for Failure {
    fn from(_: worker::Error) -> Self {
        bad(503, "The workspace service is unavailable. Try again.")
    }
}
fn bad(status: u16, message: &str) -> Failure {
    Failure {
        status,
        message: message.into(),
    }
}
fn now() -> u64 {
    Date::now().as_millis()
}
fn config(env: &Env, key: &str) -> Option<String> {
    env.secret(key)
        .map(|v| v.to_string())
        .or_else(|_| env.var(key).map(|v| v.to_string()))
        .ok()
}
fn random() -> AppResult<String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|_| bad(500, "Sign-in could not be prepared."))?;
    Ok(bytes.iter().map(|v| format!("{v:02x}")).collect())
}
fn hash(value: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(value.as_bytes()))
}
fn opaque(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn text<'a>(value: &'a Value, key: &str) -> AppResult<&'a str> {
    value[key]
        .as_str()
        .ok_or_else(|| bad(400, "The request is incomplete."))
}
fn cookie_value(req: &Request, name: &str) -> Option<String> {
    req.headers()
        .get("Cookie")
        .ok()
        .flatten()?
        .split(';')
        .map(str::trim)
        .find_map(|s| s.strip_prefix(&format!("{name}=")).map(str::to_owned))
}
fn cookie(name: &str, value: &str, url: &Url, age: u64) -> String {
    format!(
        "{name}={value}; HttpOnly; SameSite=Lax; Path=/; Max-Age={age}{}",
        if url.scheme() == "https" {
            "; Secure"
        } else {
            ""
        }
    )
}
fn reply(value: &Value, status: u16) -> Result<Response> {
    let mut r = Response::from_json(value)?.with_status(status);
    r.headers_mut().set("Cache-Control", "no-store")?;
    Ok(r)
}
fn redirect_response(url: Url) -> AppResult<Response> {
    let mut response = Response::empty()?.with_status(302);
    response.headers_mut().set("Location", url.as_str())?;
    response.headers_mut().set("Cache-Control", "no-store")?;
    Ok(response)
}
fn finish(result: AppResult<Response>) -> Result<Response> {
    match result {
        Ok(r) => Ok(r),
        Err(e) => reply(&json!({"message":e.message}), e.status),
    }
}
fn request(url: &str, data: &Value) -> AppResult<Request> {
    let headers = Headers::new();
    headers.set("Content-Type", "application/json")?;
    Ok(Request::new_with_init(
        url,
        RequestInit::new()
            .with_method(Method::Post)
            .with_headers(headers)
            .with_body(Some(data.to_string().into())),
    )?)
}
async fn rpc(env: &Env, namespace: &str, id: &str, op: &str, data: &Value) -> AppResult<Value> {
    let stub = env.durable_object(namespace)?.get_by_name(id)?;
    let mut response = stub
        .fetch_with_request(request(&format!("https://internal/{op}"), data)?)
        .await?;
    let status = response.status_code();
    let body: Value = response.json().await?;
    if status >= 400 {
        return Err(bad(
            status,
            body["message"].as_str().unwrap_or("The request failed."),
        ));
    }
    Ok(body)
}
async fn github(env: &Env, req: Request) -> AppResult<Response> {
    Ok(if let Ok(binding) = env.service("GITHUB") {
        binding.fetch_request(req).await?
    } else {
        Fetch::Request(req).send().await?
    })
}
async fn api(env: &Env, token: &str, path: &str) -> AppResult<Value> {
    let headers = Headers::new();
    headers.set("Authorization", &format!("Bearer {token}"))?;
    headers.set("Accept", "application/vnd.github+json")?;
    headers.set("User-Agent", "RayDE")?;
    headers.set("X-GitHub-Api-Version", "2022-11-28")?;
    let mut response = github(
        env,
        Request::new_with_init(
            &format!("https://api.github.com{path}"),
            RequestInit::new().with_headers(headers),
        )?,
    )
    .await?;
    if response.status_code() >= 400 {
        return Err(bad(
            if response.status_code() == 401 {
                401
            } else {
                403
            },
            "Sign in again or grant RayDE access to this repository.",
        ));
    }
    Ok(response.json().await?)
}
async fn auth(req: &Request, env: &Env) -> AppResult<(String, Value)> {
    let sid = cookie_value(req, "rayde_session")
        .filter(|s| opaque(s))
        .ok_or_else(|| bad(401, "Sign in with GitHub to continue."))?;
    let session = rpc(env, "ACCOUNTS", &sid, "get", &json!({})).await?;
    Ok((sid, session))
}
fn workspace_id(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
fn public_workspace(value: &Value) -> Value {
    json!({"id":value["id"],"repository":value["repository"],"status":value["status"],"message":value["message"],"project":value["connection"]["project"]})
}

fn preview_origin(env:&Env)->Option<String> {
    let configured=config(env,"PREVIEW_ORIGIN");
    let local=config(env,"LOCAL_DEV").as_deref()==Some("1");
    let app=Url::parse(&config(env,"APP_ORIGIN")?).ok()?;
    let mut preview=if let Some(value)=configured {Url::parse(&value).ok()?}else if local {
        let mut preview=app.clone();preview.set_host(Some(if app.host_str()==Some("localhost"){"127.0.0.1"}else{"localhost"})).ok()?;preview
    }else{return None;};
    if !matches!(preview.scheme(),"http"|"https") || preview.origin()==app.origin() || (!local && preview.scheme()!="https") || !preview.username().is_empty() || preview.password().is_some(){return None;}
    preview.set_path("");preview.set_query(None);preview.set_fragment(None);
    Some(preview.origin().ascii_serialization())
}

#[event(fetch)]
pub async fn main(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    finish(route(req, env).await)
}
async fn route(mut req: Request, env: Env) -> AppResult<Response> {
    let url = req.url()?;
    let origin = config(&env, "APP_ORIGIN").unwrap_or_else(|| url.origin().ascii_serialization());
    let path = url.path().to_string();
    if path.starts_with("/api/demo/") {return demo::route(req,env).await;}
    if assets::is_landing(&env, &url) {
        return assets::landing(&req, &env, &path).await;
    }
    if preview_origin(&env).is_some_and(|origin|url.origin().ascii_serialization()==origin) {
        if req.method()!=Method::Get {return Err(bad(404,"This app preview is unavailable."));}
        let demo=path.strip_prefix("/dist").unwrap_or(&path);
        if let Some(rest) = path.strip_prefix("/releases/") {
            let parts: Vec<_> = rest.splitn(5, '/').collect();
            if parts.len() == 5 && opaque(parts[0]) && parts[1] == "dist" && parts[2] == "demo" && opaque(parts[3]) {
                return assets::get(&req, &env, &path).await?.ok_or_else(|| bad(404, "This demo preview is unavailable."));
            }
        }
        if let Some(rest)=demo.strip_prefix("/demo/") {
            if rest.split('/').next().is_some_and(opaque) {
                return assets::get(&req,&env,demo).await?.ok_or_else(||bad(404,"This demo preview is unavailable."));
            }
        }
        let (namespace,rest)=if let Some(rest)=path.strip_prefix("/demo-previews/") {("DEMO_WORKSPACES",rest)}else{("WORKSPACES",path.strip_prefix("/previews/").unwrap_or(""))};
        let parts=rest.splitn(3,'/').collect::<Vec<_>>();
        if parts.len()!=3 || !workspace_id(parts[0]) || !opaque(parts[1]) {return Err(bad(404,"This app preview is unavailable."));}
        let namespace=env.durable_object(namespace)?;
        let stub=namespace.id_from_name(parts[0])?.get_stub()?;
        return Ok(stub.fetch_with_request(Request::new(&format!("https://workspace/preview/{}/{}",parts[1],parts[2]),Method::Get)?).await?);
    }
    if path.starts_with("/previews/") || path.starts_with("/demo-previews/"){return Err(bad(404,"This app preview is unavailable."));}
    if assets::is_origin(&env,&url){
        return assets::get(&req,&env,&path).await?.ok_or_else(||bad(503,"Editor asset storage is not configured."));
    }
    if url.scheme() != "https" && config(&env, "LOCAL_DEV").as_deref() != Some("1") {
        return Err(bad(400, "HTTPS is required."));
    }
    if path.starts_with("/api/") && req.headers().get("Origin")?.is_some_and(|v| v != origin) {
        return Err(bad(403, "This request is not allowed."));
    }
    let query = |key: &str| {
        url.query_pairs()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.into_owned())
    };
    if path.starts_with("/auth/") && url.origin().ascii_serialization() != origin {
        let mut destination =
            Url::parse(&origin).map_err(|_| bad(503, "Sign-in is not configured."))?;
        destination.set_path(&path);
        destination.set_query(url.query());
        return redirect_response(destination);
    }
    let workspace_page = path.strip_prefix('/').filter(|id| workspace_id(id));
    if let Some(id) = workspace_page {
        if url.origin().ascii_serialization() != origin {
            let mut destination =
                Url::parse(&origin).map_err(|_| bad(503, "The editor is not configured."))?;
            destination.set_path(&path);
            return redirect_response(destination);
        }
        let (_, session) = match auth(&req, &env).await {
            Ok(account) => account,
            // A gateway running on this machine has no GitHub App, so its configured development account is signed in instead.
            Err(error) if error.status == 401 && config(&env, "LOCAL_DEV").as_deref() == Some("1") && config(&env, "DEV_ACCOUNT").is_some() => {
                let mut destination = Url::parse(&format!("{origin}/auth/dev"))
                    .map_err(|_| bad(503, "Sign-in is not configured."))?;
                destination.query_pairs_mut().append_pair("account", &config(&env, "DEV_ACCOUNT").unwrap_or_default()).append_pair("return", &path);
                return redirect_response(destination);
            }
            Err(error) if error.status == 401 => {
                let mut destination = Url::parse(&format!("{origin}/auth/github/start"))
                    .map_err(|_| bad(503, "Sign-in is not configured."))?;
                destination.query_pairs_mut().append_pair("workspace", id);
                return redirect_response(destination);
            }
            Err(error) => return Err(error),
        };
        let state = json!({"owner":session["user"]["id"]});
        match rpc(&env, "WORKSPACES", id, "state", &state).await {
            // A synced workspace's link works as soon as it is published: its owner visiting it makes the browser workspace.
            Err(error) if error.status == 404 => {
                if sync::open_synced(&env, &sync::session_owner(&env, &session), id, &origin).await.is_err() {
                    return Err(error);
                }
                rpc(&env, "WORKSPACES", id, "state", &state).await?;
            }
            other => {
                other?;
            }
        }
    }
    // Sign-in for a gateway running on this machine, where there is no GitHub App: `/auth/dev?account=NAME&return=/ID`.
    if path == "/auth/dev" && config(&env, "LOCAL_DEV").as_deref() == Some("1") {
        let popup = query("popup");
        if popup.as_ref().is_some_and(|value| !opaque(value)) { return Err(bad(400, "Invalid sign-in window.")); }
        let name = query("account").filter(|n| rayde_sync::ids::AccountId::parse(&format!("dev:{n}")).is_ok()).ok_or_else(|| bad(400, "That development account name is not valid."))?;
        let sid = random()?;
        rpc(&env, "ACCOUNTS", &sid, "put", &json!({"kind":"account","user":{"id":sync::dev_user_id(&name),"login":name,"avatarUrl":Value::Null},"csrf":random()?,"expires":now()+7*DAY,"tokens":{"access":"","refresh":Value::Null,"expires":Value::Null}})).await?;
        let destination = Url::parse(&origin).map_err(|_| bad(503, "Sign-in is not configured."))?;
        let back = query("return").filter(|r| r.starts_with('/') && !r.starts_with("//")).unwrap_or_else(|| "/".into());
        let destination = destination.join(&back).map_err(|_| bad(400, "That return path is not valid."))?;
        let mut response = if let Some(channel) = popup { auth_popup::completion(&channel, true)? } else { redirect_response(destination)? };
        response.headers_mut().append("Set-Cookie", &cookie("rayde_session", &sid, &url, 7 * 86400))?;
        return Ok(response);
    }
    if path == "/auth/github/start" && config(&env, "LOCAL_DEV").as_deref() == Some("1") && config(&env, "DEV_ACCOUNT").is_some() {
        let mut destination = Url::parse(&format!("{origin}/auth/dev")).map_err(|_| bad(503, "Sign-in is not configured."))?;
        let back = query("workspace").filter(|id| workspace_id(id)).map(|id| format!("/{id}")).unwrap_or_else(|| "/?repositories=1".into());
        destination.query_pairs_mut().append_pair("account", &config(&env, "DEV_ACCOUNT").unwrap_or_default()).append_pair("return", &back);
        if let Some(channel) = query("popup") {
            if !opaque(&channel) { return Err(bad(400, "Invalid sign-in window.")); }
            destination.query_pairs_mut().append_pair("popup", &channel);
        }
        return redirect_response(destination);
    }
    if path == "/auth/github/start" {
        let popup = query("popup");
        if popup.as_ref().is_some_and(|value| !opaque(value)) { return Err(bad(400, "Invalid sign-in window.")); }
        let client = config(&env, "GITHUB_CLIENT_ID")
            .ok_or_else(|| bad(503, "GitHub sign-in is not configured."))?;
        if config(&env, "GITHUB_CLIENT_SECRET").is_none() {
            return Err(bad(503, "GitHub sign-in is not configured."));
        }
        let state = random()?;
        let secret = random()?;
        let verifier = random()?;
        let mut destination =
            Url::parse(&origin).map_err(|_| bad(503, "Sign-in is not configured."))?;
        if let Some(id) = query("workspace") {
            if !workspace_id(&id) {
                return Err(bad(400, "Choose a repository workspace."));
            }
            destination.set_path(&format!("/{id}"));
        } else {
            destination
                .query_pairs_mut()
                .append_pair("repositories", "1");
        }
        rpc(&env,"ACCOUNTS",&state,"put",&json!({"kind":"oauth","cookieHash":hash(&secret),"verifier":verifier,"returnTo":destination.as_str(),"popup":popup,"expires":now()+600000})).await?;
        let mut redirect = Url::parse("https://github.com/login/oauth/authorize").unwrap();
        for (k, v) in [
            ("client_id", client),
            (
                "redirect_uri",
                format!(
                    "{}/auth/github/callback",
                    url.origin().ascii_serialization()
                ),
            ),
            ("state", state),
            ("code_challenge", hash(&verifier)),
            ("code_challenge_method", "S256".into()),
        ] {
            redirect.query_pairs_mut().append_pair(k, &v);
        }
        let mut response = redirect_response(redirect)?;
        response
            .headers_mut()
            .set("Set-Cookie", &cookie("rayde_oauth", &secret, &url, 600))?;
        return Ok(response);
    }
    if path == "/auth/github/callback" {
        let state = query("state")
            .filter(|s| opaque(s))
            .ok_or_else(|| bad(403, "The sign-in request could not be verified."))?;
        let secret = cookie_value(&req, "rayde_oauth")
            .ok_or_else(|| bad(403, "The sign-in request could not be verified."))?;
        let flow = rpc(
            &env,
            "ACCOUNTS",
            &state,
            "consume",
            &json!({"cookieHash":hash(&secret)}),
        )
        .await?;
        let popup = flow["popup"].as_str().filter(|value| opaque(value));
        let account = async {
            let code = query("code")
                .filter(|_| query("error").is_none())
                .ok_or_else(|| bad(400, "GitHub sign-in was cancelled."))?;
            auth_popup::account(&env, &url, &flow, &code).await
        }.await;
        let mut response = match account {
            Ok(sid) => {
                let mut response = if let Some(channel) = popup { auth_popup::completion(channel, true)? }
                    else { redirect_response(Url::parse(text(&flow, "returnTo")?).map_err(|_| bad(400, "Invalid sign-in return address."))?)? };
                response.headers_mut().append("Set-Cookie", &cookie("rayde_session", &sid, &url, 7 * 86400))?;
                response
            }
            Err(_) if popup.is_some() => auth_popup::completion(popup.unwrap(), false)?,
            Err(error) => return Err(error),
        };
        response
            .headers_mut()
            .append("Set-Cookie", &cookie("rayde_oauth", "", &url, 0))?;
        return Ok(response);
    }
    if let Some(rest) = path.strip_prefix("/api/sync/") {
        return sync::route(&mut req, &env, rest).await;
    }
    if path.starts_with("/api/") {
        let (sid, session) = auth(&req, &env).await?;
        if req.method() != Method::Get
            && req.headers().get("X-RayDE-CSRF")?.as_deref() != session["csrf"].as_str()
        {
            return Err(bad(403, "The request could not be verified."));
        }
        if path == "/api/session" && req.method() == Method::Get {
            return Ok(reply(
                &json!({"user":session["user"],"csrf":session["csrf"],"installUrl":config(&env,"GITHUB_APP_SLUG").map(|slug|format!("https://github.com/apps/{slug}/installations/new"))}),
                200,
            )?);
        }
        if let Some(key)=path.strip_prefix("/api/projects/create/") {
            if req.method()!=Method::Post {return Err(bad(405,"Use POST to create a project."));}
            if !opaque(key) {return Err(bad(400,"Invalid project request."));}
            return Ok(env.durable_object("ACCOUNTS")?.get_by_name(&sid)?.fetch_with_request(req).await?);
        }
        // A local gateway has no GitHub: the account's synced workspaces are what Open Repository offers.
        if path == "/api/repositories" && req.method() == Method::Get && config(&env, "LOCAL_DEV").as_deref() == Some("1") && config(&env, "DEV_ACCOUNT").is_some() {
            return Ok(reply(&json!({"cursor":Value::Null,"repositories":sync::listing(&env,&sync::session_owner(&env,&session)).await}), 200)?);
        }
        if path == "/api/workspaces/open" && req.method() == Method::Post && config(&env, "LOCAL_DEV").as_deref() == Some("1") && config(&env, "DEV_ACCOUNT").is_some() {
            let data: Value = req.json().await?;
            let id = data["repository"].as_str().filter(|id| workspace_id(id)).ok_or_else(|| bad(400, "Choose a synced workspace."))?;
            let opened = sync::open_synced(&env, &sync::session_owner(&env, &session), id, &origin).await?;
            return Ok(reply(&opened, 200)?);
        }
        if path == "/api/repositories" && req.method() == Method::Get {
            return Ok(reply(
                &rpc(
                    &env,
                    "ACCOUNTS",
                    &sid,
                    "repositories",
                    &json!({"cursor":query("cursor")}),
                )
                .await?,
                200,
            )?);
        }
        if path == "/api/logout" && req.method() == Method::Post {
            rpc(&env, "ACCOUNTS", &sid, "logout", &json!({"sid":sid})).await?;
            let mut response = reply(&json!({}), 200)?;
            response
                .headers_mut()
                .set("Set-Cookie", &cookie("rayde_session", "", &url, 0))?;
            return Ok(response);
        }
        if path == "/api/workspaces/open" && req.method() == Method::Post {
            let data: Value = req.json().await?;
            let granted = rpc(
                &env,
                "ACCOUNTS",
                &sid,
                "repository",
                &json!({"id":data["repository"]}),
            )
            .await?;
            let id = hash(&format!(
                "github:{}:{}",
                session["user"]["id"], granted["repository"]["id"]
            ));
            rpc(&env, "ACCOUNTS", &sid, "remember", &json!({"id":id})).await?;
            return Ok(reply(&rpc(&env,"WORKSPACES",&id,"open",&json!({"id":id,"owner":session["user"]["id"],"repository":granted["repository"],"access":granted["access"]})).await?,200)?);
        }
        if let Some(rest) = path.strip_prefix("/api/workspaces/") {
            let socket = rest.ends_with("/socket");
            let resources = rest.ends_with("/resources");
            let id = rest.strip_suffix("/socket").or_else(||rest.strip_suffix("/resources")).unwrap_or(rest);
            if !workspace_id(id) {
                return Err(bad(404, "Workspace not found."));
            }
            if socket
                && req
                    .headers()
                    .get("Upgrade")?
                    .is_some_and(|v| v.eq_ignore_ascii_case("websocket"))
            {
                let record = rpc(
                    &env,
                    "WORKSPACES",
                    id,
                    "state",
                    &json!({"owner":session["user"]["id"]}),
                )
                .await?;
                // A synced workspace is the account's own upload, not a GitHub repository: there is no grant to look up and no repository token.
                let granted = if record["repository"]["sync"].is_object() {
                    json!({"access": Value::Null})
                } else {
                    rpc(
                        &env,
                        "ACCOUNTS",
                        &sid,
                        "repository",
                        &json!({"id":record["repository"]["id"]}),
                    )
                    .await?
                };
                let headers = Headers::new();
                headers.set("Upgrade", "websocket")?;
                headers.set("X-RayDE-Identity",&json!({"owner":session["user"]["id"],"sid":sid,"expires":session["expires"],"origin":origin,"access":granted["access"]}).to_string())?;
                let request = Request::new_with_init(
                    "https://internal/socket",
                    RequestInit::new().with_headers(headers),
                )?;
                return Ok(env
                    .durable_object("WORKSPACES")?
                    .get_by_name(id)?
                    .fetch_with_request(request)
                    .await?);
            }
            if req.method() == Method::Get {
                return Ok(reply(
                    &rpc(
                        &env,
                        "WORKSPACES",
                        id,
                        if resources { "resources" } else { "state" },
                        &json!({"owner":session["user"]["id"]}),
                    )
                    .await?,
                    200,
                )?);
            }
        }
        return Err(bad(404, "Not found."));
    }
    if let Some(base) = config(&env, "ASSETS_ORIGIN") {
        let mut asset = Url::parse(&base).map_err(|_| bad(503, "Invalid asset configuration."))?;
        asset.set_path(if workspace_page.is_some() {
            "/index.html"
        } else {
            url.path()
        });
        asset.set_query(url.query());
        let response = match assets::get(&req,&env,asset.path()).await? {
            Some(response)=>response,
            None=>Fetch::Url(asset).send().await?,
        };
        let headers = response.headers().clone();
        let mut response = response.with_headers(headers);
        if workspace_page.is_some() {
            response.headers_mut().set("Cache-Control", "no-store")?;
        }
        response
            .headers_mut()
            .set("Cross-Origin-Opener-Policy", "same-origin")?;
        response
            .headers_mut()
            .set("Cross-Origin-Embedder-Policy", "require-corp")?;
        return Ok(response);
    }
    Ok(Response::ok("RayDE workspace service")?)
}
