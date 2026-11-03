use super::*;
use base64::engine::general_purpose::STANDARD;
use futures_util::StreamExt;
use std::collections::BTreeMap;

pub(crate) async fn input(req: &mut Request) -> AppResult<Value> {
    let mut bytes = Vec::new();
    let mut stream = req.stream()?;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > 5 * 1024 * 1024 {
            return Err(bad(413, "The starter request is too large."));
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| bad(400, "Invalid project request."))
}

fn segment(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}
fn sha(value: &Value) -> AppResult<String> {
    value
        .as_str()
        .filter(|value| {
            matches!(value.len(), 40 | 64) && value.bytes().all(|b| b.is_ascii_hexdigit())
        })
        .map(str::to_owned)
        .ok_or_else(|| bad(502, "GitHub returned an invalid commit."))
}
fn path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 240
        && !value
            .chars()
            .any(|c| c.is_control() || "\\<>:\"|?*".contains(c))
        && value.split('/').all(|part| {
            !matches!(part, "" | "." | "..")
                && !part.eq_ignore_ascii_case(".git")
                && !part.ends_with(['.', ' '])
        })
}
async fn send(
    env: &Env,
    token: &str,
    method: Method,
    path: &str,
    data: Option<&Value>,
) -> AppResult<Value> {
    let headers = Headers::new();
    headers.set("Authorization", &format!("Bearer {token}"))?;
    headers.set("Accept", "application/vnd.github+json")?;
    headers.set("User-Agent", "RayDE")?;
    headers.set("X-GitHub-Api-Version", "2022-11-28")?;
    headers.set("Content-Type", "application/json")?;
    let mut init = RequestInit::new();
    init.with_method(method).with_headers(headers);
    if let Some(data) = data {
        init.with_body(Some(data.to_string().into()));
    }
    let request = Request::new_with_init(&format!("https://api.github.com{path}"), &init)?;
    crate::workspace::deadline(async {
    let mut response = github(env, request).await?;
    match response.status_code() {
        200..=299 => response.json().await.map_err(Failure::from),
        401 => Err(bad(401,"Sign in with GitHub again.")),
        403|404 => Err(bad(403,"Allow Repository creation and Contents write for the RayDE GitHub App, then retry.")),
        422 => Err(bad(409,"GitHub could not apply this request. Check the repository name and its current files.")),
        _ => Err(bad(502,"GitHub did not complete the project request. Try again.")),
    }
    }, 15).await.map_err(|_|bad(504,"GitHub did not respond in time. Retry to check this project request."))?
}

pub(crate) async fn create(
    state: &State,
    env: &Env,
    saved: &Value,
    key: &str,
    data: &Value,
) -> AppResult<Value> {
    if !opaque(key) {
        return Err(bad(400, "Invalid project request."));
    }
    let name = text(data, "name")?;
    if name.is_empty()
        || name.len() > 64
        || !name.as_bytes()[0].is_ascii_alphabetic()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
    {
        return Err(bad(
            400,
            "Choose a project name using letters, numbers, hyphens or underscores.",
        ));
    }
    let private = data["private"]
        .as_bool()
        .ok_or_else(|| bad(400, "Choose repository visibility."))?;
    let description = data["description"].as_str().unwrap_or("");
    if description.len() > 350 {
        return Err(bad(400, "The repository description is too long."));
    }
    let entries = data["files"]
        .as_array()
        .filter(|files| !files.is_empty() && files.len() <= 256)
        .ok_or_else(|| bad(400, "A starter needs between 1 and 256 files."))?;
    let mut files = BTreeMap::new();
    let mut names = std::collections::BTreeSet::new();
    let mut total = 0;
    for file in entries {
        let file_path = text(file, "path")?;
        let source = text(file, "text")?;
        if !path(file_path) || !names.insert(file_path.to_lowercase()) {
            return Err(bad(400, "Starter file paths must be safe and unique."));
        }
        total += source.len();
        if source.len() > 1024 * 1024 || total > 4 * 1024 * 1024 {
            return Err(bad(413, "The starter exceeds its file size limit."));
        }
        files.insert(file_path.to_owned(), source.to_owned());
    }
    for file in files.keys() {
        let parts: Vec<_> = file.split('/').collect();
        for end in 1..parts.len() {
            if names.contains(&parts[..end].join("/").to_lowercase()) {
                return Err(bad(400, "A starter file cannot also be a folder."));
            }
        }
    }
    let entry = data["entry"].as_str().unwrap_or("");
    if !entry.is_empty() && !files.contains_key(entry) {
        return Err(bad(400, "The project entry is not in the starter."));
    }
    let filename = entry.rsplit('/').next().unwrap_or("").to_ascii_lowercase();
    if !entry.is_empty()
        && !filename.ends_with(".hxml")
        && !filename.ends_with(".cbproj")
        && !matches!(filename.as_str(), "haxelib.json" | "rayzor.toml")
    {
        return Err(bad(
            400,
            "Choose a supported project entry or a folder workspace.",
        ));
    }
    let payload=hash(&json!({"name":name,"description":description,"private":private,"entry":entry,"files":files}).to_string());
    let storage = state.storage();
    let record = format!("project:{key}");
    let mut job: Value = match storage.get(&record).await? {
        Some(job) => job,
        None => {
            let mut ids: Vec<String> = storage.get("projects").await?.unwrap_or_default();
            if ids.len() >= 16 {
                return Err(bad(
                    429,
                    "Too many project creation requests in this sign-in session.",
                ));
            }
            ids.push(key.to_owned());
            storage.put("projects", ids).await?;
            json!({"payload":payload,"phase":"new","entry":entry})
        }
    };
    if job["payload"] != payload {
        return Err(bad(
            409,
            "This project request belongs to a different starter.",
        ));
    }
    let outcome = run(
        state,
        env,
        saved,
        &record,
        &mut job,
        name,
        description,
        private,
        &files,
    )
    .await;
    match outcome {
        Ok(()) => Ok(json!({"status":"ready","repository":job["repository"],"entry":entry})),
        Err(error) if job["repository"].is_object() => Ok(
            json!({"status":"incomplete","repository":job["repository"],"entry":entry,"message":error.message}),
        ),
        Err(error) => Err(error),
    }
}

async fn run(
    state: &State,
    env: &Env,
    saved: &Value,
    record: &str,
    job: &mut Value,
    name: &str,
    description: &str,
    private: bool,
    files: &BTreeMap<String, String>,
) -> AppResult<()> {
    let storage = state.storage();
    let access = text(&saved["tokens"], "access")?;
    let login = text(&saved["user"], "login")?;
    if login.is_empty()
        || login.len() > 100
        || !login
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err(bad(502, "GitHub returned an invalid account."));
    }
    if job["phase"] == "done" {
        return Ok(());
    }
    if !job["repository"].is_object() {
        if job["phase"] == "creating" {
            return Err(bad(
                409,
                "Repository creation could not be confirmed. Check GitHub before starting another request.",
            ));
        }
        job["phase"] = json!("creating");
        storage.put(record, &*job).await?;
        let repository = match send(
            env,
            access,
            Method::Post,
            "/user/repos",
            Some(
                &json!({"name":name,"description":description,"private":private,"auto_init":false}),
            ),
        )
        .await
        {
            Ok(repository) => repository,
            Err(error) => {
                if matches!(error.status, 401 | 403 | 409) {
                    job["phase"] = json!("new");
                    storage.put(record, &*job).await?;
                }
                return Err(error);
            }
        };
        let expected = format!("{login}/{name}");
        if repository["id"].as_u64().is_none_or(|id| id == 0)
            || repository["owner"]["id"] != saved["user"]["id"]
            || !text(&repository, "full_name")?.eq_ignore_ascii_case(&expected)
        {
            return Err(bad(502, "GitHub returned an unexpected repository."));
        }
        job["repository"] = json!({"id":repository["id"],"fullName":repository["full_name"],"url":format!("https://github.com/{expected}"),"branch":repository["default_branch"]});
        job["phase"] = json!("created");
        storage.put(record, &*job).await?;
    }
    let base = format!("/repos/{login}/{name}");
    if job["base"].is_null() {
        if job["phase"] == "initializing" {
            return Err(bad(
                409,
                "The repository was created, but starter initialization could not be confirmed. Review it on GitHub.",
            ));
        }
        job["phase"] = json!("initializing");
        storage.put(record, &*job).await?;
        let (first, contents) = files
            .get_key_value("README.md")
            .unwrap_or_else(|| files.first_key_value().unwrap());
        let target = first.split('/').map(segment).collect::<Vec<_>>().join("/");
        let initial = match send(
            env,
            access,
            Method::Put,
            &format!("{base}/contents/{target}"),
            Some(&json!({"message":format!("Create {name}"),"content":STANDARD.encode(contents)})),
        )
        .await
        {
            Ok(initial) => initial,
            Err(error) => {
                if matches!(error.status, 401 | 403 | 409) {
                    job["phase"] = json!("created");
                    storage.put(record, &*job).await?;
                }
                return Err(error);
            }
        };
        if initial["commit"]["parents"]
            .as_array()
            .is_none_or(|parents| !parents.is_empty())
        {
            return Err(bad(
                409,
                "The new repository changed during initialization. Review it on GitHub.",
            ));
        }
        job["base"] = json!(sha(&initial["commit"]["sha"])?);
        job["baseTree"] = json!(sha(&initial["commit"]["tree"]["sha"])?);
        job["phase"] = json!("seeded");
        storage.put(record, &*job).await?;
    }
    let branch = text(&job["repository"], "branch")?.to_owned();
    if branch.is_empty() || branch.len() > 240 {
        return Err(bad(502, "GitHub returned an invalid branch."));
    }
    let reference = format!("{base}/git/refs/heads/{}", segment(&branch));
    let head = send(
        env,
        access,
        Method::Get,
        &format!("{base}/git/ref/heads/{}", segment(&branch)),
        None,
    )
    .await?;
    if !job["commit"].is_null() && head["object"]["sha"] == job["commit"] {
        job["phase"] = json!("done");
        storage.put(record, &*job).await?;
        return Ok(());
    }
    if head["object"]["sha"] != job["base"] {
        return Err(bad(
            409,
            "The repository changed while its starter was being created. Review it on GitHub.",
        ));
    }
    if job["tree"].is_null() {
        let tree:Vec<_>=files.iter().map(|(path,content)|json!({"path":path,"mode":"100644","type":"blob","content":content})).collect();
        let created = send(
            env,
            access,
            Method::Post,
            &format!("{base}/git/trees"),
            Some(&json!({"base_tree":job["baseTree"],"tree":tree})),
        )
        .await?;
        job["tree"] = json!(sha(&created["sha"])?);
        storage.put(record, &*job).await?;
    }
    if job["commit"].is_null() {
        let created=send(env,access,Method::Post,&format!("{base}/git/commits"),Some(&json!({"message":format!("Add {name} starter"),"tree":job["tree"],"parents":[job["base"]]}))).await?;
        job["commit"] = json!(sha(&created["sha"])?);
        storage.put(record, &*job).await?;
    }
    let updated = send(
        env,
        access,
        Method::Patch,
        &reference,
        Some(&json!({"sha":job["commit"],"force":false})),
    )
    .await?;
    if updated["object"]["sha"] != job["commit"] {
        return Err(bad(502, "GitHub did not confirm the starter commit."));
    }
    job["phase"] = json!("done");
    storage.put(record, &*job).await?;
    Ok(())
}
