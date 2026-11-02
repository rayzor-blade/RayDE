//! Development driver: document GATEWAY ACCOUNT WORKSPACE PATH TEXT appends TEXT through a shared history.
use rayde_sync::client::{Config, current_manifest, documents};
use yrs::{
    Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, Transact, Update,
    updates::decoder::Decode,
};
fn main() {
    let mut args = std::env::args().skip(1);
    let (gateway, account, workspace, path, added) = (
        args.next().unwrap(),
        args.next().unwrap(),
        args.next().unwrap(),
        args.next().unwrap(),
        args.next().unwrap(),
    );
    let config: Config = serde_json::from_value(
        serde_json::json!({"root":".","gateway":gateway,"account":account,"workspace":workspace}),
    )
    .unwrap();
    let first = documents::open(
        &config,
        &path,
        current_manifest(&config).unwrap().generation,
    )
    .unwrap();
    let doc = Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        ..Options::default()
    });
    let value = doc.get_or_insert_text("text");
    doc.transact_mut()
        .apply_update(Update::decode_v1(&first.update).unwrap())
        .unwrap();
    let at = value.get_string(&doc.transact()).encode_utf16().count() as u32;
    value.insert(&mut doc.transact_mut(), at, &added);
    let update = doc
        .transact()
        .encode_state_as_update_v1(&StateVector::decode_v1(&first.vector).unwrap());
    let reply = documents::exchange(&config, &first.seed, &first.vector, &update).unwrap();
    doc.transact_mut()
        .apply_update(Update::decode_v1(&reply.update).unwrap())
        .unwrap();
    println!(
        "{}",
        serde_json::json!({"text":value.get_string(&doc.transact()),"sequence":reply.sequence,"lineage":reply.seed.lineage})
    );
}
