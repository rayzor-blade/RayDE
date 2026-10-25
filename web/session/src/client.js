// The browser's side of a RayDE workspace session: files and documents over one WebSocket.
// Documents are local-first: edits apply to a Yjs document in the page at once, are kept in IndexedDB, and
// reach the session when it is reachable and the person has signed in. A reconnect catches both sides up.
import * as Y from "yjs";
import { IndexeddbPersistence } from "y-indexeddb";

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
    this.ydoc = new Y.Doc();
    this.text = this.ydoc.getText("text");
    this.closed = false;
    /** True while edits exist that the session has not acknowledged. */
    this.unsent = false;
    this.inflight = 0;
    this.failed = false;
    this.listeners = new Set();
    this.persistence = null;
    this.ydoc.on("update", (update, origin) => {
      if (origin === "session" || this.closed) return;
      this.unsent = true;
      void this.send(update);
    });
  }

  /** Waits for what the page kept of this document, then catches up with the session. */
  async start() {
    if (this.client.options.persist !== false && typeof indexedDB !== "undefined") {
      this.persistence = new IndexeddbPersistence(`rayde:${this.client.workspace ?? "workspace"}:${this.path}`, this.ydoc);
      await this.persistence.whenSynced;
    }
    await this.sync();
  }

  onChange(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** The handshake: tell the session what the page has, take what it has, and send what it lacks. */
  async sync() {
    if (this.closed || !this.client.ready) return;
    const reply = await this.client.request("doc.open", { path: this.path, vector: b64.encode(Y.encodeStateVector(this.ydoc)) });
    Y.applyUpdate(this.ydoc, b64.decode(reply.update), "session");
    const missing = Y.encodeStateAsUpdate(this.ydoc, b64.decode(reply.vector));
    // An empty update is two bytes: nothing to send.
    this.failed = false;
    if (missing.length > 2) await this.send(missing);
    else if (this.inflight === 0) this.unsent = false;
    this.listeners.forEach((listener) => listener("synced"));
  }

  async send(update) {
    if (!this.client.ready) return;
    this.inflight++;
    try {
      await this.client.request("doc.update", { path: this.path, update: b64.encode(update) });
    } catch (error) {
      this.failed = true;
      if (error.code === "auth-required") this.client.needSignIn(error.login);
      // Anything else is retried by the next handshake.
    } finally {
      // Unsent until every update in flight has been taken and none failed.
      if (--this.inflight === 0 && !this.failed) this.unsent = false;
    }
  }

  async save() {
    return this.client.request("doc.save", { path: this.path });
  }

  async close() {
    this.closed = true;
    await this.persistence?.destroy();
    this.ydoc.destroy();
    if (this.client.ready) await this.client.request("doc.close", { path: this.path }).catch(() => {});
    this.client.docs.delete(this.path);
  }
}

export class SessionClient {
  /**
   * @param {{url: string, token?: string, credential?: string, persist?: boolean, reconnect?: boolean}} options
   *   `url` is the session's WebSocket address; `credential` is what the sign-in edge gave, if the person has signed in.
   */
  constructor(options) {
    this.options = options;
    this.socket = null;
    this.ready = false;
    this.workspace = null;
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
  }

  on(event, handler) {
    if (!this.handlers.has(event)) this.handlers.set(event, new Set());
    this.handlers.get(event).add(handler);
    return () => this.handlers.get(event).delete(handler);
  }

  emit(event, detail) {
    this.handlers.get(event)?.forEach((handler) => handler(detail));
  }

  /** Connects, and keeps reconnecting until `close()`. Resolves when the first connection is ready. */
  connect() {
    return new Promise((resolve, reject) => {
      let first = true;
      const open = () => {
        if (this.stopped) return;
        const socket = new WebSocket(this.options.url);
        this.socket = socket;
        socket.onmessage = (message) => this.receive(JSON.parse(message.data));
        socket.onopen = async () => {
          try {
            this.hello = await this.rawRequest("hello", { token: this.options.token });
            this.workspace = this.hello.name;
            this.ready = true;
            this.attempt = 0;
            if (this.credential) await this.login(this.credential).catch(() => {});
            this.pendingAuth = !!this.hello.signin && !this.identity;
            this.emit("connected", this.hello);
            await Promise.all([...this.docs.values()].map((doc) => doc.sync().catch(() => {})));
            if (first) { first = false; resolve(this.hello); }
          } catch (error) {
            if (first) { first = false; reject(error); }
          }
        };
        socket.onclose = () => {
          const wasReady = this.ready;
          this.ready = false;
          for (const [, reply] of this.waiting) reply.reject(new Error("The connection closed."));
          this.waiting.clear();
          if (wasReady) this.emit("disconnected");
          if (first && !wasReady && this.options.reconnect === false) { first = false; reject(new Error("Could not connect.")); }
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
      const id = this.next++;
      this.waiting.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ ...params, op, id }));
    });
  }

  request(op, params) {
    if (!this.ready) return Promise.reject(new Error("Not connected."));
    return this.rawRequest(op, params);
  }

  /** The sign-in the session asks for: the page opens `url`, and later calls `login` with what the edge returns. */
  needSignIn(url) {
    this.pendingAuth = true;
    this.emit("auth-required", { login: url });
  }

  async login(credential) {
    const reply = await this.request("auth.login", { credential });
    this.credential = credential;
    this.identity = { login: reply.login, id: reply.id };
    this.pendingAuth = false;
    this.emit("signed-in", this.identity);
    // Whatever was edited before signing in goes now.
    await Promise.all([...this.docs.values()].map((doc) => doc.sync().catch(() => {})));
    return this.identity;
  }

  async openDoc(path) {
    let doc = this.docs.get(path);
    if (!doc) {
      doc = new Doc(this, path);
      this.docs.set(path, doc);
      await doc.start();
    }
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
