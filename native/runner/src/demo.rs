use super::*;
use base64::engine::general_purpose::STANDARD;
use std::{collections::BTreeSet, sync::Arc, time::{SystemTime, UNIX_EPOCH}};

pub(crate) fn now() -> Result<u64> {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|value|value.as_secs()).map_err(|_|unavailable())
}

pub(crate) fn live(reference: &DemoRef) -> Result<()> {
    let now = now()?;
    if reference.expires <= now { return Err(Failure(StatusCode::GONE, "The demo session expired.")); }
    if reference.expires - now > 900 { return Err(invalid()); }
    Ok(())
}

#[derive(Deserialize)]
struct Bundle { version:u64, root:String, project:String, entries:Vec<Entry> }
#[derive(Deserialize)]
struct Entry { path:String, directory:bool, data:Option<String> }

async fn read(path:&Path, release:&str) -> Result<Bundle> {
    let metadata = tokio::fs::symlink_metadata(path).await?;
    if !metadata.file_type().is_file() || metadata.len()>3*1024*1024 { return Err(invalid()); }
    let bytes = tokio::fs::read(path).await?;
    let digest:String = Sha256::digest(&bytes).iter().map(|byte|format!("{byte:02x}")).collect();
    if digest!=release { return Err(Failure(StatusCode::CONFLICT,"The demo source release changed.")); }
    let bundle:Bundle = serde_json::from_slice(&bytes).map_err(|_|invalid())?;
    if bundle.version!=1 || bundle.root!="/work/pocket-studio" || bundle.project!="pocket-studio/build.hxml" || bundle.entries.len()>256 {return Err(invalid());}
    let mut paths = BTreeSet::new();
    let mut total = 0;
    let mut project = false;
    for entry in &bundle.entries {
        if !paths.insert(entry.path.clone()) || entry.directory && entry.data.is_some() {return Err(invalid());}
        if entry.path=="/work" || entry.path==bundle.root {
            if !entry.directory {return Err(invalid());}
            continue;
        }
        let relative = entry.path.strip_prefix(&(bundle.root.clone()+"/")).ok_or_else(invalid)?;
        if relative.is_empty() || relative.split('/').any(|part|part.is_empty() || part=="." || part==".." || part.contains(['\\','\0']) || [".git",".haxelib",".rayde",".rayzor"].contains(&part)) {return Err(invalid());}
        if !entry.directory {
            let data = STANDARD.decode(entry.data.as_deref().ok_or_else(invalid)?).map_err(|_|invalid())?;
            total += data.len();
            if total>2*1024*1024 {return Err(invalid());}
            if relative=="build.hxml" {project=true;}
        }
    }
    if !project || !paths.contains(&bundle.root) {return Err(invalid());}
    Ok(bundle)
}

pub(crate) async fn authorize(config:&Config, request:&Open) -> Result<PathBuf> {
    let reference = request.repository.demo.as_ref().ok_or_else(invalid)?;
    let source = config.demo.as_ref().ok_or(Failure(StatusCode::SERVICE_UNAVAILABLE,"Anonymous demo sessions are not enabled on this runner."))?;
    if source.release!=reference.release || !request.checkout.token().is_empty() || request.publish.is_some() {return Err(invalid());}
    live(reference)?;
    read(&source.bundle,&source.release).await?;
    Ok(source.bundle.clone())
}

pub(crate) async fn prepare(root:&Path, request:&Open, bundle:&Path, _work:Option<Arc<registry::Work>>) -> Result<PathBuf> {
    let reference = request.repository.demo.as_ref().ok_or_else(invalid)?;
    live(reference)?;
    let bundle = read(bundle,&reference.release).await?;
    let project = root.join("project");
    private_dir(&project).await?;
    for entry in bundle.entries {
        let Some(relative)=entry.path.strip_prefix(&(bundle.root.clone()+"/")) else {continue;};
        let target = project.join(relative);
        if entry.directory {tokio::fs::create_dir_all(&target).await?;} else {
            if let Some(parent)=target.parent(){tokio::fs::create_dir_all(parent).await?;}
            tokio::fs::write(target,STANDARD.decode(entry.data.as_deref().unwrap()).map_err(|_|invalid())?).await?;
        }
    }
    for args in [vec!["init","--template=","-b","main"],vec!["add","."],
        vec!["-c","user.name=Pocket Studio","-c","user.email=demo@rayde.invalid","commit","--no-gpg-sign","-m","Start Pocket Studio"]] {
        let mut command = checkout::git(root);
        command.arg("-C").arg(&project).args(args);
        command::capture(command,10).await?;
    }
    live(reference)?;
    Ok(project)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    async fn bundle(path:&Path, value:&serde_json::Value)->String {
        let bytes=serde_json::to_vec(value).unwrap();
        tokio::fs::write(path,&bytes).await.unwrap();
        Sha256::digest(bytes).iter().map(|byte|format!("{byte:02x}")).collect()
    }
    fn sample()->serde_json::Value {json!({"version":1,"root":"/work/pocket-studio","project":"pocket-studio/build.hxml","entries":[
        {"path":"/work","directory":true,"data":null},{"path":"/work/pocket-studio","directory":true,"data":null},
        {"path":"/work/pocket-studio/build.hxml","directory":false,"data":STANDARD.encode("-cp src\n-main Main\n--interp\n")},
        {"path":"/work/pocket-studio/src/Main.hx","directory":false,"data":STANDARD.encode("class Main {static function main(){}}\n")}
    ]})}
    #[tokio::test]
    async fn immutable_sources_materialize_as_independent_clean_git_trees() {
        let temporary=tempfile::tempdir().unwrap();let path=temporary.path().join("bundle.json");
        let release=bundle(&path,&sample()).await;
        let reference=DemoRef{release,lease:"a".repeat(43),expires:now().unwrap()+60};
        let request=Open{id:demo_workspace_id(&reference.release,&reference.lease),owner:0,
            repository:Repository{id:0,full_name:"demo/pocket-studio".into(),branch:String::new(),clone_url:String::new(),sync:None,demo:Some(reference)},checkout:Checkout::default(),publish:None};
        let one=prepare(&temporary.path().join("one"),&request,&path,None).await.unwrap();
        let two=prepare(&temporary.path().join("two"),&request,&path,None).await.unwrap();
        let mut command=checkout::git(temporary.path());command.arg("-C").arg(&one).args(["status","--porcelain"]);
        assert!(command::capture(command,10).await.unwrap().is_empty());
        tokio::fs::write(one.join("src/Main.hx"),"changed only one visitor").await.unwrap();
        assert!(tokio::fs::read_to_string(two.join("src/Main.hx")).await.unwrap().starts_with("class Main"));
        assert!(read(&path,&request.repository.demo.unwrap().release).await.is_ok());
    }
    #[tokio::test]
    async fn source_identity_and_entry_boundaries_are_checked_before_materialization() {
        let temporary=tempfile::tempdir().unwrap();let path=temporary.path().join("bundle.json");
        let release=bundle(&path,&sample()).await;
        assert!(read(&path,&"0".repeat(64)).await.is_err());
        assert!(read(&path,&release).await.is_ok());
        for name in ["/outside","/work/pocket-studio/../escape","/work/pocket-studio/.git/config","/work/pocket-studio/.rayde/state","/work/pocket-studio/src/../escape"] {
            let mut value=sample();value["entries"][3]["path"]=json!(name);
            let release=bundle(&path,&value).await;assert!(read(&path,&release).await.is_err(),"{name}");
        }
        let mut value=sample();let duplicate=value["entries"][3].clone();value["entries"].as_array_mut().unwrap().push(duplicate);
        let release=bundle(&path,&value).await;assert!(read(&path,&release).await.is_err());
    }
}
