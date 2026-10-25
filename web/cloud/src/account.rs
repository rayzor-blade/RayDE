use super::*;

#[durable_object]
pub struct AccountSession {
    state: State,
    env: Env,
    gate: futures_util::lock::Mutex<()>,
}
impl DurableObject for AccountSession {
    fn new(state: State, env: Env) -> Self {
        Self {
            state,
            env,
            gate: futures_util::lock::Mutex::new(()),
        }
    }
    async fn alarm(&self) -> Result<Response> {
        self.state.storage().delete_all().await?;
        Response::empty()
    }
    async fn fetch(&self, request: Request) -> Result<Response> {
        {
            let _guard = self.gate.lock().await;
            finish(self.handle(request).await)
        }
    }
}
impl AccountSession {
    async fn handle(&self, mut req: Request) -> AppResult<Response> {
        let op = req.path();
        let data: Value = req.json().await?;
        let storage = self.state.storage();
        if op == "/put" {
            let expires = data["expires"].as_u64().unwrap_or(now());
            storage.put("session", data).await?;
            storage
                .set_alarm(std::time::Duration::from_millis(
                    expires.saturating_sub(now()),
                ))
                .await?;
            return Ok(reply(&json!({}), 200)?);
        }
        let mut saved = storage
            .get::<Value>("session")
            .await?
            .ok_or_else(|| bad(401, "Sign in with GitHub to continue."))?;
        if saved["expires"].as_u64().unwrap_or(0) < now() {
            return Err(bad(401, "Sign in with GitHub to continue."));
        }
        if op == "/consume" {
            if saved["kind"] != "oauth" || saved["cookieHash"] != data["cookieHash"] {
                return Err(bad(403, "The sign-in request could not be verified."));
            }
            storage.delete_all().await?;
            return Ok(reply(&saved, 200)?);
        }
        if saved["kind"] != "account" {
            return Err(bad(401, "Sign in with GitHub to continue."));
        }
        if op == "/get" {
            return Ok(reply(&saved, 200)?);
        }
        if op == "/logout" {
            storage.delete_all().await?;
            if let Some(workspaces) = saved["workspaces"].as_array() {
                for id in workspaces {
                    rpc(
                        &self.env,
                        "WORKSPACES",
                        id.as_str().unwrap_or(""),
                        "disconnect",
                        &json!({"sid":data["sid"]}),
                    )
                    .await?;
                }
            }
            return Ok(reply(&json!({}), 200)?);
        }
        if op == "/remember" {
            let mut ids = saved["workspaces"].as_array().cloned().unwrap_or_default();
            if !ids.contains(&data["id"]) {
                ids.push(data["id"].clone());
            }
            if ids.len() > 64 {
                return Err(bad(429, "Too many active workspaces."));
            }
            saved["workspaces"] = json!(ids);
            storage.put("session", saved).await?;
            return Ok(reply(&json!({}), 200)?);
        }
        if saved["tokens"]["expires"]
            .as_u64()
            .is_some_and(|expiry| expiry < now() + 60000)
        {
            let refresh = text(&saved["tokens"], "refresh")
                .map_err(|_| bad(401, "Sign in to GitHub again."))?;
            let mut req = request(
                "https://github.com/login/oauth/access_token",
                &json!({"client_id":config(&self.env,"GITHUB_CLIENT_ID"),"client_secret":config(&self.env,"GITHUB_CLIENT_SECRET"),"grant_type":"refresh_token","refresh_token":refresh}),
            )?;
            req.headers_mut()?.set("Accept", "application/json")?;
            let mut response = github(&self.env, req).await?;
            let value: Value = response.json().await?;
            if response.status_code() >= 400 || value["access_token"].as_str().is_none() {
                return Err(bad(401, "Sign in to GitHub again."));
            }
            saved["tokens"] = json!({"access":value["access_token"],"refresh":value["refresh_token"],"expires":now()+value["expires_in"].as_u64().unwrap_or(28800)*1000});
            storage.put("session", &saved).await?;
        }
        let access = text(&saved["tokens"], "access")?;
        if op == "/repository" {
            let id = data["id"]
                .as_u64()
                .filter(|v| *v > 0)
                .ok_or_else(|| bad(400, "Choose a repository."))?;
            let repo = api(&self.env, access, &format!("/repositories/{id}")).await?;
            if repo["disabled"] == true || repo["permissions"]["pull"] == false {
                return Err(bad(403, "This repository is not available."));
            }
            return Ok(reply(
                &json!({"repository":{"id":repo["id"],"name":repo["name"],"fullName":repo["full_name"],"private":repo["private"],"branch":repo["default_branch"],"cloneUrl":repo["clone_url"]},"access":access}),
                200,
            )?);
        }
        if op == "/repositories" {
            // One installation page and one repository page keep each request bounded.
            let cursor = data["cursor"].as_str().filter(|s| !s.is_empty());
            let (page, index, repo_page): (u32, usize, u32) = match cursor {
                Some(cursor) => URL_SAFE_NO_PAD
                    .decode(cursor)
                    .ok()
                    .and_then(|b| serde_json::from_slice(&b).ok())
                    .filter(|(p, i, r): &(u32, usize, u32)| {
                        *p > 0 && *p <= 10000 && *i < 100 && *r > 0 && *r <= 10000
                    })
                    .ok_or_else(|| bad(400, "Invalid repository page."))?,
                None => (1, 0, 1),
            };
            let installations = api(
                &self.env,
                access,
                &format!("/user/installations?per_page=100&page={page}"),
            )
            .await?;
            let installs = installations["installations"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let mut repositories = Vec::new();
            let mut next = None;
            if let Some(install) = installs.get(index) {
                let result = api(
                    &self.env,
                    access,
                    &format!(
                        "/user/installations/{}/repositories?per_page=100&page={repo_page}",
                        install["id"]
                    ),
                )
                .await?;
                let repos = result["repositories"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                for repo in &repos {
                    if repo["disabled"] != true {
                        repositories.push(json!({"id":repo["id"],"name":repo["name"],"fullName":repo["full_name"],"description":repo["description"],"private":repo["private"],"branch":repo["default_branch"]}));
                    }
                }
                if repos.len() == 100 {
                    next = Some((page, index, repo_page + 1));
                } else if index + 1 < installs.len() {
                    next = Some((page, index + 1, 1));
                } else if installs.len() == 100 {
                    next = Some((page + 1, 0, 1));
                }
            }
            let next =
                next.map(|value| URL_SAFE_NO_PAD.encode(serde_json::to_vec(&value).unwrap()));
            return Ok(reply(
                &json!({"repositories":repositories,"cursor":next}),
                200,
            )?);
        }
        Err(bad(404, "Unknown account operation."))
    }
}
