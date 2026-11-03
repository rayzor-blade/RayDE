//! Desktop tabs and browser sessions share the same recovery and cloud document provider.
use crate::{
    dir_store::DirStore,
    docs::DocHub,
    editor::Editors,
    error::{Result, SessionError},
    session::Out,
};
use rayde_sync::client::{Config, documents};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, OnceLock, Weak},
};

type Hub = DocHub<DirStore>;
static HUBS: OnceLock<tokio::sync::Mutex<HashMap<String, Weak<Hub>>>> = OnceLock::new();

pub async fn open(
    config: Config,
    state_root: Option<PathBuf>,
    out: Out,
) -> Result<Arc<Editors<DirStore>>> {
    let (config, root, key) = tokio::task::spawn_blocking(move || {
        let mut config = documents::desktop_config(&config)
            .map_err(|error| SessionError::new("not-synced", error.message))?;
        config.root = std::fs::canonicalize(&config.root).map_err(crate::dir_store::io_error)?;
        let key = crate::checkpoint::digest(
            &serde_json::to_vec(&(
                &config.root,
                config.gateway.trim_end_matches('/'),
                &config.workspace,
                &config.account,
            ))
            .unwrap(),
        );
        let root = match state_root {
            Some(root) => root,
            None => PathBuf::from(
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).ok_or_else(
                    || {
                        SessionError::new(
                            "no-home",
                            "The user's private recovery directory is unavailable.",
                        )
                    },
                )?,
            )
            .join(".rayde-session")
            .join("cloud-desktop"),
        };
        Ok::<_, SessionError>((config, root.join(&key), key))
    })
    .await
    .map_err(|_| SessionError::new("failed", "Could not open desktop sync."))??;
    let mut hubs = HUBS.get_or_init(Default::default).lock().await;
    hubs.retain(|_, hub| hub.strong_count() > 0);
    let key = format!("{}:{}", root.display(), key);
    let hub = if let Some(hub) = hubs.get(&key).and_then(Weak::upgrade) {
        hub
    } else {
        let path = config.root.clone();
        let store = tokio::task::spawn_blocking(move || DirStore::with_state_root(path, root))
            .await
            .map_err(|_| SessionError::new("failed", "Could not open private recovery."))?
            .map_err(crate::dir_store::io_error)?;
        let hub = Arc::new(DocHub::new(Arc::new(store), Arc::new(|_| {})));
        hub.set_cloud(Arc::new(crate::cloud_gateway::Gateway::desktop(config)));
        hubs.insert(key, Arc::downgrade(&hub));
        hub
    };
    Ok(Editors::new(hub, out))
}
