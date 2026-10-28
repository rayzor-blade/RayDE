use rand::RngCore;
use std::{
    fs,
    io::{self, Write},
    path::Path,
};

/// Publish complete random IDs atomically, including when several sessions start together.
pub(crate) fn persistent_id(path: &Path) -> io::Result<String> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("Missing identity directory"))?;
    let mut directories = fs::DirBuilder::new();
    directories.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directories.mode(0o700);
    }
    let mut missing = Vec::new();
    let mut probe = parent;
    while !probe.try_exists()? {
        missing.push(probe.to_path_buf());
        probe = probe.parent().ok_or_else(||io::Error::other("Missing identity ancestor"))?;
    }
    directories.create(parent)?;
    #[cfg(unix)]
    for directory in missing {
        fs::File::open(&directory)?.sync_all()?;
        if let Some(parent) = directory.parent() {fs::File::open(parent)?.sync_all()?;}
    }
    if !path.try_exists()? {
        let mut random = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut random);
        let id = random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let temporary = parent.join(format!(".identity-{}-{id}", std::process::id()));
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        let published = (|| {
            file.write_all(id.as_bytes())?;
            file.sync_all()?;
            match fs::hard_link(&temporary, path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
                Err(error) => Err(error),
            }
        })();
        drop(file);
        let _ = fs::remove_file(temporary);
        published?;
        #[cfg(unix)]
        fs::File::open(parent)?.sync_all()?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() != 64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid session cache identity",
        ));
    }
    let id = fs::read_to_string(path)?;
    if !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid session cache identity",
        ));
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identities_are_atomic_persistent_and_private() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("identity");
        let ids = std::thread::scope(|scope| {
            let workers = (0..8)
                .map(|_| scope.spawn(|| persistent_id(&path).unwrap()))
                .collect::<Vec<_>>();
            workers
                .into_iter()
                .map(|worker| worker.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert!(ids.iter().all(|id| *id == ids[0]));
        assert_eq!(persistent_id(&path).unwrap(), ids[0]);
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::write(&path, "invalid").unwrap();
        assert!(persistent_id(&path).is_err());
    }
}
