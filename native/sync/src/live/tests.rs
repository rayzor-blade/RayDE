use super::*;
fn workspace() -> String {
    WorkspaceId::from_random(&[7; 32]).as_str().into()
}
fn replica(source: &Document, id: u64) -> Doc {
    let doc = Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::with_client_id(ClientID::new(id))
    });
    doc.transact_mut()
        .apply_update(Update::decode_v1(&source.state()).unwrap())
        .unwrap();
    doc
}
#[test]
fn independent_replicas_share_seed_and_concurrent_edits_converge() {
    let first = Document::new(&workspace(), "src/Main.hx", 1, "one 🦀 two").unwrap();
    let same = Document::new(&workspace(), "src/Main.hx", 1, "one 🦀 two").unwrap();
    assert_eq!(first.state(), same.state());
    let a = replica(&first, 11);
    let b = replica(&first, 12);
    let from = first.vector();
    a.get_or_insert_text("text")
        .insert(&mut a.transact_mut(), 0, "A ");
    b.get_or_insert_text("text")
        .insert(&mut b.transact_mut(), 10, " B");
    let ua = a
        .transact()
        .encode_state_as_update_v1(&vector(&from).unwrap());
    let ub = b
        .transact()
        .encode_state_as_update_v1(&vector(&from).unwrap());
    let one = first.exchange(&first.seed.lineage, &from, &ua).unwrap();
    let stored = Document::restore(first.seed.clone(), &[one.state]).unwrap();
    let both = stored.exchange(&first.seed.lineage, &from, &ub).unwrap();
    for doc in [&a, &b] {
        doc.transact_mut()
            .apply_update(Update::decode_v1(&both.update).unwrap())
            .unwrap();
        assert_eq!(
            doc.get_or_insert_text("text").get_string(&doc.transact()),
            "A one 🦀 two B"
        );
    }
    assert!(
        !Document::restore(first.seed.clone(), &[both.state])
            .unwrap()
            .exchange(&first.seed.lineage, &from, &ua)
            .unwrap()
            .changed
    );
}
#[test]
fn deletions_are_sent_even_when_the_state_vector_does_not_change() {
    let source = Document::new(&workspace(), "a.txt", 1, "abc").unwrap();
    let client = replica(&source, 5);
    let from = source.vector();
    client
        .get_or_insert_text("text")
        .remove_range(&mut client.transact_mut(), 1, 1);
    let result = source
        .exchange(
            &source.seed.lineage,
            &from,
            &client
                .transact()
                .encode_state_as_update_v1(&vector(&from).unwrap()),
        )
        .unwrap();
    assert!(result.changed);
    assert_eq!(result.vector, from);
    let saved = Document::restore(source.seed.clone(), &[result.state]).unwrap();
    assert_eq!(saved.text(), "ac");
    assert!(
        !saved
            .exchange(&source.seed.lineage, &from, &result.update)
            .unwrap()
            .changed
    );
}
#[test]
fn lineage_missing_dependencies_and_seed_clock_changes_are_refused_without_mutation() {
    let source = Document::new(&workspace(), "a", 1, "base").unwrap();
    let original = source.state();
    let from = source.vector();
    assert_eq!(
        source.exchange("foreign", &from, &[0, 0]).err(),
        Some(Error::Lineage)
    );
    assert_eq!(
        source.exchange(&source.seed.lineage, &[0], &[0, 0]).err(),
        Some(Error::Missing)
    );
    let alien = Doc::with_client_id(0);
    alien
        .get_or_insert_text("text")
        .insert(&mut alien.transact_mut(), 0, "base + forged seed");
    assert_eq!(
        source
            .exchange(&source.seed.lineage, &from, &state(&alien))
            .err(),
        Some(Error::Missing)
    );
    assert!(
        source
            .exchange(&source.seed.lineage, &from, &[255])
            .is_err()
    );
    assert_eq!(source.state(), original);
    assert_ne!(
        source.seed.lineage,
        Document::new(&workspace(), "a", 2, "base")
            .unwrap()
            .seed
            .lineage
    );
    assert_ne!(
        source.seed.lineage,
        Document::new(&workspace(), "b", 1, "base")
            .unwrap()
            .seed
            .lineage
    );
}
#[test]
fn oversized_text_and_graphs_are_refused() {
    assert!(Document::new(&workspace(), "a", 1, &"x".repeat(MAX_TEXT + 1)).is_err());
    let source = Document::new(&workspace(), "a", 1, "").unwrap();
    assert!(Document::restore(source.seed.clone(), &[vec![0; MAX_STATE + 1]]).is_err());
    assert!(
        source
            .exchange(&source.seed.lineage, &vec![0; MAX_VECTOR + 1], &[0, 0])
            .is_err()
    );
}

#[test]
fn vector_order_does_not_change_its_frontier() {
    assert!(same_vector(&[2, 0, 4, 7, 2], &[2, 7, 2, 0, 4]).unwrap());
    assert!(!same_vector(&[2, 0, 4, 7, 2], &[2, 7, 3, 0, 4]).unwrap());
    assert!(same_vector(&[255, 255, 255, 255, 15], &[0]).is_err());
}
