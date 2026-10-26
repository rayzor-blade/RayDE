// The browser's side of a RayDE workspace session: files and documents over one WebSocket.
// Documents are local-first: edits apply to a Yjs document in the page at once, are kept in IndexedDB, and
// reach the session when it is reachable and the person has signed in. A reconnect catches both sides up.
import * as Y from "yjs";
import { IndexeddbPersistence } from "y-indexeddb";

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

  /** Waits for what the page kept of this document, then catches up with the session. */
  async start() {
    await this.recover();
    await this.sync();
  }

  async recover() {
    if (this.client.options.persist !== false && this.client.cacheable && typeof indexedDB !== "undefined") {
      this.persistence = new IndexeddbPersistence(`rayde:v2:${JSON.stringify([this.workspace,this.path])}`, this.ydoc);
      await this.persistence.whenSynced;
    }
  }

  async moveRecovery() {
    await this.persistence?.destroy(); this.persistence = null;
    this.workspace = this.client.workspace;
    if (!this.closed) await this.recover();
  }

  async checkpoint() {
    await this.started?.catch(() => {});
    const persistence = this.persistence;
    if (!persistence || this.closed) return;
    await persistence.whenSynced;
    await new Promise((resolve, reject) => {
      const transaction = persistence.db.transaction("updates", "readwrite");
      transaction.oncomplete = () => resolve();
      transaction.onerror = transaction.onabort = () => reject(transaction.error ?? new Error("Could not preserve document recovery."));
      transaction.objectStore("updates").add(Y.encodeStateAsUpdate(this.ydoc));
    });
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
    if (this.closed || !this.client.ready) return;
    const reply = await this.client.request("doc.open", { path: this.path, vector: b64.encode(Y.encodeStateVector(this.ydoc)) });
    if (this.closed) return;
    Y.applyUpdate(this.ydoc, b64.decode(reply.update), "session");
    const missing = Y.encodeStateAsUpdate(this.ydoc, b64.decode(reply.vector));
    // An empty update is two bytes: nothing to send.
    this.failed = false;
    if (missing.length > 2 || this.client.hello?.durableUpdates) await this.send(missing);
    else if (this.inflight === 0) this.unsent = false;
    this.listeners.forEach((listener) => listener("synced"));
  }

  send(update) {
    if (!this.client.ready || this.client.authenticating || this.closed) return Promise.resolve();
    const work = this.transmit(update, this.localVersion);
    this.pending.add(work);
    work.finally(() => this.pending.delete(work));
    return work;
  }

  async transmit(update, version) {
    this.inflight++;
    try {
      await this.client.request("doc.update", { path: this.path, update: b64.encode(update) });
      this.acknowledgedVersion = Math.max(this.acknowledgedVersion,version);
    } catch (error) {
      this.failed = true;
      if (error.code === "auth-required") this.client.needSignIn(error.login);
      // Anything else is retried by the next handshake.
    } finally {
      // Unsent until every update in flight has been taken and none failed.
      if (--this.inflight === 0 && !this.failed && this.acknowledgedVersion === this.localVersion) this.unsent = false;
    }
  }

  async save() {
    // Edits queued before Save must reach the session before its file is flushed.
    await Promise.all([...this.pending]);
    if (this.syncing) await this.syncing;
    if (this.closed) throw new Error("The shared document is closed.");
    if (this.unsent) await this.sync();
    if (this.unsent) throw new Error("Reconnect before saving this document. Its edits are kept in this browser.");
    return this.client.request("doc.save", { path: this.path });
  }

  close() {
    if (this.closing) return this.closing;
    this.closed = true;
    this.closing = (async () => {
      await this.persistence?.destroy();
      this.ydoc.destroy();
      this.listeners.clear();
      if (this.client.ready) await this.client.request("doc.close", { path: this.path }).catch(() => {});
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
      if (doc) {
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
      await Promise.all(documents.filter(doc => doc.workspace !== this.workspace).map(doc => doc.moveRecovery()));
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
    this.socket?.close();
  }
}

export { Y };
