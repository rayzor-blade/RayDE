//! The desktop engine against real Git repositories.
use rayde_sync::{
    exclude::Selection,
    ids::WorkspaceId,
    lifecycle::Limits,
    manifest::{FileKind, Origin, Reason},
    scan::{Options, ScanError, UnsavedBuffer, scan},
};
use std::{fs, path::Path, process::Command};
use tempfile::TempDir;

fn git(root: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn repo() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    git(dir.path(), &["init", "-q", "-b", "main"]);
    dir
}

fn write(root: &Path, path: &str, content: &[u8]) {
    let full = root.join(path);
    fs::create_dir_all(full.parent().unwrap()).unwrap();
    fs::write(full, content).unwrap();
}

fn commit(root: &Path, message: &str) {
    git(root, &["add", "-A"]);
    git(root, &["commit", "-q", "-m", message]);
}

fn options(history: bool) -> Options {
    Options { workspace: WorkspaceId::from_random(&[5; 32]), base_generation: 0, device: "test".into(), now_ms: 1, limits: Limits::default(), selection: Selection::default(), history, buffers: vec![] }
}

fn paths(snapshot: &rayde_sync::scan::Snapshot) -> Vec<&str> {
    snapshot.manifest.files.iter().map(|f| f.path.as_str()).collect()
}

fn omitted(snapshot: &rayde_sync::scan::Snapshot, path: &str) -> Option<Reason> {
    snapshot.manifest.omissions.iter().find(|o| o.path == path).map(|o| o.reason)
}

#[test]
fn a_working_tree_is_captured_with_its_git_state_and_nothing_is_changed() {
    let dir = repo();
    let root = dir.path();
    write(root, "src/Main.hx", b"class Main {}\n");
    write(root, "README.md", b"# game\n");
    write(root, ".gitignore", b"*.log\nbin/\n");
    write(root, "gone.txt", b"soon deleted\n");
    commit(root, "first");
    // After the commit: a modification, a staged change, a deletion, an untracked file and ignored ones.
    write(root, "src/Main.hx", b"class Main { var x:Int; }\n");
    write(root, "README.md", b"# game, staged\n");
    git(root, &["add", "README.md"]);
    fs::remove_file(root.join("gone.txt")).unwrap();
    write(root, "notes.txt", b"todo\n");
    write(root, "debug.log", b"ignored\n");
    write(root, "bin/app.hl", b"ignored output\n");
    let before = git(root, &["status", "--porcelain=v2", "--branch"]);

    let snapshot = scan(root, &options(true)).unwrap();
    let m = &snapshot.manifest;
    assert_eq!(paths(&snapshot), vec![".gitignore", "README.md", "notes.txt", "src/Main.hx"]);
    assert_eq!(m.files.iter().find(|f| f.path == "notes.txt").unwrap().origin, Origin::Untracked);
    assert_eq!(m.files.iter().find(|f| f.path == "src/Main.hx").unwrap().origin, Origin::Tracked);
    assert_eq!(m.git.branch.as_deref(), Some("main"));
    assert_eq!(m.git.head.as_deref(), Some(git(root, &["rev-parse", "HEAD"]).as_str()));
    assert_eq!(m.git.deleted, vec!["gone.txt"], "a tracked file that is gone is a delete to apply");
    assert!(!m.git.unborn);
    // The index carries the staged README (a different object than HEAD's) apart from the working tree's content.
    let readme = m.git.index.iter().find(|e| e.path == "README.md").unwrap();
    assert_eq!(readme.oid, git(root, &["rev-parse", ":README.md"]));
    assert_ne!(readme.oid, git(root, &["rev-parse", "HEAD:README.md"]));
    assert!(m.validate(&Limits::default()).is_empty(), "{:?}", m.validate(&Limits::default()));
    // Ignored files are not even candidates, and Git's own directory is not in the manifest at all.
    assert!(!paths(&snapshot).iter().any(|p| p.starts_with(".git/") || p.ends_with(".log") || p.starts_with("bin/")));
    assert_eq!(git(root, &["status", "--porcelain=v2", "--branch"]), before, "the repository is exactly as it was");
}

#[test]
fn credentials_caches_and_session_state_are_left_out_with_reasons_and_collapsed() {
    let dir = repo();
    let root = dir.path();
    write(root, "src/Main.hx", b"x");
    write(root, ".env", b"TOKEN=abc\n");
    write(root, "config/.env.production", b"X=1\n");
    write(root, ".env.example", b"TOKEN=\n");
    write(root, "node_modules/a/index.js", b"x");
    write(root, "node_modules/b/index.js", b"y");
    write(root, ".rayde/run/run.log", b"log");
    write(root, ".rayde/settings.json", b"{}");
    write(root, "export/html5/bin/index.html", b"<html>");
    write(root, ".DS_Store", b"junk");
    commit(root, "all of it, tracked");
    let snapshot = scan(root, &options(false)).unwrap();
    assert_eq!(paths(&snapshot), vec![".env.example", ".rayde/settings.json", "export/html5/bin/index.html", "src/Main.hx"], "tracked output is source here, and the example env is a template");
    assert_eq!(omitted(&snapshot, ".env"), Some(Reason::Secret), "tracked, yet a secret needs a decision");
    assert_eq!(omitted(&snapshot, "config/.env.production"), Some(Reason::Secret));
    assert_eq!(omitted(&snapshot, "node_modules"), Some(Reason::Cache), "a cache is one omission, not one per file");
    assert!(snapshot.manifest.omissions.iter().filter(|o| o.path.starts_with("node_modules")).count() == 1);
    assert_eq!(omitted(&snapshot, ".rayde/run/run.log"), Some(Reason::SessionState));
    assert_eq!(omitted(&snapshot, ".DS_Store"), Some(Reason::OsFile));
    // The person includes the secret on purpose.
    let mut chosen = options(false);
    chosen.selection.include.push(".env".into());
    let snapshot = scan(root, &chosen).unwrap();
    assert!(paths(&snapshot).contains(&".env"));
    assert_eq!(omitted(&snapshot, "config/.env.production"), Some(Reason::Secret), "only the one chosen");
}

#[test]
fn untracked_generated_output_is_left_out_and_untracked_source_is_not() {
    let dir = repo();
    let root = dir.path();
    write(root, "src/Main.hx", b"x");
    commit(root, "base");
    write(root, "bin/app.hl", b"output");
    write(root, "export/js/app.js", b"output");
    write(root, "src/New.hx", b"new");
    let snapshot = scan(root, &options(false)).unwrap();
    assert_eq!(paths(&snapshot), vec!["src/Main.hx", "src/New.hx"]);
    assert_eq!(omitted(&snapshot, "bin"), Some(Reason::Cache));
    assert_eq!(omitted(&snapshot, "export"), Some(Reason::Cache));
}

#[cfg(unix)]
#[test]
fn symlinks_inside_the_tree_are_kept_as_links_and_others_are_reported() {
    let dir = repo();
    let root = dir.path();
    write(root, "src/lib/a.hx", b"x");
    std::os::unix::fs::symlink("src/lib", root.join("current")).unwrap();
    std::os::unix::fs::symlink("../../outside", root.join("src/up")).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", root.join("abs")).unwrap();
    commit(root, "links");
    let snapshot = scan(root, &options(false)).unwrap();
    let link = snapshot.manifest.files.iter().find(|f| f.path == "current").unwrap();
    assert_eq!((link.kind, link.link.as_deref(), link.chunks.len()), (FileKind::Symlink, Some("src/lib"), 0));
    assert_eq!(omitted(&snapshot, "src/up"), Some(Reason::UnsafeLink));
    assert_eq!(omitted(&snapshot, "abs"), Some(Reason::UnsafeLink));
    assert!(snapshot.manifest.validate(&Limits::default()).is_empty());
}

#[cfg(unix)]
#[test]
fn an_executable_keeps_its_bit() {
    use std::os::unix::fs::PermissionsExt;
    let dir = repo();
    let root = dir.path();
    write(root, "run.sh", b"#!/bin/sh\n");
    fs::set_permissions(root.join("run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
    write(root, "data.txt", b"x");
    commit(root, "x");
    let snapshot = scan(root, &options(false)).unwrap();
    let kind = |p: &str| snapshot.manifest.files.iter().find(|f| f.path == p).unwrap().kind;
    assert_eq!((kind("run.sh"), kind("data.txt")), (FileKind::Executable, FileKind::Regular));
}

#[test]
fn a_large_file_is_chunked_and_each_chunk_reads_back_checked_against_its_hash() {
    let dir = repo();
    let root = dir.path();
    let mut state = 7u64;
    let big: Vec<u8> = (0..5 * 1024 * 1024)
        .map(|_| {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (state >> 33) as u8
        })
        .collect();
    write(root, "assets/big.bin", &big);
    commit(root, "big");
    let snapshot = scan(root, &options(false)).unwrap();
    let file = &snapshot.manifest.files[0];
    assert!(file.chunks.len() > 1);
    assert_eq!(file.size, big.len() as u64);
    assert_eq!(file.hash, rayde_sync::chunk::sha256_hex(&big));
    let mut joined = Vec::new();
    for c in &file.chunks {
        joined.extend(snapshot.read_chunk(&c.hash).unwrap());
    }
    assert_eq!(joined, big);
    assert_eq!(snapshot.chunks().map(|(_, s)| s as u64).sum::<u64>(), snapshot.manifest.totals.stored_bytes);
    // The file changes after the scan: the upload must fail, not send other bytes under the old hash.
    let mut changed = big.clone();
    changed[0] ^= 0xff;
    fs::write(root.join("assets/big.bin"), &changed).unwrap();
    let error = snapshot.read_chunk(&file.chunks[0].hash).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    assert!(snapshot.read_chunk(&"0".repeat(64)).is_err());
}

#[test]
fn a_file_over_the_limit_is_left_out_not_read() {
    let dir = repo();
    let root = dir.path();
    write(root, "small.txt", b"x");
    write(root, "huge.bin", &vec![1u8; 20_000]);
    commit(root, "x");
    let mut tight = options(false);
    tight.limits.max_file_bytes = 10_000;
    let snapshot = scan(root, &tight).unwrap();
    assert_eq!(paths(&snapshot), vec!["small.txt"]);
    assert_eq!(omitted(&snapshot, "huge.bin"), Some(Reason::TooLarge));
}

#[test]
fn a_repository_with_no_commit_has_files_and_an_index_and_no_history() {
    let dir = repo();
    let root = dir.path();
    write(root, "a.hx", b"x");
    write(root, "b.hx", b"y");
    git(root, &["add", "a.hx"]);
    let snapshot = scan(root, &options(true)).unwrap();
    let m = &snapshot.manifest;
    assert!(m.git.unborn && m.git.head.is_none() && m.git.history.is_none());
    assert_eq!(m.git.branch.as_deref(), Some("main"), "the branch it will be on once it has a commit");
    assert_eq!(paths(&snapshot), vec!["a.hx", "b.hx"]);
    assert_eq!(m.git.index.iter().map(|e| e.path.as_str()).collect::<Vec<_>>(), vec!["a.hx"], "only a.hx is staged");
    assert!(m.validate(&Limits::default()).is_empty());
}

#[test]
fn history_travels_as_a_bundle_that_rebuilds_the_repository_and_leaves_secrets_in_git_config_behind() {
    let dir = repo();
    let root = dir.path();
    write(root, "a.hx", b"one");
    commit(root, "one");
    git(root, &["checkout", "-q", "-b", "feature"]);
    write(root, "a.hx", b"two");
    commit(root, "two, unpushed");
    git(root, &["config", "credential.helper", "store --file=/tmp/never-uploaded"]);
    git(root, &["config", "remote.origin.url", "https://user:hunter2@example.com/x.git"]);
    let snapshot = scan(root, &options(true)).unwrap();
    let history = snapshot.manifest.git.history.as_ref().expect("history is included");
    assert!(history.refs.iter().any(|r| r == "refs/heads/feature") && history.refs.iter().any(|r| r == "refs/heads/main"), "{:?}", history.refs);
    let mut bundle = Vec::new();
    for c in &history.chunks {
        bundle.extend(snapshot.read_chunk(&c.hash).unwrap());
    }
    assert_eq!(rayde_sync::chunk::sha256_hex(&bundle), history.hash);
    // The bundle holds objects and refs, not configuration.
    assert!(!String::from_utf8_lossy(&bundle).contains("hunter2") && !String::from_utf8_lossy(&bundle).contains("credential"));
    // A fresh repository rebuilt from it has the unpushed commit.
    let restored = tempfile::tempdir().unwrap();
    let file = restored.path().join("h.bundle");
    fs::write(&file, &bundle).unwrap();
    git(restored.path(), &["clone", "-q", "-b", "feature", file.to_str().unwrap(), "out"]);
    assert_eq!(git(&restored.path().join("out"), &["log", "--format=%s", "-2"]), "two, unpushed\none");
    assert_eq!(snapshot.manifest.git.head.as_deref(), Some(git(&restored.path().join("out"), &["rev-parse", "HEAD"]).as_str()));
    // Without history there is no bundle, and the person is told what that costs.
    let bare = scan(root, &options(false)).unwrap();
    assert!(bare.manifest.git.history.is_none() && bare.notes.iter().any(|n| n.contains("History is not included")));
    // The temporary bundle is removed when the snapshot goes.
    drop(snapshot);
}

#[test]
fn a_history_over_the_budget_is_dropped_with_a_note_and_the_tree_still_syncs() {
    let dir = repo();
    let root = dir.path();
    write(root, "a.hx", &vec![9u8; 50_000]);
    commit(root, "x");
    let mut tight = options(true);
    tight.limits.max_history_bytes = 100;
    let snapshot = scan(root, &tight).unwrap();
    assert!(snapshot.manifest.git.history.is_none());
    assert!(snapshot.notes.iter().any(|n| n.contains("working tree only")), "{:?}", snapshot.notes);
    assert_eq!(paths(&snapshot), vec!["a.hx"]);
}

#[test]
fn unsaved_buffers_are_kept_apart_from_the_saved_file_and_know_their_base() {
    let dir = repo();
    let root = dir.path();
    write(root, "src/Main.hx", b"saved\n");
    commit(root, "x");
    let mut with = options(false);
    with.buffers = vec![UnsavedBuffer { path: "src/Main.hx".into(), content: b"saved\nplus an unsaved line\n".to_vec() }, UnsavedBuffer { path: "src/New.hx".into(), content: b"never saved".to_vec() }];
    let snapshot = scan(root, &with).unwrap();
    let m = &snapshot.manifest;
    assert_eq!(fs::read(root.join("src/Main.hx")).unwrap(), b"saved\n", "the saved file is untouched");
    let main = m.buffers.iter().find(|b| b.path == "src/Main.hx").unwrap();
    assert_eq!(main.base.as_deref(), Some(m.files.iter().find(|f| f.path == "src/Main.hx").unwrap().hash.as_str()));
    assert_eq!(m.buffers.iter().find(|b| b.path == "src/New.hx").unwrap().base, None, "a buffer for a file that was never saved has no base");
    assert_eq!(snapshot.read_chunk(&main.chunks[0].hash).unwrap(), b"saved\nplus an unsaved line\n");
    assert!(m.validate(&Limits::default()).is_empty());
}

#[test]
fn a_submodule_is_listed_and_not_dereferenced_and_lfs_is_noted() {
    let dir = repo();
    let root = dir.path();
    let inner = tempfile::tempdir().unwrap();
    git(inner.path(), &["init", "-q", "-b", "main"]);
    write(inner.path(), "lib.hx", b"lib");
    commit(inner.path(), "lib");
    write(root, "src/Main.hx", b"x");
    write(root, ".gitattributes", b"*.psd filter=lfs diff=lfs merge=lfs -text\n");
    commit(root, "base");
    git(root, &["submodule", "add", "-q", inner.path().to_str().unwrap(), "vendor/lib"]);
    let snapshot = scan(root, &options(false)).unwrap();
    assert_eq!(snapshot.manifest.git.submodules, vec!["vendor/lib"]);
    assert_eq!(omitted(&snapshot, "vendor/lib"), Some(Reason::Submodule));
    assert!(!paths(&snapshot).iter().any(|p| p.starts_with("vendor/lib/")));
    assert!(snapshot.manifest.git.lfs && snapshot.notes.iter().any(|n| n.contains("LFS")));
    assert!(snapshot.notes.iter().any(|n| n.contains("submodule")));
}

#[test]
fn a_linked_worktree_syncs_without_following_its_git_pointer() {
    let dir = repo();
    let root = dir.path();
    write(root, "a.hx", b"x");
    commit(root, "x");
    let other = tempfile::tempdir().unwrap();
    let tree = other.path().join("tree");
    git(root, &["worktree", "add", "-q", "-b", "side", tree.to_str().unwrap()]);
    write(&tree, "b.hx", b"in the worktree");
    let snapshot = scan(&tree, &options(true)).unwrap();
    assert_eq!(paths(&snapshot), vec!["a.hx", "b.hx"], "the .git file is not a file of the workspace");
    assert_eq!(snapshot.manifest.git.branch.as_deref(), Some("side"));
    assert!(snapshot.manifest.validate(&Limits::default()).is_empty());
}

#[test]
fn a_subfolder_and_a_plain_folder_are_not_workspaces_to_sync() {
    let dir = repo();
    let root = dir.path();
    write(root, "sub/a.hx", b"x");
    commit(root, "x");
    assert!(matches!(scan(&root.join("sub"), &options(false)), Err(ScanError::NotTheTop { .. })));
    let plain = tempfile::tempdir().unwrap();
    assert!(matches!(scan(plain.path(), &options(false)), Err(ScanError::NotARepository(_))));
}

#[test]
fn a_git_operation_in_progress_is_not_scanned_over() {
    let dir = repo();
    let root = dir.path();
    write(root, "a.hx", b"x");
    commit(root, "x");
    fs::write(root.join(".git/index.lock"), "").unwrap();
    assert!(matches!(scan(root, &options(false)), Err(ScanError::Busy(_))));
}

#[test]
fn names_that_collide_on_a_case_insensitive_disk_keep_the_first() {
    let dropped = rayde_sync::scan::case_collisions(&["A.txt".into(), "a.txt".into(), "b.txt".into(), "B.TXT".into()]);
    assert_eq!(dropped, vec!["a.txt", "B.TXT"]);
}
