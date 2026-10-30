// The browser's side of a RayDE workspace session: files and documents over one WebSocket.
// Documents are local-first: edits apply to a Yjs document in the page at once, are kept in IndexedDB, and
// reach the session when it is reachable and the person has signed in. A reconnect catches both sides up.
import * as Y from "yjs";
import { IndexeddbPersistence } from "y-indexeddb";
import {RecoveryDirectory, validDocumentId, legacyName, recoveryName, readLegacy, recoveryHeader, checkpointRecovery, markLegacy} from "./recovery.js";

export function cacheNamespace(address, identity) {
  if (identity?.version !== 1 || ![identity.authority,identity.workspace,identity.principal].every(value =>
      typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\u0000-\u001f]/.test(value))) return null;
  const endpoint = new URL(address);
  return JSON.stringify([2,endpoint.origin,endpoint.pathname,identity.authority,identity.workspace,identity.principal]);
}

const b64 = {
  encode(bytes) {
    let text = "";
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(text);
  },
  decode(text) {
    const raw = atob(text);
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  },
};

export class SessionError extends Error {
  constructor(reply) {
    super(reply.message ?? reply.code);
    this.code = reply.code;
    this.login = reply.login ?? null;
  }
}

/** A document open in the page. `text` is its Y.Text; edit it and the change travels. */
export class Doc {
  constructor(client, path) {
    this.client = client;
    this.path = path;
    this.workspace = client.workspace;
    this.ydoc = new Y.Doc();
    this.text = this.ydoc.getText("text");
    this.closed = false;
    /** True while edits exist that the session has not acknowledged. */
    this.unsent = false;
    this.inflight = 0;
    this.failed = false;
    this.listeners = new Set();
    this.persistence = null;
    this.persistences = new Set();
    this.documentId = null;
    this.suspended = false;
    this.abort = new AbortController();
    this.pending = new Set();
    this.localVersion = 0;
    this.acknowledgedVersion = 0;
    this.ydoc.on("update", (update, origin) => {
      if (origin === "session" || this.closed) return;
      this.localVersion++;
      this.unsent = true;
      void this.send(update);
    });
  }

  /** Recovery is loaded while network publication is suspended. */
  start() { return this.sync(); }

  get persistent() { return this.client.options?.persist !== false && this.client.cacheable && typeof indexedDB !== "undefined"; }

  guard() {
    if (this.closed) throw new Error("The shared document is closed.");
    if (this.blocked) throw this.blocked;
    if (this.client.invalidated) throw this.client.invalidated;
  }

  identify(id) {
    this.guard();
    if (!validDocumentId(id)) throw Object.assign(new Error("The workspace returned an invalid document identity."),{code:"recovery-failed"});
    if (this.documentId && this.documentId !== id) throw Object.assign(new Error("The path belongs to a different document. Reopen it to continue; its previous edits are kept in this browser."),{code:"document-changed"});
    const owner = this.client.documentIds?.get(id);
    if (owner && owner !== this) throw Object.assign(new Error("This document already has an editor binding through another path."),{code:"document-open"});
    this.documentId = id;
    this.client.documentIds?.set(id,this);
  }

  async recover(name) {
    if (!this.persistent || this.persistence?.name === name) return;
    this.guard();
    const persistence = new IndexeddbPersistence(name,this.ydoc);
    this.persistences.add(persistence);
    // Destroying persistence suppresses its synced event, so closing must cancel the wait.
    await new Promise((resolve,reject) => {
      const finish = error => { clearTimeout(timer); this.abort.signal.removeEventListener("abort",cancel); error ? reject(error) : resolve(); };
      const cancel = () => finish(new Error("The shared document is closed."));
      const timer = setTimeout(() => finish(Object.assign(new Error("Browser document recovery did not open in time."),{code:"recovery-failed"})),30000);
      this.abort.signal.addEventListener("abort",cancel,{once:true});
      persistence.whenSynced.then(() => finish(),finish);
      persistence._db.catch(finish);
    });
    this.guard();
    this.persistence = persistence;
  }

  async releaseOtherRecovery() {
    for (const persistence of this.persistences) if (persistence !== this.persistence) {
      await persistence.destroy(); this.persistences.delete(persistence);
    }
  }

  async moveRecovery() {
    this.suspended = true;
    if (this.closed) return;
    // Commit the old scope before detaching it; account-only recovery must never write back into viewer storage.
    await this.checkpointGraph();
    await Promise.all([...this.persistences].map(store=>store.destroy()));
    this.persistences.clear(); this.persistence = null;
    this.workspace = this.client.workspace;
    if (this.documentId) {
      await this.recover(recoveryName(this.workspace,this.documentId));
      if (this.persistence) {
        await checkpointRecovery(this.persistence,this.ydoc,this.workspace,this.documentId,[],true);
        await this.client.recoveryDirectory.put(this.workspace,this.path,this.documentId);
      }
    } else {
      await this.recover(legacyName(this.workspace,this.path));
      await this.checkpointGraph();
    }
    await this.releaseOtherRecovery();
  }

  async checkpointGraph() {
    const persistence = this.persistence;
    if (!persistence || this.closed) return;
    await new Promise((resolve,reject) => {
      const tx = persistence.db.transaction("updates","readwrite");
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(tx.error ?? new Error("Could not preserve document recovery."));
      tx.objectStore("updates").add(Y.encodeStateAsUpdate(this.ydoc));
    });
  }

  async checkpoint() {
    await this.started?.catch(() => {});
    await this.checkpointGraph();
  }

  onChange(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** The handshake: tell the session what the page has, take what it has, and send what it lacks. */
  sync() {
    if (this.syncing) return this.syncing;
    const work = this.synchronize();
    this.syncing = work;
    const clear = () => { if (this.syncing === work) this.syncing = null; };
    work.then(clear,clear);
    return work;
  }

  async synchronize() {
    if (this.closed) return;
    this.guard();
    this.suspended = true;
    try {
      if (this.documentId && this.client.hello?.documentIdentities !== 1) throw Object.assign(new Error("The workspace no longer verifies document identities. Reopen it before continuing."),{code:"document-changed"});
      if (!this.client.ready) {
        if (!this.persistence && this.persistent) {
          const id = await this.client.recoveryDirectory.get(this.workspace,this.path);
          this.guard();
          if (id) {
            if (!await recoveryHeader(this.workspace,id)) throw Object.assign(new Error("The document's verified recovery is unavailable. Reconnect before opening it."),{code:"recovery-failed"});
            this.identify(id); await this.recover(recoveryName(this.workspace,id));
          } else if (await readLegacy(legacyName(this.workspace,this.path))) await this.recover(legacyName(this.workspace,this.path));
        }
        if (!this.persistence && Y.encodeStateVector(this.ydoc).length <= 1) throw new Error("Reconnect before opening a document without browser recovery.");
        return;
      }
      let reply;
      if (this.client.hello?.documentIdentities === 1) reply = await this.synchronizeIdentity();
      else {
        await this.recover(legacyName(this.workspace,this.path));
        this.guard();
        reply = await this.open();
        this.identityHint = validDocumentId(reply.documentId) ? reply.documentId : null;
        this.applyReply(reply);
        await this.releaseOtherRecovery();
      }
      this.guard();
      const missing = Y.encodeStateAsUpdate(this.ydoc,b64.decode(reply.vector));
      this.failed = false; this.suspended = false;
      if (missing.length > 2 || this.client.hello?.durableUpdates) await this.send(missing);
      else if (this.inflight === 0) this.unsent = false;
      this.listeners.forEach(listener => listener("synced"));
    } catch (error) {
      this.fence(error); throw error;
    }
  }

  open(vector = Y.encodeStateVector(this.ydoc), expected = this.documentId) {
    this.guard();
    return this.client.request("doc.open",{path:this.path,vector:b64.encode(vector),...(expected ? {documentId:expected} : {})});
  }

  applyReply(reply) {
    this.guard();
    if (this.documentId) this.identify(reply.documentId);
    this.restoredDirty = reply.buffered === true && reply.dirty === true;
    Y.applyUpdate(this.ydoc,b64.decode(reply.update),"session");
  }

  async synchronizeIdentity() {
    const name = legacyName(this.workspace,this.path);
    const legacy = this.persistent ? await readLegacy(name) : null;
    let reply, proven = null;
    if (!this.documentId) {
      // An unbound legacy graph must pass the server's rebound-path check before import.
      if ((legacy?.last && !legacy.binding) || Y.encodeStateVector(this.ydoc).length > 1) {
        if (legacy?.last && !legacy.binding) proven = await readLegacy(name,true);
        reply = await this.open(proven?.vector ?? Y.encodeStateVector(this.ydoc),proven?.binding?.id ?? this.identityHint);
      } else {
        this.guard();
        const lookup = this.client.hello.documentLookup === 1 ? await this.client.request("doc.lookup",{path:this.path}) : null;
        if (lookup?.documentId) this.identify(lookup.documentId);
        else reply = await this.open(new Uint8Array([0]));
      }
      this.guard();
      if (reply) this.identify(reply.documentId);
    }
    const id = this.documentId;
    const header = this.persistent ? await recoveryHeader(this.workspace,id) : null;
    await this.recover(recoveryName(this.workspace,id));
    const migrated = [];
    if (proven) { Y.applyUpdate(this.ydoc,proven.update,"recovery"); migrated.push(proven); }
    const names = new Set([name,...(header?.sources ?? [])]);
    for (const sourceName of names) {
      if (proven?.name === sourceName) continue;
      const source = sourceName === name ? legacy : await readLegacy(sourceName);
      if (source?.binding?.id !== id || header && source.last <= source.binding.copied) continue;
      const loaded = await readLegacy(sourceName,true);
      if (!loaded || loaded.binding?.id !== id) continue;
      this.guard();
      Y.applyUpdate(this.ydoc,loaded.update,"recovery"); migrated.push(loaded);
    }
    this.guard();
    reply ??= await this.open();
    this.applyReply(reply);
    if (this.persistence) {
      await checkpointRecovery(this.persistence,this.ydoc,this.workspace,id,migrated.map(source=>source.name),migrated.length>0);
      await this.client.recoveryDirectory.put(this.workspace,this.path,id);
      for (const source of migrated) await markLegacy(source,id);
    }
    await this.releaseOtherRecovery();
    return reply;
  }

  fence(error) {
    this.failed = true;
    if (!["document-changed","identity-required","recovery-failed"].includes(error.code) || this.closed) return;
    this.blocked = error; this.suspended = true;
    this.client.emit?.("document-error",{path:this.path,documentId:this.documentId,code:error.code,message:error.message});
  }

  send(update) {
    if (!this.client.ready || this.client.authenticating || this.closed || this.suspended || this.blocked) return Promise.resolve();
    const work = this.transmit(update, this.localVersion);
    this.pending.add(work);
    work.finally(() => this.pending.delete(work));
    return work;
  }

  async transmit(update, version) {
    this.inflight++;
    try {
      await this.client.request("doc.update", { path: this.path, update: b64.encode(update), ...(this.documentId ? {documentId:this.documentId} : {}) });
      this.acknowledgedVersion = Math.max(this.acknowledgedVersion,version);
    } catch (error) {
      this.fence(error);
      if (error.code === "auth-required") this.client.needSignIn(error.login);
      // Anything else is retried by the next handshake.
    } finally {
      // Unsent until every update in flight has been taken and none failed.
      if (--this.inflight === 0 && !this.failed && this.acknowledgedVersion === this.localVersion) this.unsent = false;
    }
  }

  async save() {
    this.guard();
    if (this.started) await this.started;
    // Edits queued before Save must reach the session before its file is flushed.
    await Promise.all([...this.pending]);
    if (this.syncing) await this.syncing;
    if (this.closed) throw new Error("The shared document is closed.");
    if (this.unsent) await this.sync();
    if (this.unsent) throw new Error("Reconnect before saving this document. Its edits are kept in this browser.");
    this.guard();
    try { return await this.client.request("doc.save", { path: this.path, ...(this.documentId ? {documentId:this.documentId} : {}) }); }
    catch (error) { this.fence(error); throw error; }
  }

  close() {
    if (this.closing) return this.closing;
    this.closed = true;
    this.abort.abort();
    this.closing = (async () => {
      await Promise.all([...this.persistences].map(store => {
        const closing = store.destroy();
        // A blocked IndexedDB open cannot hold an editor tab open. Destroy still closes it when it arrives.
        if (store.db) return closing;
        void closing.catch(() => {});
      }));
      this.persistences.clear();
      this.ydoc.destroy();
      this.listeners.clear();
      if (this.client.ready) await this.client.request("doc.close", { path: this.path }).catch(() => {});
      if (this.client.documentIds?.get(this.documentId) === this) this.client.documentIds.delete(this.documentId);
      if (this.client.docs.get(this.path) === this) this.client.docs.delete(this.path);
    })();
    return this.closing;
  }
}

export class SessionClient {
  /**
   * @param {{url: string, token?: string, credential?: string, persist?: boolean, reconnect?: boolean, timeout?: number}} options
   *   `url` is the session's WebSocket address; `credential` is what the sign-in edge gave, if the person has signed in.
   */
  constructor(options) {
    this.options = options;
    this.socket = null;
    this.ready = false;
    this.workspace = null;
    this.cacheable = false;
    this.cacheIdentity = null;
    this.volatile = crypto.randomUUID();
    this.invalidated = null;
    this.authenticating = false;
    this.hello = null;
    this.next = 1;
    this.waiting = new Map();
    this.docs = new Map();
    this.documentIds = new Map();
    this.recoveryDirectory = new RecoveryDirectory();
    this.handlers = new Map();
    this.pendingAuth = false;
    this.identity = null;
    this.credential = options.credential ?? null;
    this.stopped = false;
    this.attempt = 0;
    this.generation = 0;
  }

  on(event, handler) {
    if (!this.handlers.has(event)) this.handlers.set(event, new Set());
    this.handlers.get(event).add(handler);
    return () => this.handlers.get(event).delete(handler);
  }

  emit(event, detail) {
    this.handlers.get(event)?.forEach((handler) => handler(detail));
  }

  invalidate() {
    if (this.invalidated) return this.invalidated;
    const error = this.invalidated = new SessionError({code:"workspace-changed",message:"The workspace or account changed. Reopen it to continue; your previous recovery data is kept in this browser."});
    this.stopped = true; this.ready = false; this.generation++;
    for (const reply of this.waiting.values()) reply.reject(error);
    this.waiting.clear();
    this.emit("context-changed", {message:error.message});
    this.socket?.close();
    return error;
  }

  context(identity) {
    const stable = cacheNamespace(this.options.url,identity);
    return {key:stable ?? JSON.stringify(["volatile",this.volatile]),cacheable:stable !== null};
  }

  /** Connects, and keeps reconnecting until `close()`. Resolves when the first connection is ready. */
  connect() {
    return new Promise((resolve, reject) => {
      let first = true;
      const initial = setTimeout(() => {
        if (first) { first = false; this.close(); reject(new Error("The workspace session did not connect in time.")); }
      }, this.options.timeout ?? 30000);
      const open = () => {
        if (this.stopped) return;
        const socket = new WebSocket(this.options.url);
        this.socket = socket;
        socket.onmessage = (message) => { if (this.socket === socket && !this.invalidated) this.receive(JSON.parse(message.data)); };
        socket.onopen = async () => {
          try {
            if (this.socket !== socket || this.stopped) return;
            this.hello = await this.rawRequest("hello", { token: this.options.token });
            this.identity = null;
            if (this.credential) {
              try {
                const reply = await this.rawRequest("auth.login", {credential:this.credential});
                this.identity = {login:reply.login,id:reply.id};
                this.hello.cacheIdentity = reply.cacheIdentity;
              } catch { this.pendingAuth = true; }
            }
            if (this.socket !== socket || socket.readyState !== WebSocket.OPEN || this.stopped) throw new Error("The connection closed during sign-in.");
            const context = this.context(this.hello.cacheIdentity);
            if (this.workspace !== null && (context.key !== this.workspace || !context.cacheable && this.docs.size > 0)) throw this.invalidate();
            this.workspace = context.key; this.cacheable = context.cacheable; this.cacheIdentity = this.hello.cacheIdentity;
            this.ready = true;
            this.attempt = 0;
            this.pendingAuth = !!this.hello.signin && !this.identity;
            this.emit("connected", this.hello);
            await Promise.all([...this.docs.values()].map((doc) => doc.sync().catch(() => {})));
            if (first) { first = false; clearTimeout(initial); resolve(this.hello); }
          } catch (error) {
            if (first) { first = false; clearTimeout(initial); this.close(); reject(error); }
            else if (this.socket === socket) socket.close();
          }
        };
        socket.onclose = () => {
          if (this.socket !== socket) return;
          const wasReady = this.ready;
          this.ready = false;
          if (wasReady) { this.generation++; this.emit("disconnected"); }
          for (const [, reply] of this.waiting) reply.reject(new Error("The connection closed."));
          this.waiting.clear();
          if (first && !wasReady && this.options.reconnect === false) { first = false; clearTimeout(initial); reject(new Error("Could not connect.")); }
          if (!this.stopped && this.options.reconnect !== false) setTimeout(open, Math.min(250 * 2 ** this.attempt++, 5000));
        };
      };
      open();
    });
  }

  receive(message) {
    if (message.id !== undefined && this.waiting.has(message.id)) {
      const reply = this.waiting.get(message.id);
      this.waiting.delete(message.id);
      message.ok ? reply.resolve(message) : reply.reject(new SessionError(message));
    } else if (message.ev === "doc.update") {
      const doc = this.docs.get(message.path);
      if (doc && !doc.closed && !doc.blocked) {
        Y.applyUpdate(doc.ydoc, b64.decode(message.update), "session");
        doc.listeners.forEach((listener) => listener("remote"));
      }
    } else if (message.ev) {
      this.emit(message.ev, message);
    }
  }

  rawRequest(op, params = {}) {
    return new Promise((resolve, reject) => {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return reject(new Error("Not connected."));
      if (this.waiting.size >= 4096) return reject(new Error("Too many session requests are waiting."));
      const id = this.next++;
      const timer = setTimeout(() => {
        this.waiting.delete(id); reject(new Error(`The session did not answer ${op}.`));
      }, this.options.timeout ?? 60000);
      this.waiting.set(id, {
        resolve(value) { clearTimeout(timer); resolve(value); },
        reject(error) { clearTimeout(timer); reject(error); },
      });
      try { this.socket.send(JSON.stringify({ ...params, op, id })); }
      catch (error) { this.waiting.get(id).reject(error); this.waiting.delete(id); }
    });
  }

  request(op, params) {
    if (this.invalidated) return Promise.reject(this.invalidated);
    if (!this.ready) return Promise.reject(new Error("Not connected."));
    return this.rawRequest(op, params);
  }

  /** The local bridge fences process handles before forwarding onto a replacement connection. */
  forward(op, params = {}) {
    if ((op.startsWith("proc.") || op.startsWith("term.")) && params.sessionGeneration !== undefined) {
      if (params.sessionGeneration !== this.generation) return Promise.reject(new Error("The program belongs to a disconnected session."));
      params = {...params}; delete params.sessionGeneration;
    }
    return this.request(op,params);
  }

  /** The sign-in the session asks for: the page opens `url`, and later calls `login` with what the edge returns. */
  needSignIn(url) {
    this.pendingAuth = true;
    this.emit("auth-required", { login: url });
  }

  login(credential) {
    if (this.authenticating) return Promise.reject(new Error("Sign-in is already in progress."));
    const work = this.authenticate(credential);
    this.authentication = work;
    const clear = () => { if (this.authentication === work) this.authentication = null; };
    work.then(clear,clear);
    return work;
  }

  async authenticate(credential) {
    if (!this.ready || this.invalidated) throw this.invalidated ?? new Error("Not connected.");
    const socket = this.socket;
    this.authenticating = true;
    try {
      const reply = await this.rawRequest("auth.login", { credential });
      const context = this.context(reply.cacheIdentity), previous = this.cacheIdentity;
      if (this.identity && this.identity.id !== reply.id || this.workspace !== context.key &&
          !(previous?.principal === "viewer" && previous.authority === reply.cacheIdentity?.authority && previous.workspace === reply.cacheIdentity?.workspace)) throw this.invalidate();
      const documents = [...this.docs.values()];
      await Promise.all(documents.map(doc => doc.started?.catch(() => {})));
      if (this.socket !== socket || !this.ready || this.invalidated) throw this.invalidated ?? new Error("The connection closed during sign-in.");
      this.credential = credential;
      this.identity = { login: reply.login, id: reply.id };
      this.workspace = context.key; this.cacheable = context.cacheable; this.cacheIdentity = reply.cacheIdentity;
      this.hello.cacheIdentity = reply.cacheIdentity;
      try { await Promise.all(documents.filter(doc => doc.workspace !== this.workspace).map(doc => doc.moveRecovery())); }
      catch (error) { this.invalidate(); throw error; }
      this.pendingAuth = false;
      this.emit("signed-in", this.identity);
    } finally { this.authenticating = false; }
    await Promise.all([...this.docs.values()].map((doc) => doc.sync().catch(() => {})));
    return this.identity;
  }

  async openDoc(path) {
    if (this.authentication) await this.authentication;
    if (this.invalidated) throw this.invalidated;
    let doc = this.docs.get(path);
    if (doc?.closed) { await doc.close(); return this.openDoc(path); }
    if (!doc) {
      doc = new Doc(this, path);
      this.docs.set(path, doc);
      doc.started = doc.start();
    }
    try { await doc.started; }
    catch (error) { await doc.close(); throw error; }
    return doc;
  }

  list(path = "") { return this.request("fs.list", { path }).then((r) => r.entries); }
  stat(path) { return this.request("fs.stat", { path }).then((r) => r.entry); }
  read(path) { return this.request("fs.read", { path }).then((r) => r.data); }
  write(path, data) { return this.request("fs.write", { path, data }); }
  mkdir(path) { return this.request("fs.mkdir", { path }); }
  remove(path, recursive = false) { return this.request("fs.remove", { path, recursive }); }
  rename(from, to) { return this.request("fs.rename", { from, to }); }

  /** Runs a program in the session; output arrives as `proc.out` and `proc.exit` events. */
  spawn(command, args = [], cwd = "") { return this.request("proc.spawn", { command, args, cwd }).then((r) => r.pid); }

  close() {
    this.stopped = true;
    this.recoveryDirectory.close();
    this.socket?.close();
  }
}

export { Y };
