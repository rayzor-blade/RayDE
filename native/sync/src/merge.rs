//! Merging two edited versions of a working tree that started from the same one. A file changed on one side moves over; a text file changed on both
//! is merged by Yrs when the edits are in different places; edits in the same place, binary files, and an edit against a deletion are reported as
//! conflicts and nothing is decided for them. The merge looks only at content, so either side can run it.
use similar::{DiffOp, TextDiff};
use std::collections::{BTreeMap, BTreeSet};
use yrs::{Doc, GetString, OffsetKind, Options, block::ClientID, ReadTxn, StateVector, Text, Transact, Update, updates::decoder::Decode};

/// The largest text file merged by content; a larger one that changed on both sides is a conflict.
pub const MAX_TEXT: usize = 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum Merged {
    Text(String),
    /// Both sides edited the same lines.
    Overlap,
}

/// One edited stretch of the base text: base lines `first..last` (a gap when equal) become `text`, with the same stretch in UTF-16 units for the document.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Hunk {
    first: usize,
    last: usize,
    from: u32,
    to: u32,
    text: String,
}

fn hunks(base: &str, edited: &str) -> Vec<Hunk> {
    let base_lines: Vec<&str> = base.split_inclusive('\n').collect();
    let edited_lines: Vec<&str> = edited.split_inclusive('\n').collect();
    let mut offsets = vec![0u32];
    for line in &base_lines {
        offsets.push(offsets.last().unwrap() + line.encode_utf16().count() as u32);
    }
    let diff = TextDiff::from_lines(base, edited);
    diff.ops()
        .iter()
        .filter_map(|op| {
            let (old, new) = match *op {
                DiffOp::Equal { .. } => return None,
                DiffOp::Delete { old_index, old_len, new_index } => ((old_index, old_index + old_len), (new_index, new_index)),
                DiffOp::Insert { old_index, new_index, new_len } => ((old_index, old_index), (new_index, new_index + new_len)),
                DiffOp::Replace { old_index, old_len, new_index, new_len } => ((old_index, old_index + old_len), (new_index, new_index + new_len)),
            };
            Some(Hunk { first: old.0, last: old.1, from: offsets[old.0], to: offsets[old.1], text: edited_lines[new.0..new.1].concat() })
        })
        .collect()
}

/// Two hunks overlap when the stretches of base they edit touch, counting the gap an insertion sits in; neighbours overlap too, as they do in Git.
fn touch(a: &Hunk, b: &Hunk) -> bool {
    a.first.max(b.first) <= a.last.min(b.last)
}

fn options(client: u64) -> Options {
    Options { offset_kind: OffsetKind::Utf16, ..Options::with_client_id(ClientID::new(client)) }
}

/// A document of the base text with one fixed client, so every side that starts from the same text starts from the same history.
fn seed(base: &str) -> Vec<u8> {
    let doc = Doc::with_options(options(0));
    let text = doc.get_or_insert_text("text");
    text.insert(&mut doc.transact_mut(), 0, base);
    doc.transact().encode_state_as_update_v1(&StateVector::default())
}

/// The history of one side's edits on top of the base: its hunks, applied last to first so each offset is still the base's.
fn edited(seed: &[u8], client: u64, hunks: &[Hunk]) -> Vec<u8> {
    let doc = Doc::with_options(options(client));
    let text = doc.get_or_insert_text("text");
    doc.transact_mut().apply_update(Update::decode_v1(seed).expect("the seed is ours")).expect("the seed applies");
    for hunk in hunks.iter().rev() {
        let mut txn = doc.transact_mut();
        if hunk.to > hunk.from {
            text.remove_range(&mut txn, hunk.from, hunk.to - hunk.from);
        }
        if !hunk.text.is_empty() {
            text.insert(&mut txn, hunk.from, &hunk.text);
        }
    }
    let state = doc.transact().encode_state_as_update_v1(&StateVector::default());
    state
}

/// Merges `ours` and `theirs`, both edited from `base`. Edits that both sides made identically count once.
pub fn text(base: &str, ours: &str, theirs: &str) -> Merged {
    if ours == theirs {
        return Merged::Text(ours.to_string());
    }
    if ours == base {
        return Merged::Text(theirs.to_string());
    }
    if theirs == base {
        return Merged::Text(ours.to_string());
    }
    let (mine, mut yours) = (hunks(base, ours), hunks(base, theirs));
    yours.retain(|hunk| !mine.contains(hunk));
    if mine.iter().any(|a| yours.iter().any(|b| touch(a, b))) {
        return Merged::Overlap;
    }
    let seed = seed(base);
    let doc = Doc::with_options(options(3));
    let merged = doc.get_or_insert_text("text");
    for update in [edited(&seed, 1, &mine), edited(&seed, 2, &yours)] {
        doc.transact_mut().apply_update(Update::decode_v1(&update).expect("the update is ours")).expect("the update applies");
    }
    let result = merged.get_string(&doc.transact());
    Merged::Text(result)
}

/// What a file is on one side of a merge: the hash of its content and whether it is executable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub hash: String,
    pub executable: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    Write { path: String, content: Vec<u8>, executable: bool },
    Delete { path: String },
}

#[derive(Debug, PartialEq, Eq)]
pub struct Conflict {
    pub path: String,
    pub reason: &'static str,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// What to do to the local tree so it holds both sides' changes.
    pub actions: Vec<Action>,
    /// Files neither side's version of which can be chosen for the person. Present means the plan is not to be applied as it stands.
    pub conflicts: Vec<Conflict>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Side {
    Base,
    Ours,
    Theirs,
}

fn as_text(bytes: &[u8]) -> Option<&str> {
    if bytes.len() > MAX_TEXT || bytes.contains(&0) {
        return None;
    }
    std::str::from_utf8(bytes).ok()
}

/// Plans a three-way merge of trees. `content` supplies a file's bytes from a side when they are needed; it returns None when they cannot be had.
pub fn plan(base: &BTreeMap<String, Entry>, ours: &BTreeMap<String, Entry>, theirs: &BTreeMap<String, Entry>, content: &mut dyn FnMut(Side, &str) -> Option<Vec<u8>>) -> Plan {
    let mut plan = Plan::default();
    let paths: BTreeSet<&String> = base.keys().chain(ours.keys()).chain(theirs.keys()).collect();
    for path in paths {
        let (b, o, t) = (base.get(path), ours.get(path), theirs.get(path));
        if o == t {
            continue;
        }
        let same = |x: Option<&Entry>, y: Option<&Entry>| x.map(|e| &e.hash) == y.map(|e| &e.hash);
        if same(o, b) {
            // Only they changed it: it moves over.
            plan.actions.push(match t {
                Some(entry) => match content(Side::Theirs, path) {
                    Some(bytes) => Action::Write { path: path.clone(), content: bytes, executable: entry.executable },
                    None => {
                        plan.conflicts.push(Conflict { path: path.clone(), reason: "the other version could not be read" });
                        continue;
                    }
                },
                None => Action::Delete { path: path.clone() },
            });
            continue;
        }
        if same(t, b) {
            // Only we changed it: nothing to do.
            continue;
        }
        // Both sides changed it, differently.
        let (Some(_), Some(o), Some(t)) = (b, o, t) else {
            plan.conflicts.push(Conflict { path: path.clone(), reason: if o.is_none() || t.is_none() { "edited on one side and deleted on the other" } else { "added on both sides with different content" } });
            continue;
        };
        let (Some(base_bytes), Some(our_bytes), Some(their_bytes)) = (content(Side::Base, path), content(Side::Ours, path), content(Side::Theirs, path)) else {
            plan.conflicts.push(Conflict { path: path.clone(), reason: "a version could not be read" });
            continue;
        };
        match (as_text(&base_bytes), as_text(&our_bytes), as_text(&their_bytes)) {
            (Some(base_text), Some(our_text), Some(their_text)) => match text(base_text, our_text, their_text) {
                Merged::Text(merged) => plan.actions.push(Action::Write { path: path.clone(), content: merged.into_bytes(), executable: o.executable || t.executable }),
                Merged::Overlap => plan.conflicts.push(Conflict { path: path.clone(), reason: "both sides edited the same lines" }),
            },
            _ => plan.conflicts.push(Conflict { path: path.clone(), reason: "a binary or very large file changed on both sides" }),
        }
    }
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(n: usize) -> String {
        (1..=n).map(|i| format!("line {i}\n")).collect()
    }

    fn replace_line(text: &str, n: usize, with: &str) -> String {
        text.lines().enumerate().map(|(i, l)| if i + 1 == n { format!("{with}\n") } else { format!("{l}\n") }).collect()
    }

    #[test]
    fn edits_in_different_places_are_both_kept() {
        let base = lines(12);
        let ours = replace_line(&base, 2, "ours");
        let theirs = replace_line(&base, 10, "theirs");
        let Merged::Text(merged) = text(&base, &ours, &theirs) else { panic!("no overlap here") };
        assert_eq!(merged, replace_line(&replace_line(&base, 2, "ours"), 10, "theirs"));
        assert_eq!(text(&base, &theirs, &ours), Merged::Text(merged), "the same either way round");
    }

    #[test]
    fn a_line_both_sides_edited_is_an_overlap_and_so_is_its_neighbour() {
        let base = lines(8);
        assert_eq!(text(&base, &replace_line(&base, 4, "ours"), &replace_line(&base, 4, "theirs")), Merged::Overlap);
        assert_eq!(text(&base, &replace_line(&base, 4, "ours"), &replace_line(&base, 5, "theirs")), Merged::Overlap, "neighbours conflict, as in Git");
    }

    #[test]
    fn an_edit_both_sides_made_identically_counts_once() {
        let base = lines(6);
        let fixed = replace_line(&base, 3, "fixed");
        let theirs = replace_line(&fixed, 6, "also theirs");
        assert_eq!(text(&base, &fixed, &theirs), Merged::Text(theirs.clone()));
    }

    #[test]
    fn an_insert_at_the_top_and_another_at_the_end_both_land() {
        let base = lines(5);
        let ours = format!("header\n{base}");
        let theirs = format!("{base}footer\n");
        assert_eq!(text(&base, &ours, &theirs), Merged::Text(format!("header\n{base}footer\n")));
    }

    #[test]
    fn two_inserts_at_the_same_place_conflict() {
        let base = lines(3);
        let ours = format!("a\n{base}");
        let theirs = format!("b\n{base}");
        assert_eq!(text(&base, &ours, &theirs), Merged::Overlap);
    }

    #[test]
    fn offsets_count_utf16_units_so_characters_outside_the_basic_plane_do_not_shift_edits() {
        let base = "a 😀 one\nb 😀 two\nc 😀 three\nd 😀 four\n".to_string();
        let ours = base.replace("a 😀 one", "a 😀 ONE");
        let theirs = base.replace("d 😀 four", "d 😀 FOUR");
        assert_eq!(text(&base, &ours, &theirs), Merged::Text("a 😀 ONE\nb 😀 two\nc 😀 three\nd 😀 FOUR\n".into()));
    }

    #[test]
    fn deleting_a_stretch_and_editing_elsewhere_merges() {
        let base = lines(10);
        let ours: String = base.lines().filter(|l| !["line 3", "line 4"].contains(l)).map(|l| format!("{l}\n")).collect();
        let theirs = replace_line(&base, 9, "nine");
        let Merged::Text(merged) = text(&base, &ours, &theirs) else { panic!("no overlap") };
        assert!(!merged.contains("line 3") && !merged.contains("line 4") && merged.contains("nine\n") && merged.contains("line 8\n"));
    }

    fn entry(bytes: &[u8]) -> Entry {
        Entry { hash: crate::chunk::sha256_hex(bytes), executable: false }
    }

    #[test]
    fn a_tree_merges_per_file_and_reports_what_it_cannot_decide() {
        let files = |items: &[(&str, &str)]| items.iter().map(|(p, c)| (p.to_string(), entry(c.as_bytes()))).collect::<BTreeMap<_, _>>();
        let b = lines(8);
        let (o_main, t_main) = (replace_line(&b, 1, "ours"), replace_line(&b, 8, "theirs"));
        let (o_clash, t_clash) = (replace_line(&b, 4, "ours"), replace_line(&b, 4, "theirs"));
        let base = files(&[("main.hx", &b), ("clash.hx", &b), ("only-theirs.txt", "old"), ("gone.txt", "bye"), ("kept.txt", "keep"), ("edited.txt", "e0")]);
        let ours = files(&[("main.hx", &o_main), ("clash.hx", &o_clash), ("only-theirs.txt", "old"), ("gone.txt", "bye"), ("kept.txt", "keep ours"), ("new-ours.txt", "n"), ("edited.txt", "e1")]);
        let theirs = files(&[("main.hx", &t_main), ("clash.hx", &t_clash), ("only-theirs.txt", "new"), ("kept.txt", "keep"), ("new-theirs.txt", "t")]);
        let mut sources: BTreeMap<(Side, String), Vec<u8>> = BTreeMap::new();
        for (side, set) in [(Side::Base, [("main.hx", b.as_str()), ("clash.hx", b.as_str())]), (Side::Ours, [("main.hx", o_main.as_str()), ("clash.hx", o_clash.as_str())]), (Side::Theirs, [("main.hx", t_main.as_str()), ("clash.hx", t_clash.as_str())])] {
            for (path, content) in set {
                sources.insert((side, path.to_string()), content.as_bytes().to_vec());
            }
        }
        sources.insert((Side::Theirs, "only-theirs.txt".into()), b"new".to_vec());
        sources.insert((Side::Theirs, "new-theirs.txt".into()), b"t".to_vec());
        let plan = plan(&base, &ours, &theirs, &mut |side, path| sources.get(&(side, path.to_string())).cloned());
        let mut written: Vec<&str> = plan.actions.iter().filter_map(|a| if let Action::Write { path, .. } = a { Some(path.as_str()) } else { None }).collect();
        written.sort();
        assert_eq!(written, vec!["main.hx", "new-theirs.txt", "only-theirs.txt"]);
        assert!(plan.actions.contains(&Action::Delete { path: "gone.txt".into() }), "their deletion of a file we left alone moves over");
        let conflicts: Vec<(&str, &str)> = plan.conflicts.iter().map(|c| (c.path.as_str(), c.reason)).collect();
        assert_eq!(conflicts, vec![("clash.hx", "both sides edited the same lines"), ("edited.txt", "edited on one side and deleted on the other")]);
        let merged = plan.actions.iter().find_map(|a| if let Action::Write { path, content, .. } = a { (path == "main.hx").then(|| String::from_utf8(content.clone()).unwrap()) } else { None }).unwrap();
        assert!(merged.starts_with("ours\n") && merged.ends_with("theirs\n"));
    }
}
