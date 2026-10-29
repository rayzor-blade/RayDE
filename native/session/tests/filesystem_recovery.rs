mod support;
use rayde_session::{checkpoint, dir_store::DirStore, docs::DocHub, store::FileStore};
use serde_json::json;
use std::{fs, sync::Arc};

fn draft(text: &str) -> checkpoint::Checkpoint {
    use yrs::{ReadTxn, StateVector, Transact};
    let peer = support::Peer::new();
    peer.edit(0, 0, text);
    checkpoint::pack(
        &peer
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default()),
    )
    .unwrap()
}

fn alter_header(record: &[u8], change: impl FnOnce(&mut serde_json::Value)) -> Vec<u8> {
    let magic = b"\xffrayde-buffer\0";
    let prefix = magic.len() + 4;
    let size = u32::from_le_bytes(record[magic.len()..prefix].try_into().unwrap()) as usize;
    let mut header = serde_json::from_slice(&record[prefix..prefix + size]).unwrap();
    change(&mut header);
    let header = serde_json::to_vec(&header).unwrap();
    let mut result = magic.to_vec();
    result.extend((header.len() as u32).to_le_bytes());
    result.extend(header);
    result.extend(&record[prefix + size..]);
    result
}

#[tokio::test]
async fn released_recovered_drafts_block_file_parent_and_destination_mutations() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/main.hx"), "saved").unwrap();
    fs::write(root.path().join("other.hx"), "other").unwrap();
    let snapshot = draft("unsaved draft");
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    hub.restore_buffer("src/main.hx", &snapshot, &checkpoint::digest(b"saved"))
        .await
        .unwrap();
    hub.attach("src/main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    hub.detach("src/main.hx", "a");
    hub.release("src/main.hx").await.unwrap();
    drop(hub);
    let hub = DocHub::new(
        Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap()),
        Arc::new(|_| {}),
    );
    for path in ["src/main.hx", "src"] {
        assert_eq!(
            hub.remove(path, true).await.unwrap_err().code,
            "buffer-dirty"
        );
        assert_eq!(
            hub.rename(path, "moved").await.unwrap_err().code,
            "buffer-dirty"
        );
    }
    assert_eq!(
        hub.rename("other.hx", "src/main.hx")
            .await
            .unwrap_err()
            .code,
        "buffer-dirty"
    );
    assert_eq!(
        fs::read_to_string(root.path().join("src/main.hx")).unwrap(),
        "saved"
    );
    assert_eq!(
        hub.attach("src/main.hx", "a", None, Arc::new(|_| {}))
            .await
            .unwrap()
            .text,
        "unsaved draft"
    );
    hub.save("src/main.hx", false).await.unwrap();
    hub.detach("src/main.hx", "a");
    hub.release("src/main.hx").await.unwrap();
    hub.rename("src", "moved").await.unwrap();
    assert_eq!(
        fs::read_to_string(root.path().join("moved/main.hx")).unwrap(),
        "unsaved draft"
    );
    hub.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn released_alias_drafts_protect_canonical_paths_and_allow_unrelated_mutations() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/main.hx"), "saved").unwrap();
    std::os::unix::fs::symlink("src", root.path().join("alias")).unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    hub.restore_buffer(
        "alias/main.hx",
        &draft("draft"),
        &checkpoint::digest(b"saved"),
    )
    .await
    .unwrap();
    let record = store
        .read_state("doc:alias/main.hx")
        .await
        .unwrap()
        .unwrap();
    for path in ["alias/main.hx", "src/main.hx"] {
        assert_eq!(
            hub.write(path, b"replacement").await.unwrap_err().code,
            "buffer-dirty"
        );
        assert_eq!(
            hub.remove(path, false).await.unwrap_err().code,
            "buffer-dirty"
        );
    }
    assert_eq!(
        hub.rename("src", "moved").await.unwrap_err().code,
        "buffer-dirty"
    );
    hub.write("src-other.txt", b"unrelated").await.unwrap();
    hub.rename("src-other.txt", "renamed.txt").await.unwrap();
    hub.remove("renamed.txt", false).await.unwrap();
    assert_eq!(
        store
            .read_state("doc:alias/main.hx")
            .await
            .unwrap()
            .unwrap(),
        record
    );
    assert_eq!(
        fs::read_to_string(root.path().join("src/main.hx")).unwrap(),
        "saved"
    );
    assert_eq!(
        hub.attach("alias/main.hx", "a", None, Arc::new(|_| {}))
            .await
            .unwrap()
            .text,
        "draft"
    );
    hub.save("alias/main.hx", false).await.unwrap();
    hub.detach("alias/main.hx", "a");
    hub.release("alias/main.hx").await.unwrap();
    hub.remove("src", true).await.unwrap();
    hub.write("src/main.hx", b"new file").await.unwrap();
    assert_eq!(
        hub.attach("alias/main.hx", "a", None, Arc::new(|_| {}))
            .await
            .unwrap()
            .text,
        "new file"
    );
    hub.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn retargeting_a_released_draft_alias_does_not_attach_it_to_another_file() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    for file in ["first.txt", "second.txt"] {
        fs::write(root.path().join(file), "same saved contents").unwrap();
    }
    std::os::unix::fs::symlink("first.txt", root.path().join("alias.txt")).unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    hub.restore_buffer(
        "alias.txt",
        &draft("private first-file draft"),
        &checkpoint::digest(b"same saved contents"),
    )
    .await
    .unwrap();
    let before = store.read_state("doc:alias.txt").await.unwrap();
    fs::remove_file(root.path().join("alias.txt")).unwrap();
    std::os::unix::fs::symlink("second.txt", root.path().join("alias.txt")).unwrap();
    assert_eq!(
        hub.attach("alias.txt", "a", None, Arc::new(|_| {}))
            .await
            .err()
            .unwrap()
            .code,
        "recovery-conflict"
    );
    assert_eq!(store.read_state("doc:alias.txt").await.unwrap(), before);
    assert_eq!(
        fs::read_to_string(root.path().join("second.txt")).unwrap(),
        "same saved contents"
    );
    hub.close().await;
}

#[tokio::test]
async fn legacy_buffers_require_rebinding_and_corrupt_bindings_cannot_hide_a_draft() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.txt"), "saved").unwrap();
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    hub.restore_buffer("main.txt", &draft("draft"), &checkpoint::digest(b"saved"))
        .await
        .unwrap();
    let bound = store.read_state("doc:main.txt").await.unwrap().unwrap();
    let legacy = alter_header(&bound, |header| {
        header["version"] = json!(1);
        header.as_object_mut().unwrap().remove("path");
        header.as_object_mut().unwrap().remove("binding");
    });
    store.write_state("doc:main.txt", &legacy).await.unwrap();
    assert_eq!(
        hub.remove("main.txt", false).await.unwrap_err().code,
        "recovery-binding"
    );
    assert_eq!(
        store.read_state("doc:main.txt").await.unwrap().unwrap(),
        legacy
    );
    assert_eq!(
        hub.attach("main.txt", "a", None, Arc::new(|_| {}))
            .await
            .unwrap()
            .text,
        "draft"
    );
    hub.detach("main.txt", "a");
    hub.release("main.txt").await.unwrap();
    assert_eq!(
        hub.remove("main.txt", false).await.unwrap_err().code,
        "buffer-dirty"
    );
    hub.write("other.txt", b"allowed").await.unwrap();
    let corrupted = alter_header(&bound, |header| {
        header["path"] = json!(root.path().join("other.txt"))
    });
    store.write_state("doc:main.txt", &corrupted).await.unwrap();
    assert_eq!(
        hub.remove("main.txt", false).await.unwrap_err().code,
        "bad-buffer-state"
    );
    assert_eq!(
        store.read_state("doc:main.txt").await.unwrap().unwrap(),
        corrupted
    );
    store.write_state("doc:main.txt", &bound).await.unwrap();
    fs::write(root.path().join("main.txt"), "changed externally").unwrap();
    assert_eq!(
        hub.rename("main.txt", "moved.txt").await.unwrap_err().code,
        "recovery-conflict"
    );
    assert_eq!(
        store.read_state("doc:main.txt").await.unwrap().unwrap(),
        bound
    );
    hub.close().await;
}

#[tokio::test]
async fn protocol_refuses_closed_dirty_draft_mutations_and_workspace_root_moves() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.txt"), "saved").unwrap();
    let running = support::server(root.path(), false).await;
    let mut client = support::Client::hello(&running).await;
    assert_eq!(client.request(json!({"op":"doc.restore","path":"main.txt","mode":"buffer","checkpoint":draft("draft"),"diskSha256":checkpoint::digest(b"saved")})).await["ok"],true);
    client
        .request(json!({"op":"doc.open","path":"main.txt"}))
        .await;
    client
        .request(json!({"op":"doc.close","path":"main.txt"}))
        .await;
    assert_eq!(
        client
            .request(json!({"op":"fs.rename","from":"main.txt","to":"moved.txt"}))
            .await["code"],
        "buffer-dirty"
    );
    assert_eq!(
        client
            .request(json!({"op":"fs.remove","path":"main.txt"}))
            .await["code"],
        "buffer-dirty"
    );
    assert_eq!(
        client
            .request(json!({"op":"fs.rename","from":"","to":"moved"}))
            .await["code"],
        "outside"
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"main.txt"}))
            .await["text"],
        "draft"
    );
    client.close().await;
    running.shutdown().await;
}

#[tokio::test]
async fn refusing_a_directory_mutation_leaves_clean_sibling_graphs_and_other_workspaces_untouched()
{
    let root = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    for file in ["clean.txt", "dirty.txt"] {
        fs::write(root.path().join("src").join(file), "saved").unwrap();
    }
    let store = Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap());
    let hub = DocHub::new(store.clone(), Arc::new(|_| {}));
    for (file, text) in [("clean.txt", "saved"), ("dirty.txt", "draft")] {
        hub.restore_buffer(
            &format!("src/{file}"),
            &draft(text),
            &checkpoint::digest(b"saved"),
        )
        .await
        .unwrap();
    }
    let clean = store.read_state("doc:src/clean.txt").await.unwrap();
    let dirty = store.read_state("doc:src/dirty.txt").await.unwrap();
    assert_eq!(
        hub.rename("src", "moved").await.unwrap_err().code,
        "buffer-dirty"
    );
    assert_eq!(store.read_state("doc:src/clean.txt").await.unwrap(), clean);
    assert_eq!(store.read_state("doc:src/dirty.txt").await.unwrap(), dirty);
    let independent = DirStore::with_state_root(other.path(), state.path()).unwrap();
    independent
        .write("main.txt", b"another workspace")
        .await
        .unwrap();
    independent.remove("main.txt", false).await.unwrap();
    hub.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn file_and_directory_aliases_cannot_bypass_shared_document_guards() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/main.hx"), "keep").unwrap();
    std::os::unix::fs::symlink("src", root.path().join("alias")).unwrap();
    let hub = DocHub::new(
        Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap()),
        Arc::new(|_| {}),
    );
    hub.attach("src/main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    assert_eq!(
        hub.remove("alias", true).await.unwrap_err().code,
        "document-open"
    );
    assert_eq!(
        hub.rename("alias/main.hx", "moved.hx")
            .await
            .unwrap_err()
            .code,
        "document-open"
    );
    assert_eq!(
        hub.write("alias/main.hx", b"changed")
            .await
            .unwrap_err()
            .code,
        "document-open"
    );
    if root.path().join("SRC/MAIN.HX").exists() {
        assert_eq!(
            hub.remove("SRC/MAIN.HX", false).await.unwrap_err().code,
            "document-open"
        );
    }
    assert_eq!(
        fs::read_to_string(root.path().join("src/main.hx")).unwrap(),
        "keep"
    );
    hub.close().await;
}

#[tokio::test]
async fn direct_writes_update_shared_graphs_without_a_file_watcher() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(root.path().join("main.hx"), "old").unwrap();
    let hub = DocHub::new(
        Arc::new(DirStore::with_state_root(root.path(), state.path()).unwrap()),
        Arc::new(|_| {}),
    );
    hub.attach("main.hx", "a", None, Arc::new(|_| {}))
        .await
        .unwrap();
    hub.write("main.hx", b"new content").await.unwrap();
    assert_eq!(hub.text("main.hx").unwrap(), "new content");
    let delta = hub
        .receive_journal("main.hx", "a", &[0, 0], "AA==")
        .unwrap();
    let state =
        checkpoint::materialize(&[checkpoint::unpack_delta(&delta).unwrap()], &delta.vector)
            .unwrap();
    assert_eq!(checkpoint::text(&state).unwrap(), "new content");
    assert_eq!(
        hub.write("main.hx", &[255]).await.unwrap_err().code,
        "not-text"
    );
    assert_eq!(
        fs::read(root.path().join("main.hx")).unwrap(),
        b"new content"
    );
    assert_eq!(hub.text("main.hx").unwrap(), "new content");
    hub.close().await;
}

#[tokio::test]
async fn deleting_a_shared_file_or_parent_is_refused_until_the_document_is_released() {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::create_dir(root.path().join("src-other")).unwrap();
    fs::write(root.path().join("src/main.hx"), "base").unwrap();
    let running = support::server(root.path(), false).await;
    let mut client = support::Client::hello(&running).await;
    assert_eq!(
        client.request(json!({"op":"hello"})).await["fileMutations"],
        1
    );
    client
        .request(json!({"op":"doc.open","path":"src/main.hx"}))
        .await;
    for path in ["src/main.hx", "src"] {
        assert_eq!(
            client
                .request(json!({"op":"fs.remove","path":path,"recursive":true}))
                .await["code"],
            "document-open"
        );
        assert!(root.path().join("src/main.hx").exists());
    }
    assert_eq!(
        client
            .request(json!({"op":"fs.remove","path":"src-other"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"fs.write","path":"src/main.hx","data":"acknowledged"}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"doc.open","path":"src/main.hx"}))
            .await["text"],
        "acknowledged"
    );
    client
        .request(json!({"op":"doc.close","path":"src/main.hx"}))
        .await;
    assert_eq!(
        client
            .request(json!({"op":"fs.remove","path":"src","recursive":true}))
            .await["ok"],
        true
    );
    assert!(!root.path().join("src").exists());
    client.close().await;
    running.shutdown().await;
}
