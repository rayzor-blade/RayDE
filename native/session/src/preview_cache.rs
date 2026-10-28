//! Validated, bounded snapshots of successful preview compiler stages.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    io::Read,
    path::{Path, PathBuf},
};

type Result<T> = std::result::Result<T, String>;
const MAX_BYTES: u64 = 128 * 1024 * 1024;
const MAX_FILES: usize = 40_000;

#[derive(Clone, Default, Deserialize, Serialize)]
pub(crate) struct Recipe {
    pub compiler: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub family: Option<String>,
    pub primary: Option<String>,
    pub output: Option<String>,
    pub runner: Option<CompilerRunner>,
    pub assets: Option<String>,
    pub entry: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
pub(crate) struct CompilerRunner {
    pub command: String,
    pub args: Vec<String>,
}
#[derive(Clone)]
pub(crate) struct Plan {
    recipe: Recipe,
    pub bytecode: String,
    pub wasm: String,
}
pub(crate) struct Cache {
    root: PathBuf,
    tools: Option<PathBuf>,
    environment: BTreeMap<String, String>,
    lock: tokio::sync::Mutex<()>,
    hashes: std::sync::Arc<std::sync::Mutex<HashMap<PathBuf, (Stamp, String)>>>,
}
#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    size: u64,
    modified: u128,
    changed: (i64, i64),
}
fn stamp(metadata: &std::fs::Metadata) -> Result<Stamp> {
    #[cfg(unix)]
    let changed = {
        use std::os::unix::fs::MetadataExt;
        (metadata.ctime(), metadata.ctime_nsec())
    };
    #[cfg(not(unix))]
    let changed = (0, 0);
    Ok(Stamp {
        size: metadata.len(),
        modified: metadata
            .modified()
            .map_err(err)?
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(err)?
            .as_nanos(),
        changed,
    })
}
#[derive(Deserialize, Serialize)]
struct Manifest {
    key: String,
    files: BTreeMap<String, String>,
}

impl Cache {
    pub async fn clear(&self) -> Result<()> {
        let _guard = self.lock.lock().await;
        let root = self.root.clone();
        tokio::task::spawn_blocking(move || {
            let directory = cache_dir(&root)?;
            for stage in ["bytecode", "wasm", ".bytecode-next", ".wasm-next"] {
                match std::fs::remove_dir_all(directory.join(stage)) {
                    Ok(()) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                    Err(error) => return Err(err(error)),
                }
            }
            Ok(())
        })
        .await
        .map_err(err)?
    }
    pub fn new(root: &Path, tools: Option<&Path>, environment: &HashMap<String, String>) -> Self {
        let mut values: BTreeMap<_, _> = std::env::vars().collect();
        values.extend(environment.iter().map(|(k, v)| (k.clone(), v.clone())));
        Self {
            root: std::fs::canonicalize(root).unwrap_or_else(|_| root.into()),
            tools: tools.map(|path| std::fs::canonicalize(path).unwrap_or_else(|_| path.into())),
            environment: values,
            lock: tokio::sync::Mutex::new(()),
            hashes: Default::default(),
        }
    }
    pub async fn plan(&self, recipe: Recipe) -> Result<Plan> {
        if recipe
            .family
            .as_deref()
            .is_some_and(|family| family != "haxe")
        {
            return Err("This compiler manages its incremental build cache.".into());
        }
        for path in [&recipe.primary, &recipe.output].into_iter().flatten() {
            crate::store::clean(path).map_err(err)?;
        }
        if recipe.args.len() > 4096
            || recipe.compiler.len() > 4096
            || recipe.args.iter().any(|a| a.len() > 32768)
        {
            return Err("Compiler arguments exceed cache limits".into());
        }
        let cwd = std::fs::canonicalize(self.root.join(&recipe.cwd)).map_err(err)?;
        if !cwd.starts_with(&self.root) {
            return Err("Compiler directory leaves the workspace".into());
        }
        let mut paths = self
            .tools
            .as_ref()
            .map(|tools| vec![tools.join("haxe")])
            .unwrap_or_default();
        if let Some(assets) = recipe.assets.as_deref().filter(|path| !path.is_empty()) {
            paths.push(self.root.join(crate::store::clean(assets).map_err(err)?));
        }
        let compiler = executable(&recipe.compiler, &cwd, &self.environment)?;
        let standard = self
            .environment
            .get("HAXE_STD_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| compiler.parent().unwrap().join("std"));
        if !standard.join("StdTypes.hx").is_file() {
            return Err("Compiler standard library could not be located".into());
        }
        paths.push(standard);
        let mut libraries = Vec::new();
        let mut at = 0;
        while at < recipe.args.len() {
            let flag = &recipe.args[at];
            at += 1;
            match flag.as_str() {
                "-cp" | "-p" | "--class-path" | "-lib" | "-L" | "--library" | "-resource"
                | "-r" | "--resource" => {
                    let value = recipe.args.get(at).ok_or("Incomplete compiler arguments")?;
                    at += 1;
                    if ["-lib", "-L", "--library"].contains(&flag.as_str()) {
                        libraries.push(value.clone());
                    } else {
                        paths.push(cwd.join(
                            if ["-r", "-resource", "--resource"].contains(&flag.as_str()) {
                                value.split('@').next().unwrap()
                            } else {
                                value
                            },
                        ));
                    }
                }
                "--cwd" | "-C" | "--connect" | "--server-connect" => {
                    return Err("This compiler configuration needs an uncached build".into());
                }
                _ if flag.ends_with(".hxml") => {
                    return Err("Nested compiler argument files need an uncached build".into());
                }
                _ => (),
            }
        }
        if !libraries.is_empty() {
            let mut command = tokio::process::Command::new("haxelib");
            command
                .arg("libpath")
                .args(libraries)
                .current_dir(&cwd)
                .envs(&self.environment)
                .kill_on_drop(true);
            let output = tokio::time::timeout(std::time::Duration::from_secs(10), command.output())
                .await
                .map_err(|_| "Library resolution timed out")?
                .map_err(err)?;
            if !output.status.success() || output.stdout.len() > 1024 * 1024 {
                return Err("Library paths could not be resolved".into());
            }
            for line in String::from_utf8(output.stdout)
                .map_err(err)?
                .lines()
                .filter(|s| !s.is_empty())
            {
                paths.push(PathBuf::from(line));
            }
        }
        let mut git = tokio::process::Command::new("git");
        git.args([
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ])
        .current_dir(&self.root)
        .kill_on_drop(true);
        let output = tokio::time::timeout(std::time::Duration::from_secs(5), git.output())
            .await
            .map_err(|_| "Workspace scan timed out")?
            .map_err(err)?;
        if !output.status.success() || output.stdout.len() > 8 * 1024 * 1024 {
            return Err("Workspace inventory is unavailable; building without cache".into());
        }
        let workspace = String::from_utf8(output.stdout)
            .map_err(err)?
            .split('\0')
            .filter(|s| !s.is_empty())
            .map(|s| self.root.join(s))
            .collect::<Vec<_>>();
        let root = self.root.clone();
        let tools = self.tools.clone();
        let env = self.environment.clone();
        let hashes = self.hashes.clone();
        tokio::task::spawn_blocking(move || {
            let mut haxe = Sha256::new();
            haxe.update(b"rayde-preview-bytecode-v3\0");
            hash_tool(&mut haxe, &compiler)?;
            haxe.update(serde_json::to_vec(&serde_json::json!({"compiler":recipe.compiler,"args":recipe.args,"cwd":recipe.cwd,"primary":recipe.primary,"assets":recipe.assets,"entry":recipe.entry})).map_err(err)?);
            haxe.update(serde_json::to_vec(&env).map_err(err)?);
            let mut files = BTreeSet::new();
            let mut visited = BTreeSet::new();
            for path in workspace {
                if !path.starts_with(root.join(".rayde")) && !path.starts_with(root.join(".rayzor"))
                {
                    collect(&path, &mut files, &mut visited)?;
                }
            }
            for path in paths {
                collect(&path, &mut files, &mut visited)?;
            }
            hash_files(&mut haxe, files, &hashes)?;
            let bytecode = format!("{:x}", haxe.finalize());
            let mut wasm = Sha256::new();
            wasm.update(b"rayde-preview-wasm-v1:wasm32-wasip1-threads:fibers=1\0");
            wasm.update(&bytecode);
            let mut files = BTreeSet::new();
            let mut visited = BTreeSet::new();
            if let Some(tools)=tools {collect(&tools, &mut files, &mut visited)?;}
            if let Some(runner)=&recipe.runner {
                wasm.update(serde_json::to_vec(runner).map_err(err)?);
                if !runner.command.is_empty(){hash_tool(&mut wasm,&executable(&runner.command,&cwd,&env)?)?;}
            }else{hash_tool(&mut wasm, &executable("ash", &cwd, &env)?)?;}
            hash_files(&mut wasm, files, &hashes)?;
            Ok(Plan {
                recipe,
                bytecode,
                wasm: format!("{:x}", wasm.finalize()),
            })
        })
        .await
        .map_err(err)?
    }
    pub async fn restore(&self, plan: &Plan, directory: &Path) -> Result<&'static str> {
        let _guard = self.lock.lock().await;
        let root = self.root.clone();
        let directory = directory.to_owned();
        let plan = plan.clone();
        tokio::task::spawn_blocking(move || {
            let cache = cache_dir(&root)?;
            for (stage, key) in [("wasm", &plan.wasm), ("bytecode", &plan.bytecode)] {
                let source = cache.join(stage);
                let Ok(bytes) = std::fs::read(source.join("manifest.json")) else {
                    continue;
                };
                if bytes.len() > 8 * 1024 * 1024 {
                    continue;
                }
                let Ok(manifest) = serde_json::from_slice::<Manifest>(&bytes) else {
                    continue;
                };
                if manifest.key != *key || manifest.files.is_empty() {
                    continue;
                }
                if inventory(&source.join("files")).ok().as_ref() != Some(&manifest.files) {
                    continue;
                }
                copy_files(&source.join("files"), &directory, &manifest.files)?;
                return Ok(stage);
            }
            Ok("miss")
        })
        .await
        .map_err(err)?
    }
    pub async fn publish(&self, plan: &Plan, directory: &Path, stage: &str) -> Result<bool> {
        let current = self.plan(plan.recipe.clone()).await?;
        if current.bytecode != plan.bytecode || stage == "wasm" && current.wasm != plan.wasm {
            return Ok(false);
        }
        let _guard = self.lock.lock().await;
        let root = self.root.clone();
        let directory = directory.to_owned();
        let stage = stage.to_owned();
        let key = if stage == "wasm" {
            plan.wasm.clone()
        } else {
            plan.bytecode.clone()
        };
        let primary = plan
            .recipe
            .primary
            .clone()
            .unwrap_or_else(|| "app.hl".into());
        let output = plan
            .recipe
            .output
            .clone()
            .unwrap_or_else(|| "app.wasm".into());
        tokio::task::spawn_blocking(move || {
            if !directory.join(primary).is_file()
                || stage == "wasm"
                    && (!directory.join(output).is_file()
                        || !directory.join("index.html").is_file())
            {
                return Err("Compiler output is incomplete".into());
            }
            let cache = cache_dir(&root)?;
            let pending = cache.join(format!(".{stage}-next"));
            let destination = cache.join(&stage);
            let _ = std::fs::remove_dir_all(&pending);
            let files = inventory(&directory)?;
            let result = (|| {
                copy_files(&directory, &pending.join("files"), &files)?;
                std::fs::write(
                    pending.join("manifest.json"),
                    serde_json::to_vec(&Manifest { key, files }).map_err(err)?,
                )
                .map_err(err)?;
                let _ = std::fs::remove_dir_all(&destination);
                std::fs::rename(&pending, destination).map_err(err)?;
                Ok(true)
            })();
            if result.is_err() {
                let _ = std::fs::remove_dir_all(&pending);
            }
            result
        })
        .await
        .map_err(err)?
    }
}
fn err(error: impl std::fmt::Display) -> String {
    error.to_string()
}
fn hash_tool(hash: &mut Sha256, path: &Path) -> Result<()> {
    let value = stamp(&std::fs::metadata(path).map_err(err)?)?;
    hash.update(path.as_os_str().as_encoded_bytes());
    hash.update([0]);
    hash.update(value.size.to_le_bytes());
    hash.update(value.modified.to_le_bytes());
    hash.update(value.changed.0.to_le_bytes());
    hash.update(value.changed.1.to_le_bytes());
    Ok(())
}
fn executable(name: &str, cwd: &Path, environment: &BTreeMap<String, String>) -> Result<PathBuf> {
    let path = Path::new(name);
    if path.components().count() > 1 {
        return std::fs::canonicalize(cwd.join(path)).map_err(err);
    }
    for directory in
        std::env::split_paths(environment.get("PATH").map(String::as_str).unwrap_or(""))
    {
        for suffix in if cfg!(windows) {
            vec![".exe", ""]
        } else {
            vec![""]
        } {
            let path = directory.join(format!("{name}{suffix}"));
            if path.is_file() {
                return std::fs::canonicalize(path).map_err(err);
            }
        }
    }
    Err("Compiler executable is unavailable".into())
}
fn collect(
    path: &Path,
    files: &mut BTreeSet<PathBuf>,
    visited: &mut BTreeSet<PathBuf>,
) -> Result<()> {
    if !path.exists() {
        files.insert(path.into());
        return Ok(());
    }
    let path = std::fs::canonicalize(path).map_err(err)?;
    if files.len() + visited.len() > MAX_FILES {
        return Err("Compiler input inventory exceeds cache limits".into());
    }
    if path.is_dir() {
        if !visited.insert(path.clone()) {
            return Ok(());
        }
        for entry in std::fs::read_dir(path).map_err(err)? {
            let entry = entry.map_err(err)?;
            if [
                ".git",
                ".rayde",
                ".rayzor",
                ".haxelib",
                "target",
                "node_modules",
            ]
            .contains(&entry.file_name().to_string_lossy().as_ref())
            {
                continue;
            }
            collect(&entry.path(), files, visited)?;
        }
    } else if path.is_file() {
        files.insert(path);
    } else {
        return Err("Unsupported compiler input".into());
    }
    Ok(())
}
fn digest(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path).map_err(err)?;
    let mut hash = Sha256::new();
    let mut bytes = [0u8; 65536];
    loop {
        let length = file.read(&mut bytes).map_err(err)?;
        if length == 0 {
            break;
        }
        hash.update(&bytes[..length]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn hash_files(
    hash: &mut Sha256,
    files: BTreeSet<PathBuf>,
    memo: &std::sync::Mutex<HashMap<PathBuf, (Stamp, String)>>,
) -> Result<()> {
    let mut size = 0u64;
    for path in files {
        hash.update(path.as_os_str().as_encoded_bytes());
        hash.update([0]);
        if !path.exists() {
            hash.update(b"missing\0");
            continue;
        }
        let metadata = std::fs::metadata(&path).map_err(err)?;
        let before = stamp(&metadata)?;
        hash.update(before.modified.to_le_bytes());
        hash.update(before.changed.0.to_le_bytes());
        hash.update(before.changed.1.to_le_bytes());
        size += metadata.len();
        if size > 512 * 1024 * 1024 {
            return Err("Compiler inputs exceed cache size limits".into());
        }
        let known = if cfg!(unix) {
            memo.lock()
                .unwrap()
                .get(&path)
                .filter(|(stamp, _)| *stamp == before)
                .map(|(_, hash)| hash.clone())
        } else {
            None
        };
        let value = match known {
            Some(hash) => hash,
            None => {
                let value = digest(&path)?;
                if before != stamp(&std::fs::metadata(&path).map_err(err)?)? {
                    return Err("Compiler inputs changed during validation".into());
                }
                let mut hashes = memo.lock().unwrap();
                if hashes.len() >= 8192 {
                    hashes.clear();
                }
                hashes.insert(path.clone(), (before, value.clone()));
                value
            }
        };
        hash.update(value);
        hash.update([0]);
    }
    Ok(())
}
fn cache_dir(root: &Path) -> Result<PathBuf> {
    let directory = root.join(".rayde/preview-cache");
    std::fs::create_dir_all(&directory).map_err(err)?;
    let directory = std::fs::canonicalize(directory).map_err(err)?;
    if !directory.starts_with(root) {
        return Err("Cache directory leaves the workspace".into());
    }
    Ok(directory)
}
fn inventory(root: &Path) -> Result<BTreeMap<String, String>> {
    let mut files = BTreeMap::new();
    let mut pending = vec![root.to_owned()];
    let mut total = 0;
    let mut entries = 0;
    while let Some(path) = pending.pop() {
        for entry in std::fs::read_dir(path).map_err(err)? {
            entries += 1;
            if entries > 2048 {
                return Err("Compiler outputs exceed cache limits".into());
            }
            let entry = entry.map_err(err)?;
            let metadata = entry.metadata().map_err(err)?;
            if entry.file_type().map_err(err)?.is_symlink() {
                return Err("Cached outputs contain symlinks".into());
            }
            if metadata.is_dir() {
                pending.push(entry.path());
                continue;
            }
            if !metadata.is_file() {
                return Err("Unsupported compiler output".into());
            }
            total += metadata.len();
            if total > MAX_BYTES || files.len() >= 2048 {
                return Err("Compiler outputs exceed cache limits".into());
            }
            files.insert(
                entry
                    .path()
                    .strip_prefix(root)
                    .map_err(err)?
                    .to_string_lossy()
                    .replace('\\', "/"),
                digest(&entry.path())?,
            );
        }
    }
    Ok(files)
}
fn copy_files(source: &Path, destination: &Path, files: &BTreeMap<String, String>) -> Result<()> {
    for name in files.keys() {
        let path = destination.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).map_err(err)?;
        std::fs::copy(source.join(name), path).map_err(err)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn stages_survive_restart_and_validate_sources_tools_and_outputs() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("workspace");
        let tools = temporary.path().join("tools");
        let host = temporary.path().join("host");
        let library = temporary.path().join("library");
        for path in [
            root.join("src"),
            tools.join("haxe"),
            host.join("std"),
            library.clone(),
        ] {
            std::fs::create_dir_all(path).unwrap();
        }
        for path in [
            root.join("src/Main.hx"),
            tools.join("haxe/Support.hx"),
            host.join("std/StdTypes.hx"),
            library.join("Dependency.hx"),
            host.join("haxe"),
            host.join("ash"),
        ] {
            std::fs::write(path, "initial").unwrap();
        }
        assert!(
            std::process::Command::new("git")
                .args(["init", "-q"])
                .current_dir(&root)
                .status()
                .unwrap()
                .success()
        );
        let environment = HashMap::from([(
            "PATH".into(),
            format!(
                "{}{}{}",
                host.display(),
                if cfg!(windows) { ";" } else { ":" },
                std::env::var("PATH").unwrap_or_default()
            ),
        )]);
        let make = || Cache::new(&root, Some(&tools), &environment);
        let cache = make();
        let recipe = Recipe {
            compiler: host.join("haxe").to_string_lossy().into(),
            args: vec![
                "-cp".into(),
                "src".into(),
                "-cp".into(),
                library.to_string_lossy().into(),
                "-main".into(),
                "Main".into(),
            ],
            cwd: "".into(),
            ..Recipe::default()
        };
        let plan = cache.plan(recipe.clone()).await.unwrap();
        let mut configured = recipe.clone();
        configured.runner = Some(CompilerRunner {
            command: host.join("ash").to_string_lossy().into(),
            args: vec!["--target".into(), "wasm32-wasip1-threads".into()],
        });
        let first = cache.plan(configured.clone()).await.unwrap();
        configured
            .runner
            .as_mut()
            .unwrap()
            .args
            .push("--no-fma".into());
        let changed_flags = cache.plan(configured).await.unwrap();
        assert_eq!(first.bytecode, changed_flags.bytecode);
        assert_ne!(first.wasm, changed_flags.wasm);
        let mut javascript = recipe.clone();
        javascript.primary = Some("app.js".into());
        javascript.output = Some("app.js".into());
        javascript.runner = Some(CompilerRunner {
            command: String::new(),
            args: vec![],
        });
        let no_ash = Cache::new(
            &root,
            None,
            &HashMap::from([("PATH".into(), String::new())]),
        );
        let js = no_ash.plan(javascript).await.unwrap();
        assert!(!js.wasm.is_empty());
        let build = root.join(".rayde/previews/test");
        std::fs::create_dir_all(&build).unwrap();
        assert_eq!(cache.restore(&plan, &build).await.unwrap(), "miss");
        assert!(cache.publish(&plan, &build, "bytecode").await.is_err());
        std::fs::write(build.join("app.hl"), "bytecode").unwrap();
        std::fs::write(build.join("host.mjs"), "haxe support").unwrap();
        assert!(cache.publish(&plan, &build, "bytecode").await.unwrap());
        let second = root.join(".rayde/previews/second");
        std::fs::create_dir_all(&second).unwrap();
        assert_eq!(make().restore(&plan, &second).await.unwrap(), "bytecode");
        assert_eq!(
            std::fs::read_to_string(second.join("host.mjs")).unwrap(),
            "haxe support"
        );
        std::fs::write(build.join("app.wasm"), "wasm").unwrap();
        std::fs::write(build.join("index.html"), "page").unwrap();
        assert!(cache.publish(&plan, &build, "wasm").await.unwrap());
        assert_eq!(make().restore(&plan, &second).await.unwrap(), "wasm");
        std::fs::write(host.join("ash"), "updated backend").unwrap();
        let updated = cache.plan(recipe.clone()).await.unwrap();
        assert_eq!(plan.bytecode, updated.bytecode);
        assert_ne!(plan.wasm, updated.wasm);
        assert_eq!(cache.restore(&updated, &second).await.unwrap(), "bytecode");
        std::fs::write(host.join("ash"), "initial").unwrap();
        std::fs::write(
            root.join(".rayde/preview-cache/wasm/files/app.wasm"),
            "corrupted",
        )
        .unwrap();
        assert_eq!(cache.restore(&plan, &second).await.unwrap(), "bytecode");
        std::fs::write(root.join("src/Main.hx"), "changed").unwrap();
        assert!(!cache.publish(&plan, &build, "wasm").await.unwrap());
        let edited = cache.plan(recipe.clone()).await.unwrap();
        assert_ne!(plan.bytecode, edited.bytecode);
        assert_eq!(cache.restore(&edited, &second).await.unwrap(), "miss");
        std::fs::write(root.join("src/Main.hx"), "initial").unwrap();
        std::fs::write(library.join("Dependency.hx"), "changed").unwrap();
        assert_ne!(
            cache.plan(recipe.clone()).await.unwrap().bytecode,
            plan.bytecode
        );
        std::fs::write(library.join("Dependency.hx"), "initial").unwrap();
        std::fs::write(library.join("Added.hx"), "new module").unwrap();
        assert_ne!(
            cache.plan(recipe.clone()).await.unwrap().bytecode,
            plan.bytecode
        );
        std::fs::remove_file(library.join("Added.hx")).unwrap();
        let mut flags = recipe.clone();
        flags.args.extend(["-D".into(), "debug".into()]);
        assert_ne!(cache.plan(flags).await.unwrap().bytecode, plan.bytecode);
        cache.clear().await.unwrap();
        assert_eq!(cache.restore(&plan, &second).await.unwrap(), "miss");
        let huge = std::fs::File::create(build.join("huge.bin")).unwrap();
        huge.set_len(MAX_BYTES + 1).unwrap();
        assert!(
            cache
                .publish(&cache.plan(recipe).await.unwrap(), &build, "bytecode")
                .await
                .is_err()
        );
    }
}
