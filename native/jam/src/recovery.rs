//! A bounded CRDT snapshot plus checksummed, fsynced updates. Call only on the Jam worker.
use crate::document::{Document, MAX_UPDATE};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

const MAX_RECORD: usize = MAX_UPDATE * 4 / 3 + 4096;
const HEADER: usize = 12;
const MAX_JOURNAL: u64 = 4 * 1024 * 1024;
const COMPACT_BYTES: u64 = 512 * 1024;
const COMPACT_RECORDS: u64 = 128;
const IO_ERROR: &str = "Cannot save Jam recovery; check workspace permissions and free disk space";
const CORRUPT: &str = "Jam recovery is damaged; preserve its folder before starting a fresh Jam";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    version: u32,
    document_id: String,
    file: String,
    sequence: u64,
    state: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    document_id: String,
    sequence: u64,
    update: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    data: String,
    crc: u32,
}

fn open(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).map_err(|_| IO_ERROR.into())
}
fn sync_dir(root: &Path) -> Result<(), String> {
    #[cfg(unix)]
    File::open(root)
        .and_then(|f| f.sync_all())
        .map_err(|_| IO_ERROR)?;
    Ok(())
}
pub fn valid_id(value: &str) -> bool {
    (16..=64).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
}

/// The lock covers every role for this workspace document, including a disconnected guest.
pub struct Recovery {
    pub id: String,
    pub file: String,
    pub doc: Document,
    journal: Option<Journal>,
    failed: bool,
}
struct Journal {
    root: PathBuf,
    _lock: File,
    log: File,
    sequence: u64,
    records: u64,
    bytes: u64,
}
impl Recovery {
    pub fn open(
        root: &str,
        file: &str,
        restore: bool,
        id: &str,
        state: &str,
    ) -> Result<Self, String> {
        let mut result = Self {
            id: id.into(),
            file: file.into(),
            doc: Document::new("")?,
            journal: None,
            failed: false,
        };
        if !root.is_empty() {
            let root = PathBuf::from(root);
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(&root).map_err(|_| IO_ERROR)?;
            let lock = open(&root.join("lock"))?;
            lock.try_lock()
                .map_err(|_| "This document's Jam recovery is already in use by another window")?;
            let log = open(&root.join("updates.log"))?;
            result.journal = Some(Journal {
                root,
                _lock: lock,
                log,
                sequence: 0,
                records: 0,
                bytes: 0,
            });
        } else if restore {
            return Err("No Jam recovery folder was provided".into());
        }
        if restore {
            result.load()?;
        } else if !id.is_empty() {
            if !valid_id(id) {
                return Err("Invalid Jam document identity".into());
            }
            result.doc.apply(state)?;
            result.checkpoint()?;
        }
        Ok(result)
    }
    pub fn durable(&self) -> bool {
        self.journal.is_some()
    }
    pub fn adopt(&mut self, id: &str, file: &str, state: &str) -> Result<(), String> {
        if !valid_id(id) {
            return Err("Invalid Jam document identity".into());
        }
        if !self.id.is_empty() && self.id != id {
            return Err("This invitation is for a different Jam; your recovery was kept".into());
        }
        if !self.file.is_empty() && self.file != file {
            return Err(
                "The invitation shares a different document; open its matching file first".into(),
            );
        }
        self.doc.apply(state)?;
        self.id = id.into();
        self.file = file.into();
        self.checkpoint()
    }
    pub fn accept(&mut self, update: &str) -> Result<(), String> {
        if self.failed {
            return Err(IO_ERROR.into());
        }
        let result = self.append(update);
        if result.is_err() {
            self.failed = true;
        }
        result
    }
    fn append(&mut self, update: &str) -> Result<(), String> {
        if self.id.is_empty() {
            return Err("Jam has not received its document identity".into());
        }
        self.doc.apply(update)?;
        if let Some(journal) = &mut self.journal {
            let sequence = journal.sequence.checked_add(1).ok_or(CORRUPT)?;
            let data = serde_json::to_vec(&Record {
                document_id: self.id.clone(),
                sequence,
                update: update.into(),
            })
            .map_err(|_| CORRUPT)?;
            if data.len() > MAX_RECORD
                || journal.bytes + data.len() as u64 + HEADER as u64 > MAX_JOURNAL
            {
                return Err("Jam recovery journal limit reached".into());
            }
            let mut header = Vec::with_capacity(HEADER);
            header.extend_from_slice(&(data.len() as u32).to_le_bytes());
            header.extend_from_slice(&crc32fast::hash(&data).to_le_bytes());
            header.extend_from_slice(&crc32fast::hash(&header).to_le_bytes());
            journal
                .log
                .write_all(&header)
                .and_then(|_| journal.log.write_all(&data))
                .and_then(|_| journal.log.sync_all())
                .map_err(|_| IO_ERROR)?;
            journal.sequence = sequence;
            journal.records += 1;
            journal.bytes += data.len() as u64 + HEADER as u64;
            if journal.bytes >= COMPACT_BYTES || journal.records >= COMPACT_RECORDS {
                self.checkpoint()?;
            }
        }
        Ok(())
    }
    pub fn checkpoint(&mut self) -> Result<(), String> {
        if self.failed {
            return Err(IO_ERROR.into());
        }
        let result = self.save_snapshot();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
    fn save_snapshot(&mut self) -> Result<(), String> {
        let Some(journal) = &mut self.journal else {
            return Ok(());
        };
        let data = serde_json::to_string(&Snapshot {
            version: 1,
            document_id: self.id.clone(),
            file: self.file.clone(),
            sequence: journal.sequence,
            state: self.doc.state(),
        })
        .map_err(|_| CORRUPT)?;
        let bytes = serde_json::to_vec(&Envelope {
            crc: crc32fast::hash(data.as_bytes()),
            data,
        })
        .map_err(|_| CORRUPT)?;
        if bytes.len() > MAX_RECORD + 4096 {
            return Err("Jam recovery snapshot exceeds its limit".into());
        }
        let next = journal.root.join("checkpoint.next");
        let mut output = open(&next)?;
        output
            .set_len(0)
            .and_then(|_| output.write_all(&bytes))
            .and_then(|_| output.sync_all())
            .map_err(|_| IO_ERROR)?;
        drop(output);
        fs::rename(next, journal.root.join("checkpoint.json")).map_err(|_| IO_ERROR)?;
        sync_dir(&journal.root)?;
        // Sequence numbers make a crash between rename and truncation harmless.
        journal
            .log
            .set_len(0)
            .and_then(|_| journal.log.seek(SeekFrom::Start(0)))
            .and_then(|_| journal.log.sync_all())
            .map_err(|_| IO_ERROR)?;
        journal.bytes = 0;
        journal.records = 0;
        Ok(())
    }
    fn load(&mut self) -> Result<(), String> {
        let journal = self.journal.as_mut().ok_or(CORRUPT)?;
        let file = File::open(journal.root.join("checkpoint.json"))
            .map_err(|_| "No saved Jam checkpoint exists for this document")?;
        if file.metadata().map_err(|_| CORRUPT)?.len() > (MAX_RECORD + 4096) as u64 {
            return Err(CORRUPT.into());
        }
        let envelope: Envelope = serde_json::from_reader(file).map_err(|_| CORRUPT)?;
        if crc32fast::hash(envelope.data.as_bytes()) != envelope.crc {
            return Err(CORRUPT.into());
        }
        let snapshot: Snapshot = serde_json::from_str(&envelope.data).map_err(|_| CORRUPT)?;
        if snapshot.version != 1 || !valid_id(&snapshot.document_id) || snapshot.file != self.file {
            return Err(CORRUPT.into());
        }
        self.doc.apply(&snapshot.state)?;
        self.id = snapshot.document_id;
        journal.sequence = snapshot.sequence;
        let size = journal.log.metadata().map_err(|_| CORRUPT)?.len();
        if size > MAX_JOURNAL {
            return Err(CORRUPT.into());
        }
        let mut data = Vec::new();
        journal.log.read_to_end(&mut data).map_err(|_| CORRUPT)?;
        let mut offset = 0;
        while data.len() - offset >= HEADER {
            let length = u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap()) as usize;
            let crc = u32::from_le_bytes(data[offset + 4..offset + 8].try_into().unwrap());
            let header_crc =
                u32::from_le_bytes(data[offset + 8..offset + HEADER].try_into().unwrap());
            if header_crc != crc32fast::hash(&data[offset..offset + 8]) || length > MAX_RECORD {
                return Err(CORRUPT.into());
            }
            if data.len() - offset - HEADER < length {
                break;
            }
            let payload = &data[offset + HEADER..offset + HEADER + length];
            if crc32fast::hash(payload) != crc {
                return Err(CORRUPT.into());
            }
            let record: Record = serde_json::from_slice(payload).map_err(|_| CORRUPT)?;
            // An old journal can remain after publishing a fresh room's snapshot.
            if record.document_id == self.id && record.sequence > snapshot.sequence {
                if record.sequence != journal.sequence + 1 {
                    return Err(CORRUPT.into());
                }
                self.doc.apply(&record.update)?;
                journal.sequence = record.sequence;
            }
            offset += length + HEADER;
            journal.records += 1;
        }
        // Only a partial final frame is expendable; a complete corrupt frame is preserved.
        journal
            .log
            .set_len(offset as u64)
            .and_then(|_| journal.log.seek(SeekFrom::End(0)))
            .and_then(|_| journal.log.sync_all())
            .map_err(|_| IO_ERROR)?;
        journal.bytes = offset as u64;
        // Restore compacts the log without changing any CRDT clocks or the room identity.
        self.checkpoint()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::Patch;
    fn root() -> PathBuf {
        std::env::temp_dir().join(format!("rayde-jam-{}", Document::new("").unwrap().id()))
    }
    #[test]
    fn locks_compacts_recovers_tail_and_merges_old_offline_document() {
        let root = root();
        let path = root.to_str().unwrap();
        let seed = Document::new("🦀").unwrap();
        let id = seed.id();
        let mut offline = Document::new("").unwrap();
        offline.apply(&seed.state()).unwrap();
        let mut store = Recovery::open(path, "Main.hx", false, &id, &seed.state()).unwrap();
        assert!(Recovery::open(path, "Main.hx", true, "", "").is_err());
        let mut writer = Document::new("").unwrap();
        writer.apply(&seed.state()).unwrap();
        for _ in 0..140 {
            let text = writer.text();
            let at = text.encode_utf16().count() as u32;
            store
                .accept(
                    &writer
                        .edit(
                            &text,
                            &[Patch {
                                from: at,
                                removed: "".into(),
                                inserted: "x".into(),
                            }],
                        )
                        .unwrap(),
                )
                .unwrap();
        }
        let text = store.doc.text();
        let vector = store.doc.vector();
        drop(store);
        // Simulate a process dying halfway through the final journal frame.
        let mut log = OpenOptions::new()
            .append(true)
            .open(root.join("updates.log"))
            .unwrap();
        let mut tail = vec![16, 0, 0, 0, 0, 0, 0, 0];
        tail.extend_from_slice(&crc32fast::hash(&tail).to_le_bytes());
        tail.extend_from_slice(&[1, 2]);
        log.write_all(&tail).unwrap();
        drop(log);
        let mut restored = Recovery::open(path, "Main.hx", true, "", "").unwrap();
        assert_eq!(restored.id, id);
        assert_eq!(restored.doc.text(), text);
        assert_eq!(restored.doc.vector(), vector);
        restored
            .accept(
                &offline
                    .edit(
                        "🦀",
                        &[Patch {
                            from: 0,
                            removed: "".into(),
                            inserted: "old: ".into(),
                        }],
                    )
                    .unwrap(),
            )
            .unwrap();
        offline
            .apply(&restored.doc.diff(&offline.vector()).unwrap())
            .unwrap();
        assert_eq!(offline.text(), format!("old: {text}"));
        assert_eq!(restored.doc.text(), offline.text());
        drop(restored);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn corrupt_complete_records_and_snapshots_are_preserved() {
        for corrupt in 0..3 {
            let root = root();
            let path = root.to_str().unwrap();
            let seed = Document::new("keep").unwrap();
            let mut store =
                Recovery::open(path, "Main.hx", false, &seed.id(), &seed.state()).unwrap();
            store.accept(&seed.state()).unwrap();
            drop(store);
            let file = root.join(if corrupt == 0 {
                "checkpoint.json"
            } else {
                "updates.log"
            });
            let mut bytes = fs::read(&file).unwrap();
            let last = bytes.len() - 1;
            bytes[if corrupt == 2 { 0 } else { last }] ^= 1;
            fs::write(&file, &bytes).unwrap();
            assert!(Recovery::open(path, "Main.hx", true, "", "").is_err());
            assert_eq!(fs::read(file).unwrap(), bytes);
            fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn interrupted_snapshot_publication_and_new_room_replacement() {
        let root = root();
        let path = root.to_str().unwrap();
        let mut seed = Document::new("old").unwrap();
        let mut store = Recovery::open(path, "Main.hx", false, &seed.id(), &seed.state()).unwrap();
        store
            .accept(
                &seed
                    .edit(
                        "old",
                        &[Patch {
                            from: 3,
                            removed: "".into(),
                            inserted: " update".into(),
                        }],
                    )
                    .unwrap(),
            )
            .unwrap();
        let log = fs::read(root.join("updates.log")).unwrap();
        store.checkpoint().unwrap();
        drop(store);
        fs::write(root.join("updates.log"), &log).unwrap();
        let restored = Recovery::open(path, "Main.hx", true, "", "").unwrap();
        assert_eq!(restored.doc.text(), "old update");
        drop(restored);
        let fresh = Document::new("fresh").unwrap();
        drop(Recovery::open(path, "Main.hx", false, &fresh.id(), &fresh.state()).unwrap());
        fs::write(root.join("updates.log"), &log).unwrap();
        let restored = Recovery::open(path, "Main.hx", true, "", "").unwrap();
        assert_eq!(restored.doc.text(), "fresh");
        assert_eq!(restored.id, fresh.id());
        drop(restored);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn failed_writes_poison_store_and_journal_size_is_bounded() {
        let root = root();
        let path = root.to_str().unwrap();
        let seed = Document::new("safe").unwrap();
        let mut store = Recovery::open(path, "Main.hx", false, &seed.id(), &seed.state()).unwrap();
        store.journal.as_mut().unwrap().log = File::open(root.join("updates.log")).unwrap();
        assert!(store.accept(&seed.state()).is_err());
        assert!(store.checkpoint().is_err());
        drop(store);
        let log = OpenOptions::new()
            .write(true)
            .open(root.join("updates.log"))
            .unwrap();
        log.set_len(MAX_JOURNAL + 1).unwrap();
        drop(log);
        assert!(Recovery::open(path, "Main.hx", true, "", "").is_err());
        assert_eq!(
            fs::metadata(root.join("updates.log")).unwrap().len(),
            MAX_JOURNAL + 1
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn checkpoint_preserves_pending_updates_and_deletions() {
        let root = root();
        let path = root.to_str().unwrap();
        let mut seed = Document::new("abc").unwrap();
        let state = seed.state();
        let first = seed
            .edit(
                "abc",
                &[Patch {
                    from: 3,
                    removed: "".into(),
                    inserted: "X".into(),
                }],
            )
            .unwrap();
        let second = seed
            .edit(
                "abcX",
                &[Patch {
                    from: 4,
                    removed: "".into(),
                    inserted: "Y".into(),
                }],
            )
            .unwrap();
        let deletion = seed
            .edit(
                "abcXY",
                &[Patch {
                    from: 0,
                    removed: "ab".into(),
                    inserted: "".into(),
                }],
            )
            .unwrap();
        let mut store = Recovery::open(path, "Main.hx", false, &seed.id(), &state).unwrap();
        store.accept(&second).unwrap();
        store.accept(&deletion).unwrap();
        store.checkpoint().unwrap();
        drop(store);
        let mut restored = Recovery::open(path, "Main.hx", true, "", "").unwrap();
        restored.accept(&first).unwrap();
        assert_eq!(restored.doc.text(), "cXY");
        drop(restored);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn wrong_room_cannot_overwrite_recovery() {
        let root = root();
        let path = root.to_str().unwrap();
        let seed = Document::new("keep").unwrap();
        let mut store = Recovery::open(path, "Main.hx", false, &seed.id(), &seed.state()).unwrap();
        assert!(
            store
                .adopt(
                    &Document::new("").unwrap().id(),
                    "Main.hx",
                    &Document::new("wrong").unwrap().state()
                )
                .is_err()
        );
        drop(store);
        let restored = Recovery::open(path, "Main.hx", true, "", "").unwrap();
        assert_eq!(restored.doc.text(), "keep");
        drop(restored);
        fs::remove_dir_all(root).unwrap();
    }
}
