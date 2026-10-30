import * as Y from "yjs";

const LOCAL = Symbol("editor");
const REMOTE = Symbol("projection");

/** Apply ordered UTF-16 patches against the text the editor actually saw. */
function edit(text, parts) {
  const before = text.toString();
  let end = 0;
  for (const part of parts) {
    if (!Number.isSafeInteger(part.from) || part.from < end || typeof part.removed !== "string" || typeof part.inserted !== "string" ||
        part.from + part.removed.length > before.length || before.slice(part.from, part.from + part.removed.length) !== part.removed)
      throw new Error("The editor transaction does not match its document.");
    end = part.from + part.removed.length;
  }
  for (const part of parts.toReversed()) {
    if (part.removed.length) text.delete(part.from, part.removed.length);
    if (part.inserted.length) text.insert(part.from, part.inserted);
  }
}

/** Capture disjoint changes in the old text's coordinates. */
function changes(doc, run) {
  const text = doc.getText("text"), before = text.toString(), parts = [];
  const observe = event => {
    let at = 0, part = null;
    for (const change of event.delta) {
      if (change.retain) { at += change.retain; part = null; }
      else {
        if (!part) { part = {from:at, removed:"", inserted:""}; parts.push(part); }
        if (change.delete) { part.removed += before.slice(at, at + change.delete); at += change.delete; }
        if (change.insert) part.inserted += change.insert;
      }
    }
  };
  text.observe(observe);
  try { run(); } finally { text.unobserve(observe); }
  return parts;
}

/** One projection belongs to a persistent editor buffer, rather than a mounted view. */
export class EditorDocument {
  constructor(doc, handle, emit) {
    this.doc = doc;
    this.handle = handle;
    this.emit = emit;
    this.shadow = new Y.Doc();
    Y.applyUpdate(this.shadow, Y.encodeStateAsUpdate(doc.ydoc), REMOTE);
    this.text = this.shadow.getText("text");
    this.undo = new Y.UndoManager(this.text, {trackedOrigins:new Set([LOCAL]), captureTimeout:0});
    this.serial = this.epoch = this.version = this.undoBytes = 0;
    this.ready = this.dirty = this.closed = false;
    this.offer = null;
    this.project = (update, origin) => {
      this.version++;
      if (origin !== this) { this.dirty = true; this.offerRemote(); }
    };
    this.publish = (update, origin) => {
      if (origin === LOCAL || origin === this.undo) Y.applyUpdate(doc.ydoc, update, this);
    };
    doc.ydoc.on("update", this.project);
    this.shadow.on("update", this.publish);
  }

  snapshot() { return {text:this.text.toString(), epoch:this.epoch, serial:this.serial, ...(this.doc.restoredDirty ? {dirty:true} : {})}; }

  local(request) {
    if (!this.ready || request.epoch !== this.epoch || request.serial !== this.serial + 1 || !Array.isArray(request.parts))
      throw new Error("The editor transaction is out of sequence.");
    this.shadow.transact(() => edit(this.text, request.parts), LOCAL);
    this.serial++;
    this.undoBytes += request.parts.reduce((size, part) => size + 2 * (part.removed.length + part.inserted.length) + 64, 0);
    if (this.undoBytes > 1024 * 1024 || this.undo.undoStack.length > 100) { this.undo.clear(); this.undoBytes = 0; }
  }

  reverse(request) {
    if (!this.ready || request.epoch !== this.epoch || request.serial !== this.serial + 1)
      throw new Error("The editor undo is out of sequence.");
    const parts = changes(this.shadow, () => request.redo ? this.undo.redo() : this.undo.undo());
    this.serial++;
    return {...this.snapshot(), parts};
  }

  offerRemote() {
    if (this.closed || !this.ready || !this.dirty || this.offer) return;
    const update = Y.encodeStateAsUpdate(this.doc.ydoc, Y.encodeStateVector(this.shadow));
    const probe = new Y.Doc();
    Y.applyUpdate(probe, Y.encodeStateAsUpdate(this.shadow), REMOTE);
    const parts = changes(probe, () => Y.applyUpdate(probe, update, REMOTE));
    const text = probe.getText("text").toString();
    probe.destroy();
    this.offer = {update, version:this.version, epoch:this.epoch + 1, serial:this.serial};
    this.emit({ev:"view.remote", handle:this.handle, text, parts, epoch:this.offer.epoch, serial:this.serial});
  }

  acknowledge(request) {
    const offer = this.offer;
    if (!offer || request.epoch !== offer.epoch) throw new Error("The editor acknowledgement is out of sequence.");
    if (request.accept) {
      if (offer.serial !== this.serial) throw new Error("The editor acknowledged an obsolete projection.");
      Y.applyUpdate(this.shadow, offer.update, REMOTE);
      this.epoch = offer.epoch;
      this.dirty = offer.version !== this.version;
    }
    this.offer = null;
    this.offerRemote();
  }

  dispose() {
    if (this.closed) return;
    this.closed = true;
    this.doc.ydoc.off("update", this.project);
    this.shadow.off("update", this.publish);
    this.undo.destroy();
    this.shadow.destroy();
    this.offer = null;
  }
}

/** Channel requests are serialized per document, including acknowledgements and save barriers. */
export class EditorDocuments {
  constructor(client, emit) {
    this.client = client; this.emit = emit; this.documents = new Map(); this.queues = new Map(); this.opening = new Set(); this.closed = false; this.failure = null;
    this.unsubscribe = client.on?.("context-changed", ({message}) => {
      this.failure = message;
      for (const view of this.documents.values()) {
        view.ready = false;
        this.emit({ev:"view.error",handle:view.handle,code:"workspace-changed",message});
      }
    });
    this.unsubscribeDocument = client.on?.("document-error", ({path,code,message}) => {
      for (const view of this.documents.values()) if (view.doc.path === path) {
        view.ready = false;
        this.emit({ev:"view.error",handle:view.handle,code,message});
      }
    });
  }

  request(op, request) {
    const handle = request.handle;
    if (typeof handle !== "string" || handle.length > 1024) return Promise.reject(new Error("Invalid editor handle."));
    const work = (this.queues.get(handle) ?? Promise.resolve()).catch(() => {}).then(async () => {
      if (this.closed) throw new Error("The editor session is closed.");
      if (this.failure && op !== "view.close") throw new Error(this.failure);
      if (op === "view.open") {
        if (this.documents.has(handle) || this.documents.size + this.opening.size >= 256) throw new Error("Too many shared documents are open.");
        if (typeof request.path !== "string" || this.opening.has(request.path) || [...this.documents.values()].some(view => view.doc.path === request.path)) throw new Error("This document already has an editor binding.");
        this.opening.add(request.path);
        let doc;
        try { doc = await this.client.openDoc(request.path); } finally { this.opening.delete(request.path); }
        if (this.closed || this.failure) { await doc.close(); throw new Error(this.failure ?? "The editor session is closed."); }
        const view = new EditorDocument(doc, handle, this.emit);
        this.documents.set(handle, view);
        return view.snapshot();
      }
      const view = this.documents.get(handle);
      if (!view) { if (op === "view.close") return {}; throw new Error("The shared document is closed."); }
      if (view.doc.blocked && op !== "view.close") throw view.doc.blocked;
      if (op === "view.ready") { view.ready = true; view.offerRemote(); }
      else if (op === "view.edit") view.local(request);
      else if (op === "view.ack") view.acknowledge(request);
      else if (op === "view.undo") return view.reverse(request);
      // Only the barrier is ordered. Later typing must still reach IndexedDB while the network waits.
      else if (op === "view.save") return {saved:view.doc.save()};
      else if (op === "view.close") { view.dispose(); this.documents.delete(handle); await view.doc.close(); }
      else throw new Error("Unknown editor operation.");
      return {};
    });
    this.queues.set(handle, work);
    const cleanup = () => { if (this.queues.get(handle) === work) this.queues.delete(handle); };
    work.then(cleanup, cleanup);
    return op === "view.save" ? work.then(reply => reply.saved) : work;
  }

  close() {
    this.closed = true;
    this.unsubscribe?.();
    this.unsubscribeDocument?.();
    for (const view of this.documents.values()) { view.dispose(); void view.doc.close(); }
    this.documents.clear();
  }
}
