import test from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import { EditorDocument, EditorDocuments } from "../src/editor.js";

function fixture(initial = "abc") {
  const ydoc = new Y.Doc(), remote = new Y.Doc(), events = [];
  ydoc.getText("text").insert(0, initial);
  Y.applyUpdate(remote, Y.encodeStateAsUpdate(ydoc));
  const doc = {ydoc}, view = new EditorDocument(doc, "a", event => events.push(event));
  view.ready = true;
  const deliver = () => Y.applyUpdate(ydoc, Y.encodeStateAsUpdate(remote), "session");
  const ack = event => view.acknowledge({epoch:event.epoch, accept:event.serial === view.serial});
  const drain = () => { while (events.length) ack(events.shift()); };
  const dispose = () => { view.dispose(); ydoc.destroy(); remote.destroy(); };
  return {ydoc, remote, events, view, deliver, drain, ack, dispose};
}

test("a remote offer racing with local typing is rejected and reprojected without losing either edit", () => {
  const f = fixture();
  try {
    f.remote.getText("text").insert(0, "remote "); f.deliver();
    assert.equal(f.events.length, 1);
    f.view.local({epoch:0, serial:1, parts:[{from:3, removed:"", inserted:" local"}]});
    f.ack(f.events.shift());
    const merged = f.events.shift();
    assert.equal(merged.text, "remote abc local");
    assert.deepEqual(merged.parts, [{from:0, removed:"", inserted:"remote "}]);
    f.ack(merged);
    assert.equal(f.view.text.toString(), f.ydoc.getText("text").toString());
    assert.equal(f.events.length, 0);
  } finally { f.dispose(); }
});

test("UTF-16 multi-range transactions undo only local edits after remote deletions and duplicate delivery", () => {
  const f = fixture("😀 alpha beta omega");
  try {
    f.view.local({epoch:0, serial:1, parts:[{from:3, removed:"alpha", inserted:"A"}, {from:9, removed:"beta", inserted:"B"}]});
    Y.applyUpdate(f.remote, Y.encodeStateAsUpdate(f.ydoc));
    f.remote.getText("text").delete(7, 5);
    f.deliver(); f.deliver(); f.drain();
    assert.equal(f.view.text.toString(), "😀 A B ");
    const undone = f.view.reverse({epoch:f.view.epoch, serial:2});
    assert.equal(undone.text, "😀 alpha beta ");
    const redone = f.view.reverse({epoch:f.view.epoch, serial:3, redo:true});
    assert.equal(redone.text, "😀 A B ");
    assert.equal(f.events.length, 0, "delete sets must not cause an endless projection loop");
  } finally { f.dispose(); }
});

test("acknowledging a snapshot preserves newer remote updates and emits exact disjoint patches", () => {
  const f = fixture("0123456789");
  try {
    f.remote.getText("text").insert(0, "x"); f.deliver();
    f.remote.transact(() => { f.remote.getText("text").delete(8, 1); f.remote.getText("text").delete(2, 1); }); f.deliver();
    assert.equal(f.events.length, 1);
    f.ack(f.events.shift());
    const latest = f.events.shift();
    assert.deepEqual(latest.parts, [{from:2,removed:"1",inserted:""}, {from:8,removed:"7",inserted:""}]);
    f.ack(latest);
    assert.equal(f.view.text.toString(), "x02345689");
    assert.equal(f.events.length, 0);
  } finally { f.dispose(); }
});

test("invalid patches and stale undo leave the document unchanged; disposal unhooks projection resources", () => {
  const f = fixture();
  assert.throws(() => f.view.local({epoch:0,serial:1,parts:[{from:1,removed:"wrong",inserted:"x"}]}), /does not match/);
  assert.equal(f.view.text.toString(), "abc");
  assert.throws(() => f.view.reverse({epoch:2,serial:1}), /out of sequence/);
  f.view.dispose();
  f.remote.getText("text").insert(0,"later"); f.deliver();
  assert.equal(f.events.length, 0);
  f.dispose();
});

test("the bridge orders open, edits, save and close, and releases completed request queues", async () => {
  const ydoc = new Y.Doc(); ydoc.getText("text").insert(0,"base");
  let saved, closed = false;
  const documents = new EditorDocuments({openDoc:async () => ({ydoc, path:"a", save:async () => { saved = ydoc.getText("text").toString(); }, close:async () => { closed = true; }})}, () => {});
  const open = documents.request("view.open",{handle:"a",path:"a"});
  const ready = documents.request("view.ready",{handle:"a"});
  const edit = documents.request("view.edit",{handle:"a",epoch:0,serial:1,parts:[{from:4,removed:"",inserted:"!"}]});
  const save = documents.request("view.save",{handle:"a"});
  await Promise.all([open,ready,edit,save]);
  assert.equal(saved,"base!");
  await documents.request("view.close",{handle:"a"});
  assert.equal(closed,true); assert.equal(documents.documents.size,0); assert.equal(documents.queues.size,0);
  documents.close(); ydoc.destroy();
});

test("typing reaches the local CRDT while an earlier save is waiting for the network", async () => {
  const ydoc = new Y.Doc(); ydoc.getText("text").insert(0,"base");
  let finish;
  const documents = new EditorDocuments({openDoc:async () => ({ydoc,path:"a",save:() => new Promise(resolve => { finish = resolve; }),close:async () => {}})},() => {});
  await documents.request("view.open",{handle:"a",path:"a"});
  await documents.request("view.ready",{handle:"a"});
  const saved = documents.request("view.save",{handle:"a"});
  await documents.request("view.edit",{handle:"a",epoch:0,serial:1,parts:[{from:4,removed:"",inserted:" offline"}]});
  assert.equal(ydoc.getText("text").toString(),"base offline");
  assert.equal(documents.queues.size,0,"a network save must not hold the editor operation queue");
  finish({}); await saved;
  documents.close(); ydoc.destroy();
});

test("concurrent opens cannot give one document two projection owners", async () => {
  const ydoc = new Y.Doc();
  let started, release;
  const entered = new Promise(resolve => { started = resolve; });
  const opening = new Promise(resolve => { release = resolve; });
  const documents = new EditorDocuments({openDoc() { started(); return opening; }},() => {});
  const first = documents.request("view.open",{handle:"first",path:"a"});
  await entered;
  await assert.rejects(documents.request("view.open",{handle:"second",path:"a"}),/already has an editor binding/);
  release({ydoc,path:"a",close:async () => {}}); await first;
  assert.equal(documents.documents.size,1);
  assert.equal(documents.opening.size,0);
  documents.close(); ydoc.destroy();
});
