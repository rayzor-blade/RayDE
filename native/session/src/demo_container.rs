//! Fixed-image entrypoint for anonymous Cloudflare demo compute. No checkout or build on boot.
use crate::{checkpoint::digest, demo_seed::DemoSeed, server::Options};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::{self, Write},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub const VARIABLES: [&str; 8] = [
    "RAYDE_DEMO_ID",
    "RAYDE_DEMO_LEASE",
    "RAYDE_DEMO_RELEASE",
    "RAYDE_DEMO_TOOLCHAIN",
    "RAYDE_DEMO_TOKEN",
    "RAYDE_DEMO_GENERATION",
    "RAYDE_DEMO_EXPIRES",
    "RAYDE_DEMO_ORIGIN",
];

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    pub version: u32,
    pub id: String,
    pub release: String,
    pub toolchain: String,
    pub generation: u64,
    /// Unix seconds, fixed at admission; reconnecting cannot extend it.
    pub expires: u64,
}

#[derive(Serialize, Deserialize, PartialEq, Eq)]
struct Binding {
    health: Health,
    lease: String,
    token_sha256: String,
}

struct Layout {
    image: PathBuf,
    root: PathBuf,
    state: PathBuf,
}

fn invalid(message: &str) -> io::Error {
    io::Error::other(message)
}
fn hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn key(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
fn seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn configuration(
    values: &HashMap<String, String>,
    now: u64,
) -> io::Result<(Binding, String, String)> {
    let get = |name: &str| {
        values
            .get(name)
            .cloned()
            .ok_or_else(|| invalid("The demo container lease is incomplete."))
    };
    let id = get("RAYDE_DEMO_ID")?;
    let lease = get("RAYDE_DEMO_LEASE")?;
    let release = get("RAYDE_DEMO_RELEASE")?;
    let toolchain = get("RAYDE_DEMO_TOOLCHAIN")?;
    let token = get("RAYDE_DEMO_TOKEN")?;
    let generation = get("RAYDE_DEMO_GENERATION")?
        .parse::<u64>()
        .map_err(|_| invalid("Invalid demo generation."))?;
    let expires = get("RAYDE_DEMO_EXPIRES")?
        .parse::<u64>()
        .map_err(|_| invalid("Invalid demo expiry."))?;
    let origin = get("RAYDE_DEMO_ORIGIN")?;
    let uri = origin
        .parse::<axum::http::Uri>()
        .map_err(|_| invalid("Invalid demo origin."))?;
    if !key(&id)
        || !key(&lease)
        || !hex(&release)
        || !hex(&toolchain)
        || !hex(&token)
        || generation != 1
        || expires <= now
        || expires - now > 900
        || uri.scheme_str() != Some("https")
        || uri.authority().is_none()
        || uri.authority().is_some_and(|a| a.as_str().contains('@'))
        || uri.path_and_query().is_some_and(|p| p.as_str() != "/")
        || origin.ends_with('/')
        || URL_SAFE_NO_PAD.encode(Sha256::digest(format!("demo:{release}:{lease}").as_bytes()))
            != id
    {
        return Err(invalid("The demo container lease is invalid or expired."));
    }
    Ok((
        Binding {
            health: Health {
                version: 1,
                id,
                release,
                toolchain,
                generation,
                expires,
            },
            lease,
            token_sha256: digest(token.as_bytes()),
        },
        token,
        origin,
    ))
}

fn bounded_file(path: &Path, maximum: u64) -> io::Result<Vec<u8>> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.len() > maximum {
        return Err(invalid("Invalid demo image file."));
    }
    std::fs::read(path)
}

fn prepare(values: &HashMap<String, String>, layout: Layout, now: u64) -> io::Result<Options> {
    let (binding, token, origin) = configuration(values, now)?;
    let manifest = bounded_file(&layout.image.join("toolchain.json"), 4 * 1024 * 1024)?;
    let identity: serde_json::Value = serde_json::from_slice(&manifest)
        .map_err(|_| invalid("Invalid demo toolchain manifest."))?;
    if digest(&manifest) != binding.health.toolchain || identity["version"] != 1 {
        return Err(invalid("The demo toolchain does not match its image."));
    }
    let bundle = layout.image.join("demo-workspace.json");
    let seed_bytes = bounded_file(&bundle, 3 * 1024 * 1024)?;
    DemoSeed::parse(&seed_bytes, &binding.health.release)
        .map_err(|_| invalid("The demo image does not match its source release."))?;
    for path in [&layout.root, &layout.state] {
        if !std::fs::symlink_metadata(path)?.is_dir() {
            return Err(invalid(
                "The demo requires private workspace and state directories.",
            ));
        }
    }
    let binding_path = layout.state.join("container.json");
    match std::fs::symlink_metadata(&binding_path) {
        Ok(_) => {
            let previous: Binding = serde_json::from_slice(&bounded_file(&binding_path, 4096)?)
                .map_err(|_| invalid("Invalid demo container binding."))?;
            if previous != binding {
                return Err(invalid("This demo filesystem belongs to another lease."));
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            DemoSeed::verify_files(&seed_bytes, &binding.health.release, &layout.root)?;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&binding_path)?;
            file.write_all(&serde_json::to_vec(&binding)?)?;
            file.sync_all()?;
        }
        Err(e) => return Err(e),
    }
    let mut options = Options::new(&layout.root);
    options.state_root = Some(layout.state);
    options.demo_seed = Some((bundle, binding.health.release.clone()));
    options.container_health = Some(binding.health);
    options.address = ([0, 0, 0, 0], 8080).into();
    options.token = Some(token);
    options.origins = vec![origin];
    options.exec = true;
    options.environment = crate::environment::load(&layout.image.join("environment.json"), true)?;
    options
        .environment
        .insert("HOME".into(), "/workspace".into());
    options
        .environment
        .insert("SHELL".into(), "/bin/bash".into());
    options.extension_host = Some(layout.image.join("bin/rayde-extension-host"));
    options.extensions = Some(layout.image.join("extensions"));
    options.read_roots = ["haxelib", "haxe-std", "haxe/std"]
        .iter()
        .map(|p| layout.image.join(p))
        .collect();
    options.preview_tools = Some(layout.image.join("preview"));
    Ok(options)
}

/// Run a prepared image using the private lease captured by the entrypoint.
pub fn run(values: &HashMap<String, String>) -> io::Result<()> {
    let options = prepare(
        values,
        Layout {
            image: "/opt/rayde".into(),
            root: "/workspace/project".into(),
            state: "/state".into(),
        },
        seconds(),
    )?;
    let expires = options.container_health.as_ref().unwrap().expires;
    tokio::runtime::Builder::new_multi_thread().enable_all().build()?.block_on(async move {
        let running = crate::server::start(options).await?;
        eprintln!("Demo session ready.");
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(expires.saturating_sub(seconds()))) => {},
            _ = tokio::signal::ctrl_c() => {},
        }
        running.shutdown().await;
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use serde_json::json;

    fn fixture() -> (tempfile::TempDir, HashMap<String, String>, Layout) {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("image");
        let root = dir.path().join("project");
        let state = dir.path().join("state");
        for path in [&image, &root, &state] {
            std::fs::create_dir(path).unwrap();
        }
        let bundle = serde_json::to_vec(&json!({"version":1,"root":"/work/pocket-studio","project":"pocket-studio/build.hxml","entries":[
            {"path":"/work/pocket-studio","directory":true},
            {"path":"/work/pocket-studio/build.hxml","directory":false,"data":STANDARD.encode("-main Main\n")},
            {"path":"/work/pocket-studio/logo.bin","directory":false,"data":STANDARD.encode([0,255])}
        ]})).unwrap();
        let release = digest(&bundle);
        let lease = "L".repeat(43);
        let manifest = br#"{"version":1}"#;
        std::fs::write(image.join("toolchain.json"), manifest).unwrap();
        std::fs::write(image.join("demo-workspace.json"), bundle).unwrap();
        std::fs::write(image.join("environment.json"), "{}").unwrap();
        std::fs::write(root.join("build.hxml"), "-main Main\n").unwrap();
        std::fs::write(root.join("logo.bin"), [0, 255]).unwrap();
        let id =
            URL_SAFE_NO_PAD.encode(Sha256::digest(format!("demo:{release}:{lease}").as_bytes()));
        let values = [
            id,
            lease,
            release,
            digest(manifest),
            "a".repeat(64),
            "1".into(),
            "1500".into(),
            "https://rayde.org".into(),
        ];
        (
            dir,
            VARIABLES
                .into_iter()
                .zip(values)
                .map(|(k, v)| (k.to_owned(), v))
                .collect(),
            Layout { image, root, state },
        )
    }
    #[test]
    fn validates_image_and_lease_without_overwriting_a_used_workspace() {
        let (_dir, values, layout) = fixture();
        let again = || Layout {
            image: layout.image.clone(),
            root: layout.root.clone(),
            state: layout.state.clone(),
        };
        let options = prepare(&values, again(), 1000).unwrap();
        assert!(options.exec);
        assert!(
            options
                .environment
                .keys()
                .all(|key| !VARIABLES.contains(&key.as_str()))
        );
        std::fs::write(layout.root.join("build.hxml"), "visitor edit").unwrap();
        assert!(prepare(&values, again(), 1001).is_ok());
        assert_eq!(
            std::fs::read_to_string(layout.root.join("build.hxml")).unwrap(),
            "visitor edit"
        );
        let mut changed = values.clone();
        changed.insert("RAYDE_DEMO_TOKEN".into(), "b".repeat(64));
        assert!(prepare(&changed, again(), 1001).is_err());
        assert!(prepare(&values, again(), 1500).is_err());
        std::fs::write(layout.image.join("toolchain.json"), "{}").unwrap();
        assert!(prepare(&values, again(), 1000).is_err());
    }
    #[test]
    fn refuses_changed_seed_symlinks_and_invalid_admission() {
        let (_dir, values, layout) = fixture();
        let again = || Layout {
            image: layout.image.clone(),
            root: layout.root.clone(),
            state: layout.state.clone(),
        };
        std::fs::write(layout.root.join("logo.bin"), [0, 254]).unwrap();
        assert!(prepare(&values, again(), 1000).is_err());
        assert!(!layout.state.join("container.json").exists());
        for (key, value) in [
            ("RAYDE_DEMO_EXPIRES", "1901"),
            ("RAYDE_DEMO_GENERATION", "2"),
            ("RAYDE_DEMO_ORIGIN", "https://rayde.org/path"),
            ("RAYDE_DEMO_ID", &"x".repeat(43)),
        ] {
            let mut changed = values.clone();
            changed.insert(key.into(), value.into());
            assert!(configuration(&changed, 1000).is_err());
        }
        #[cfg(unix)]
        {
            std::fs::remove_file(layout.root.join("logo.bin")).unwrap();
            let outside = layout.root.parent().unwrap().join("logo.bin");
            std::fs::write(&outside, [0, 255]).unwrap();
            std::os::unix::fs::symlink(outside, layout.root.join("logo.bin")).unwrap();
            assert!(prepare(&values, again(), 1000).is_err());
        }
    }
    #[tokio::test]
    async fn readiness_is_private_metadata_and_preserves_socket_authentication() {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::Message;
        let (_dir, values, layout) = fixture();
        let mut options = prepare(&values, layout, 1000).unwrap();
        options.address = ([127, 0, 0, 1], 0).into();
        options.exec = false;
        options.read_roots.clear();
        options.preview_tools = None;
        options.extension_host = None;
        options.extensions = None;
        let expected = serde_json::to_value(options.container_health.as_ref().unwrap()).unwrap();
        let running = crate::server::start(options).await.unwrap();
        let response = reqwest::get(format!("{}/health", running.url()))
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        let text = response.text().await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&text).unwrap(),
            expected
        );
        assert!(!text.contains(&values["RAYDE_DEMO_TOKEN"]));
        let (mut socket, _) = tokio_tungstenite::connect_async(format!("ws://{}/session",running.address)).await.unwrap();
        for (id,token,allowed) in [(1,"foreign",false),(2,values["RAYDE_DEMO_TOKEN"].as_str(),true)] {
            socket.send(Message::text(json!({"id":id,"op":"hello","token":token}).to_string())).await.unwrap();
            let reply=socket.next().await.unwrap().unwrap().into_text().unwrap();
            let value:serde_json::Value=serde_json::from_str(&reply).unwrap();
            assert_eq!(value["ok"],allowed);
        }
        socket.close(None).await.unwrap();
        running.shutdown().await;
    }
}
