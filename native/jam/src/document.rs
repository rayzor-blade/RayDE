//! UTF-16 editor transactions over Yrs update-v1 documents.
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::{Deserialize, Serialize};
use yrs::{
    Assoc, Doc, GetString, IndexedSequence, OffsetKind, Options, ReadTxn, StateVector, StickyIndex,
    Text, TextRef, Transact, UndoManager, Update,
    updates::{decoder::Decode, encoder::Encode},
};

pub const MAX_TEXT: usize = 1024 * 1024;
pub const MAX_UPDATE: usize = 2 * 1024 * 1024;
pub const MAX_SESSION: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Patch {
    pub from: u32,
    pub removed: String,
    pub inserted: String,
}

pub struct Document {
    doc: Doc,
    text: TextRef,
    undo: UndoManager,
    history_bytes: usize,
    received_bytes: usize,
}

pub fn decode(value: &str) -> Result<Vec<u8>, String> {
    if value.len() > MAX_UPDATE * 4 / 3 + 8 {
        return Err("Jam update exceeds its limit".into());
    }
    B64.decode(value).map_err(|_| "Invalid Jam encoding".into())
}
pub fn encode(value: &[u8]) -> String {
    B64.encode(value)
}

/// Reject offsets inside a surrogate pair; Rust's string ranges use UTF-8 bytes.
fn byte_at(text: &str, index: u32) -> Result<usize, String> {
    let mut offset = 0;
    for (byte, ch) in text.char_indices() {
        if offset == index {
            return Ok(byte);
        }
        offset += ch.len_utf16() as u32;
        if offset > index {
            return Err("Jam edit splits a Unicode character".into());
        }
    }
    if offset == index {
        Ok(text.len())
    } else {
        Err("Jam position is out of bounds".into())
    }
}

impl Document {
    pub fn new(initial: &str) -> Result<Self, String> {
        if initial.len() > MAX_TEXT {
            return Err("Jam text exceeds 1 MiB".into());
        }
        let doc = Doc::with_options(Options {
            offset_kind: OffsetKind::Utf16,
            ..Options::default()
        });
        let text = doc.get_or_insert_text("source");
        text.insert(&mut doc.transact_mut_with("seed"), 0, initial);
        let mut undo = UndoManager::with_options(yrs::undo::Options {
            capture_timeout_millis: 0,
            ..Default::default()
        });
        undo.expand_scope(&doc, &text);
        undo.include_origin("editor");
        Ok(Self {
            doc,
            text,
            undo,
            history_bytes: 0,
            received_bytes: initial.len(),
        })
    }
    pub fn id(&self) -> String {
        self.doc.guid().to_string()
    }
    pub fn text(&self) -> String {
        self.text.get_string(&self.doc.transact())
    }
    pub fn vector(&self) -> String {
        encode(&self.doc.transact().state_vector().encode_v1())
    }
    pub fn state(&self) -> String {
        encode(
            &self
                .doc
                .transact()
                .encode_state_as_update_v1(&StateVector::default()),
        )
    }
    pub fn diff(&self, vector: &str) -> Result<String, String> {
        let vector =
            StateVector::decode_v1(&decode(vector)?).map_err(|_| "Invalid Jam state vector")?;
        Ok(encode(
            &self.doc.transact().encode_state_as_update_v1(&vector),
        ))
    }
    pub fn edit(&mut self, before: &str, parts: &[Patch]) -> Result<String, String> {
        if before != self.text() {
            return Err("Jam document and editor are out of sync".into());
        }
        if parts.len() > 4096 {
            return Err("Too many Jam edit ranges".into());
        }
        let mut last = 0usize;
        let mut size = before.len();
        let mut cost = 0;
        for part in parts {
            let from = byte_at(before, part.from)?;
            let end = from
                .checked_add(part.removed.len())
                .ok_or("Invalid Jam edit")?;
            if from < last || before.get(from..end) != Some(part.removed.as_str()) {
                return Err("Invalid or overlapping Jam edits".into());
            }
            size = size
                .checked_sub(part.removed.len())
                .and_then(|n| n.checked_add(part.inserted.len()))
                .ok_or("Invalid Jam edit size")?;
            cost += part.removed.len() + part.inserted.len();
            last = end;
        }
        if size > MAX_TEXT || self.received_bytes + cost > MAX_SESSION {
            return Err("Jam session limit reached; start a new session".into());
        }
        if self.history_bytes + cost > MAX_TEXT || self.undo.undo_stack().len() >= 100 {
            self.undo.clear_all();
            self.history_bytes = 0;
        }
        self.history_bytes += cost;
        self.received_bytes += cost;
        self.undo.reset();
        let mut txn = self.doc.transact_mut_with("editor");
        for part in parts.iter().rev() {
            if !part.removed.is_empty() {
                self.text.remove_range(
                    &mut txn,
                    part.from,
                    part.removed.encode_utf16().count() as u32,
                );
            }
            if !part.inserted.is_empty() {
                self.text.insert(&mut txn, part.from, &part.inserted);
            }
        }
        Ok(encode(&txn.encode_update_v1()))
    }
    pub fn apply(&mut self, update: &str) -> Result<(), String> {
        let bytes = decode(update)?;
        if bytes.len() > MAX_UPDATE || self.received_bytes + bytes.len() > MAX_SESSION {
            return Err("Jam session limit reached; start a new session".into());
        }
        let update = Update::decode_v1(&bytes).map_err(|_| "Invalid Jam document update")?;
        self.doc
            .transact_mut_with("remote")
            .apply_update(update)
            .map_err(|_| "Cannot apply Jam update")?;
        self.received_bytes += bytes.len();
        if self.text().len() > MAX_TEXT || self.state().len() > MAX_UPDATE * 4 / 3 {
            return Err("Jam document exceeds its limit".into());
        }
        Ok(())
    }
    pub fn undo(&mut self, redo: bool) -> String {
        let vector = self.doc.transact().state_vector();
        if redo {
            self.undo.redo_blocking();
        } else {
            self.undo.undo_blocking();
        }
        encode(&self.doc.transact().encode_state_as_update_v1(&vector))
    }
    pub fn position(&self, index: u32) -> Result<String, String> {
        byte_at(&self.text(), index)?;
        let txn = self.doc.transact();
        let position = self
            .text
            .sticky_index(&txn, index, Assoc::After)
            .unwrap_or_else(|| StickyIndex::from_type(&txn, &self.text, Assoc::After));
        Ok(encode(&position.encode_v1()))
    }
    pub fn resolve(&self, position: &str) -> Result<u32, String> {
        if position.len() > 256 {
            return Err("Invalid Jam position".into());
        }
        let position =
            StickyIndex::decode_v1(&decode(position)?).map_err(|_| "Invalid Jam position")?;
        let txn = self.doc.transact();
        let offset = position.get_offset(&txn).ok_or("Unknown Jam position")?;
        if !std::ptr::eq(
            offset.branch.as_ref(),
            <TextRef as AsRef<yrs::branch::Branch>>::as_ref(&self.text),
        ) {
            return Err("Unknown Jam text".into());
        }
        Ok(offset.index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pair(seed: &str) -> (Document, Document) {
        let a = Document::new(seed).unwrap();
        let mut b = Document::new("").unwrap();
        b.apply(&a.state()).unwrap();
        (a, b)
    }
    #[test]
    fn concurrent_unicode_edits_and_author_undo() {
        let (mut a, mut b) = pair("a🦀b\n");
        let caret = b.position(3).unwrap();
        let ua = a
            .edit(
                "a🦀b\n",
                &[Patch {
                    from: 1,
                    removed: "🦀".into(),
                    inserted: "é".into(),
                }],
            )
            .unwrap();
        let ub = b
            .edit(
                "a🦀b\n",
                &[Patch {
                    from: 4,
                    removed: "".into(),
                    inserted: "你好".into(),
                }],
            )
            .unwrap();
        a.apply(&ub).unwrap();
        b.apply(&ua).unwrap();
        b.apply(&ua).unwrap();
        assert_eq!(a.text(), b.text());
        assert_eq!(a.text(), "aéb你好\n");
        assert_eq!(b.resolve(&caret).unwrap(), 2);
        let undo = a.undo(false);
        b.apply(&undo).unwrap();
        assert_eq!(b.text(), "a🦀b你好\n");
        assert_eq!(a.text(), b.text());
        b.apply(&a.undo(true)).unwrap();
        assert_eq!(a.text(), b.text());
    }
    #[test]
    fn reversed_updates_reconnect_and_atomic_ranges() {
        let (mut a, mut b) = pair("hello world");
        let first = a
            .edit(
                "hello world",
                &[
                    Patch {
                        from: 0,
                        removed: "hello".into(),
                        inserted: "hi".into(),
                    },
                    Patch {
                        from: 6,
                        removed: "world".into(),
                        inserted: "there".into(),
                    },
                ],
            )
            .unwrap();
        let second = a
            .edit(
                "hi there",
                &[Patch {
                    from: 8,
                    removed: "".into(),
                    inserted: "!".into(),
                }],
            )
            .unwrap();
        b.apply(&second).unwrap();
        b.apply(&first).unwrap();
        assert_eq!(b.text(), "hi there!");
        let vb = b.vector();
        b.edit(
            "hi there!",
            &[Patch {
                from: 0,
                removed: "".into(),
                inserted: "B: ".into(),
            }],
        )
        .unwrap();
        let va = a.vector();
        a.apply(&b.diff(&va).unwrap()).unwrap();
        b.apply(&a.diff(&vb).unwrap()).unwrap();
        assert_eq!(a.text(), b.text());
        b.apply(&a.undo(false)).unwrap();
        b.apply(&a.undo(false)).unwrap();
        assert!(
            a.text().contains("B: ") && a.text().contains("hello") && a.text().contains("world")
        );
        assert_eq!(a.text(), b.text());
    }
    #[test]
    fn rejects_surrogates_overlap_stale_and_oversize() {
        let mut a = Document::new("🦀x").unwrap();
        assert!(
            a.edit(
                "🦀x",
                &[Patch {
                    from: 1,
                    removed: "".into(),
                    inserted: "a".into()
                }]
            )
            .is_err()
        );
        assert!(a.edit("wrong", &[]).is_err());
        assert!(a.apply("invalid!").is_err());
        assert_eq!(a.text(), "🦀x");
        assert!(Document::new(&"x".repeat(MAX_TEXT + 1)).is_err());
        let empty = Document::new("").unwrap();
        assert_eq!(empty.resolve(&empty.position(0).unwrap()).unwrap(), 0);
    }
}
