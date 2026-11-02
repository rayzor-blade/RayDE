//! Putting a manifest's symbolic link on a disk. Targets are `/`-separated in the manifest; Windows spells them with `\` and only makes links with a
//! privilege, so there a link that cannot be made becomes a plain file holding its target text, and nothing is refused.
use std::{fs, io, path::Path};

/// What was placed at the path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placed {
    Link,
    /// A plain file holding the target, because the system would not make a link.
    Stand,
}

/// A manifest target as the system spells it.
pub fn native_target(target: &str) -> String {
    if cfg!(windows) { target.replace('/', "\\") } else { target.to_string() }
}

/// A target read from the disk as the manifest spells it.
pub fn manifest_target(target: &str) -> String {
    if cfg!(windows) { target.replace('\\', "/") } else { target.to_string() }
}

#[cfg(unix)]
fn symlink(target: &str, _directory: bool, at: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, at)
}

#[cfg(windows)]
fn symlink(target: &str, directory: bool, at: &Path) -> io::Result<()> {
    if directory { std::os::windows::fs::symlink_dir(target, at) } else { std::os::windows::fs::symlink_file(target, at) }
}

#[cfg(not(any(unix, windows)))]
fn symlink(_target: &str, _directory: bool, _at: &Path) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "no links here"))
}

/// Replaces whatever is at `at` with a link to `target` (as the manifest spells it), made beside it and moved into place so no half-made link is seen.
pub fn place(at: &Path, target: &str) -> io::Result<Placed> {
    if let Some(parent) = at.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = at.with_extension(format!("rayde-link-{}", std::process::id()));
    let _ = fs::remove_file(&temporary);
    let directory = at.parent().is_some_and(|parent| parent.join(native_target(target)).is_dir());
    let placed = match symlink(&native_target(target), directory, &temporary) {
        Ok(()) => Placed::Link,
        Err(_) if cfg!(windows) => {
            fs::write(&temporary, target)?;
            Placed::Stand
        }
        Err(error) => return Err(error),
    };
    // A link, or a directory link on Windows, is not replaced by a rename over it.
    if fs::symlink_metadata(at).is_ok() {
        if fs::symlink_metadata(at).is_ok_and(|meta| meta.is_dir()) {
            fs::remove_dir(at).or_else(|_| fs::remove_file(at))?;
        } else {
            fs::remove_file(at)?;
        }
    }
    fs::rename(&temporary, at)?;
    Ok(placed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn targets_keep_the_manifest_spelling_whichever_way_the_system_writes_them() {
        for target in ["doc.txt", "src/lib", "../up/one", "a/./b"] {
            assert_eq!(manifest_target(&native_target(target)), target);
        }
        if cfg!(windows) {
            assert_eq!(native_target("src/lib"), "src\\lib");
        } else {
            assert_eq!(native_target("src/lib"), "src/lib");
        }
    }

    #[test]
    fn a_link_is_placed_over_a_file_and_over_another_link_and_reads_back_the_same() {
        let dir = tempfile::tempdir().unwrap();
        let at = dir.path().join("sub").join("latest");
        for target in ["doc.txt", "../two.txt"] {
            let placed = place(&at, target).unwrap();
            match placed {
                Placed::Link => assert_eq!(manifest_target(fs::read_link(&at).unwrap().to_str().unwrap()), target),
                Placed::Stand => assert_eq!(fs::read_to_string(&at).unwrap(), target),
            }
            assert!(cfg!(windows) || placed == Placed::Link, "only Windows may do without a link");
        }
        fs::remove_file(&at).unwrap();
        fs::write(&at, "plain").unwrap();
        place(&at, "doc.txt").unwrap();
        assert_ne!(fs::read(&at).ok(), Some(b"plain".to_vec()));
        assert!(fs::read_dir(at.parent().unwrap()).unwrap().count() == 1, "no temporary is left beside it");
    }

    #[test]
    fn a_link_to_a_directory_is_placed_as_one() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("real")).unwrap();
        let at = dir.path().join("alias");
        if place(&at, "real").unwrap() == Placed::Link {
            assert!(fs::symlink_metadata(&at).unwrap().file_type().is_symlink());
            assert!(at.is_dir());
        }
        assert_eq!(place(&at, "real").unwrap(), place(&at, "real").unwrap(), "placing again over what it made works");
    }
}
