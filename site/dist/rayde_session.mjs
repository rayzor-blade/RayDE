// src/entry.js
function pageEntry(location2, connection = null) {
  const url = new URL(location2.href), query2 = url.searchParams;
  const landing = ["rayde.org", "www.rayde.org"].includes(url.hostname);
  const workspace = !landing && /^\/[\w-]{43}$/.test(url.pathname) ? url.pathname.slice(1) : null;
  const socket = workspace ? new URL(`/api/workspaces/${workspace}/socket`, url.origin) : null;
  if (socket) socket.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const explicit = query2.get("session");
  const remembered = !workspace && !explicit && query2.get("demo") !== "1" ? connection : null;
  const endpoint2 = socket?.href ?? explicit ?? remembered?.endpoint ?? null;
  const token2 = workspace ? void 0 : explicit ? new URLSearchParams(url.hash.slice(1)).get("token") : remembered?.token;
  const project = query2.get("project") ?? remembered?.project ?? null;
  return { workspace, endpoint: endpoint2, token: token2, project, demo: !endpoint2 && (query2.get("demo") === "1" || landing && query2.get("demo") !== "0") };
}

// src/connection.js
var KEY = "rayde.workspaceConnection.v1";
function connectionSettings(value) {
  if (!value || value.version !== 1) throw new Error("Invalid connection settings.");
  let endpoint2 = null;
  if (value.endpoint) {
    const url = new URL(value.endpoint);
    if (!["ws:", "wss:"].includes(url.protocol) || url.username || url.password || url.hash) throw new Error("Use a ws:// or wss:// session address.");
    endpoint2 = url.href;
  }
  const token2 = value.token ?? "", project = value.project ?? "";
  if (typeof token2 !== "string" || token2.length > 4096 || typeof project !== "string" || project.length > 4096) throw new Error("Invalid workspace settings.");
  const environment = value.environment ?? [];
  if (!Array.isArray(environment) || environment.length > 128 || environment.some((entry2) => typeof entry2 !== "string" || entry2.length > 8192 || !/^[A-Za-z_][A-Za-z0-9_]*=/.test(entry2) || /[\r\n\0]/.test(entry2))) throw new Error("Enter one NAME=value environment variable per line.");
  return { version: 1, endpoint: endpoint2, token: token2, project, environment };
}
function readConnection(storage2) {
  try {
    return connectionSettings(JSON.parse((storage2 ?? globalThis.localStorage).getItem(KEY)));
  } catch {
    return null;
  }
}

// src/preset.js
function samplePreset(value) {
  if (!value || value.version !== 1 || typeof value.name !== "string" || value.name.length > 128 || !Array.isArray(value.entries) || value.entries.length > 256) throw new Error("Invalid sample workspace.");
  const safe = (path) => typeof path === "string" && path.startsWith("/work/") && path.split("/").slice(1).every((part) => part && part !== "." && part !== ".." && !part.includes("\\") && !part.includes("\0"));
  if (!safe(value.root) || !safe("/work/" + value.project) || !("/work/" + value.project).startsWith(value.root + "/")) throw new Error("Invalid sample workspace path.");
  let bytes = 0;
  const paths = /* @__PURE__ */ new Set();
  for (const entry2 of value.entries) {
    if (entry2.path !== "/work" && entry2.path !== value.root && !(safe(entry2.path) && entry2.path.startsWith(value.root + "/")) || paths.has(entry2.path)) throw new Error("Invalid sample entry.");
    paths.add(entry2.path);
    if (typeof entry2.directory !== "boolean" || entry2.directory && entry2.data != null || !entry2.directory && (typeof entry2.data !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(entry2.data))) throw new Error("Invalid sample contents.");
    bytes += entry2.data?.length ?? 0;
  }
  if (bytes > 2 * 1024 * 1024 || !value.entries.some((entry2) => entry2.path === value.root && entry2.directory) || !value.entries.some((entry2) => entry2.path === "/work/" + value.project && !entry2.directory)) throw new Error("Incomplete sample workspace.");
  return value;
}
function seedSample(database, value) {
  const preset = samplePreset(value);
  return new Promise((resolve, reject) => {
    const transaction = database.transaction("files", "readwrite"), store = transaction.objectStore("files");
    transaction.oncomplete = () => resolve();
    transaction.onerror = transaction.onabort = () => reject(transaction.error ?? Error("Could not save the sample workspace."));
    for (const entry2 of preset.entries) {
      const request = store.get(entry2.path);
      request.onsuccess = () => {
        if (request.result === void 0) store.put(entry2);
        else if (request.result.directory !== entry2.directory) transaction.abort();
      };
    }
  });
}

// src/accounts.js
var Accounts = class {
  constructor({ fetch: fetch2 = globalThis.fetch.bind(globalThis), location: location2 = globalThis.location, later = (fn) => setTimeout(fn, 60) } = {}) {
    this.fetch = fetch2;
    this.location = location2;
    this.later = later;
    this.csrf = null;
    this.installUrl = null;
    this.landing = ["rayde.org", "www.rayde.org"].includes(new URL(location2?.href ?? "http://localhost").hostname);
  }
  async api(path, body) {
    const response = await this.fetch(path, {
      credentials: "same-origin",
      method: body === void 0 ? "GET" : "POST",
      headers: body === void 0 ? {} : { "Content-Type": "application/json", "X-RayDE-CSRF": this.csrf ?? "" },
      ...body === void 0 ? {} : { body: JSON.stringify(body) }
    });
    if (response.status === 401 && path === "/api/session") return { user: null };
    if (!response.headers.get("Content-Type")?.includes("application/json")) throw new Error("Connect this editor to the workspace service to sign in.");
    const reply = await response.json();
    if (!response.ok) throw new Error(reply.message ?? "The workspace request failed.");
    return reply;
  }
  async request(op, params2) {
    if (op === "account.status") {
      if (this.landing) return { user: null, installable: false };
      const session = await this.api("/api/session");
      this.csrf = session.csrf ?? null;
      this.installUrl = session.installUrl ?? null;
      return { user: session.user, installable: !!this.installUrl };
    }
    if (op === "account.repositories") return this.api("/api/repositories" + (params2.cursor ? "?cursor=" + encodeURIComponent(params2.cursor) : ""));
    if (op === "account.open") return this.api("/api/workspaces/open", { repository: params2.repository });
    if (op === "account.workspace") return this.api("/api/workspaces/" + encodeURIComponent(params2.workspace));
    if (op === "account.signin") {
      this.later(() => this.location.assign(this.landing ? "https://app.rayde.org/auth/github/start" : "/auth/github/start"));
      return {};
    }
    if (op === "account.install") {
      const url = new URL(this.installUrl ?? "https://github.com");
      if (!this.installUrl || url.origin !== "https://github.com" || !url.pathname.startsWith("/apps/")) throw new Error("The GitHub App is not configured.");
      this.later(() => this.location.assign(url.href));
      return {};
    }
    if (op === "account.signout") {
      await this.api("/api/logout", {});
      this.csrf = null;
      this.later(() => this.location.assign(this.location.origin));
      return {};
    }
    if (op === "account.connect") {
      if (!/^[\w-]{43}$/.test(params2.workspace)) throw new Error("Choose a repository workspace.");
      const url = new URL("/" + params2.workspace, this.location.origin);
      this.later(() => this.location.assign(url.href));
      return {};
    }
    throw new Error("Unknown account request.");
  }
};

// node_modules/lib0/map.js
var create = () => /* @__PURE__ */ new Map();
var copy = (m) => {
  const r = create();
  m.forEach((v2, k) => {
    r.set(k, v2);
  });
  return r;
};
var setIfUndefined = (map2, key, createT) => {
  let set = map2.get(key);
  if (set === void 0) {
    map2.set(key, set = createT());
  }
  return set;
};
var map = (m, f2) => {
  const res = [];
  for (const [key, value] of m) {
    res.push(f2(value, key));
  }
  return res;
};
var any = (m, f2) => {
  for (const [key, value] of m) {
    if (f2(value, key)) {
      return true;
    }
  }
  return false;
};

// node_modules/lib0/set.js
var create2 = () => /* @__PURE__ */ new Set();

// node_modules/lib0/array.js
var last = (arr) => arr[arr.length - 1];
var appendTo = (dest, src) => {
  for (let i = 0; i < src.length; i++) {
    dest.push(src[i]);
  }
};
var from = Array.from;
var every = (arr, f2) => {
  for (let i = 0; i < arr.length; i++) {
    if (!f2(arr[i], i, arr)) {
      return false;
    }
  }
  return true;
};
var some = (arr, f2) => {
  for (let i = 0; i < arr.length; i++) {
    if (f2(arr[i], i, arr)) {
      return true;
    }
  }
  return false;
};
var unfold = (len, f2) => {
  const array = new Array(len);
  for (let i = 0; i < len; i++) {
    array[i] = f2(i, array);
  }
  return array;
};
var isArray = Array.isArray;

// node_modules/lib0/observable.js
var ObservableV2 = class {
  constructor() {
    this._observers = create();
  }
  /**
   * @template {keyof EVENTS & string} NAME
   * @param {NAME} name
   * @param {EVENTS[NAME]} f
   */
  on(name, f2) {
    setIfUndefined(
      this._observers,
      /** @type {string} */
      name,
      create2
    ).add(f2);
    return f2;
  }
  /**
   * @template {keyof EVENTS & string} NAME
   * @param {NAME} name
   * @param {EVENTS[NAME]} f
   */
  once(name, f2) {
    const _f = (...args2) => {
      this.off(
        name,
        /** @type {any} */
        _f
      );
      f2(...args2);
    };
    this.on(
      name,
      /** @type {any} */
      _f
    );
  }
  /**
   * @template {keyof EVENTS & string} NAME
   * @param {NAME} name
   * @param {EVENTS[NAME]} f
   */
  off(name, f2) {
    const observers = this._observers.get(name);
    if (observers !== void 0) {
      observers.delete(f2);
      if (observers.size === 0) {
        this._observers.delete(name);
      }
    }
  }
  /**
   * Emit a named event. All registered event listeners that listen to the
   * specified name will receive the event.
   *
   * @todo This should catch exceptions
   *
   * @template {keyof EVENTS & string} NAME
   * @param {NAME} name The event name.
   * @param {Parameters<EVENTS[NAME]>} args The arguments that are applied to the event listener.
   */
  emit(name, args2) {
    return from((this._observers.get(name) || create()).values()).forEach((f2) => f2(...args2));
  }
  destroy() {
    this._observers = create();
  }
};
var Observable = class {
  constructor() {
    this._observers = create();
  }
  /**
   * @param {N} name
   * @param {function} f
   */
  on(name, f2) {
    setIfUndefined(this._observers, name, create2).add(f2);
  }
  /**
   * @param {N} name
   * @param {function} f
   */
  once(name, f2) {
    const _f = (...args2) => {
      this.off(name, _f);
      f2(...args2);
    };
    this.on(name, _f);
  }
  /**
   * @param {N} name
   * @param {function} f
   */
  off(name, f2) {
    const observers = this._observers.get(name);
    if (observers !== void 0) {
      observers.delete(f2);
      if (observers.size === 0) {
        this._observers.delete(name);
      }
    }
  }
  /**
   * Emit a named event. All registered event listeners that listen to the
   * specified name will receive the event.
   *
   * @todo This should catch exceptions
   *
   * @param {N} name The event name.
   * @param {Array<any>} args The arguments that are applied to the event listener.
   */
  emit(name, args2) {
    return from((this._observers.get(name) || create()).values()).forEach((f2) => f2(...args2));
  }
  destroy() {
    this._observers = create();
  }
};

// node_modules/lib0/math.js
var floor = Math.floor;
var abs = Math.abs;
var min = (a3, b) => a3 < b ? a3 : b;
var max = (a3, b) => a3 > b ? a3 : b;
var isNaN = Number.isNaN;
var isNegativeZero = (n) => n !== 0 ? n < 0 : 1 / n < 0;

// node_modules/lib0/binary.js
var BIT1 = 1;
var BIT2 = 2;
var BIT3 = 4;
var BIT4 = 8;
var BIT6 = 32;
var BIT7 = 64;
var BIT8 = 128;
var BIT18 = 1 << 17;
var BIT19 = 1 << 18;
var BIT20 = 1 << 19;
var BIT21 = 1 << 20;
var BIT22 = 1 << 21;
var BIT23 = 1 << 22;
var BIT24 = 1 << 23;
var BIT25 = 1 << 24;
var BIT26 = 1 << 25;
var BIT27 = 1 << 26;
var BIT28 = 1 << 27;
var BIT29 = 1 << 28;
var BIT30 = 1 << 29;
var BIT31 = 1 << 30;
var BIT32 = 1 << 31;
var BITS5 = 31;
var BITS6 = 63;
var BITS7 = 127;
var BITS17 = BIT18 - 1;
var BITS18 = BIT19 - 1;
var BITS19 = BIT20 - 1;
var BITS20 = BIT21 - 1;
var BITS21 = BIT22 - 1;
var BITS22 = BIT23 - 1;
var BITS23 = BIT24 - 1;
var BITS24 = BIT25 - 1;
var BITS25 = BIT26 - 1;
var BITS26 = BIT27 - 1;
var BITS27 = BIT28 - 1;
var BITS28 = BIT29 - 1;
var BITS29 = BIT30 - 1;
var BITS30 = BIT31 - 1;
var BITS31 = 2147483647;

// node_modules/lib0/number.js
var MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER;
var MIN_SAFE_INTEGER = Number.MIN_SAFE_INTEGER;
var LOWEST_INT32 = 1 << 31;
var isInteger = Number.isInteger || ((num) => typeof num === "number" && isFinite(num) && floor(num) === num);
var isNaN2 = Number.isNaN;
var parseInt = Number.parseInt;

// node_modules/lib0/string.js
var fromCharCode = String.fromCharCode;
var fromCodePoint = String.fromCodePoint;
var MAX_UTF16_CHARACTER = fromCharCode(65535);
var toLowerCase = (s) => s.toLowerCase();
var trimLeftRegex = /^\s*/g;
var trimLeft = (s) => s.replace(trimLeftRegex, "");
var fromCamelCaseRegex = /([A-Z])/g;
var fromCamelCase = (s, separator) => trimLeft(s.replace(fromCamelCaseRegex, (match2) => `${separator}${toLowerCase(match2)}`));
var _encodeUtf8Polyfill = (str) => {
  const encodedString = unescape(encodeURIComponent(str));
  const len = encodedString.length;
  const buf = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    buf[i] = /** @type {number} */
    encodedString.codePointAt(i);
  }
  return buf;
};
var utf8TextEncoder = (
  /** @type {TextEncoder} */
  typeof TextEncoder !== "undefined" ? new TextEncoder() : null
);
var _encodeUtf8Native = (str) => utf8TextEncoder.encode(str);
var encodeUtf8 = utf8TextEncoder ? _encodeUtf8Native : _encodeUtf8Polyfill;
var utf8TextDecoder = typeof TextDecoder === "undefined" ? null : new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
if (utf8TextDecoder && utf8TextDecoder.decode(new Uint8Array()).length === 1) {
  utf8TextDecoder = null;
}
var repeat = (source, n) => unfold(n, () => source).join("");

// node_modules/lib0/encoding.js
var Encoder = class {
  constructor() {
    this.cpos = 0;
    this.cbuf = new Uint8Array(100);
    this.bufs = [];
  }
};
var createEncoder = () => new Encoder();
var length = (encoder) => {
  let len = encoder.cpos;
  for (let i = 0; i < encoder.bufs.length; i++) {
    len += encoder.bufs[i].length;
  }
  return len;
};
var toUint8Array = (encoder) => {
  const uint8arr = new Uint8Array(length(encoder));
  let curPos = 0;
  for (let i = 0; i < encoder.bufs.length; i++) {
    const d = encoder.bufs[i];
    uint8arr.set(d, curPos);
    curPos += d.length;
  }
  uint8arr.set(new Uint8Array(encoder.cbuf.buffer, 0, encoder.cpos), curPos);
  return uint8arr;
};
var verifyLen = (encoder, len) => {
  const bufferLen = encoder.cbuf.length;
  if (bufferLen - encoder.cpos < len) {
    encoder.bufs.push(new Uint8Array(encoder.cbuf.buffer, 0, encoder.cpos));
    encoder.cbuf = new Uint8Array(max(bufferLen, len) * 2);
    encoder.cpos = 0;
  }
};
var write = (encoder, num) => {
  const bufferLen = encoder.cbuf.length;
  if (encoder.cpos === bufferLen) {
    encoder.bufs.push(encoder.cbuf);
    encoder.cbuf = new Uint8Array(bufferLen * 2);
    encoder.cpos = 0;
  }
  encoder.cbuf[encoder.cpos++] = num;
};
var writeUint8 = write;
var writeVarUint = (encoder, num) => {
  while (num > BITS7) {
    write(encoder, BIT8 | BITS7 & num);
    num = floor(num / 128);
  }
  write(encoder, BITS7 & num);
};
var writeVarInt = (encoder, num) => {
  const isNegative = isNegativeZero(num);
  if (isNegative) {
    num = -num;
  }
  write(encoder, (num > BITS6 ? BIT8 : 0) | (isNegative ? BIT7 : 0) | BITS6 & num);
  num = floor(num / 64);
  while (num > 0) {
    write(encoder, (num > BITS7 ? BIT8 : 0) | BITS7 & num);
    num = floor(num / 128);
  }
};
var _strBuffer = new Uint8Array(3e4);
var _maxStrBSize = _strBuffer.length / 3;
var _writeVarStringNative = (encoder, str) => {
  if (str.length < _maxStrBSize) {
    const written = utf8TextEncoder.encodeInto(str, _strBuffer).written || 0;
    writeVarUint(encoder, written);
    for (let i = 0; i < written; i++) {
      write(encoder, _strBuffer[i]);
    }
  } else {
    writeVarUint8Array(encoder, encodeUtf8(str));
  }
};
var _writeVarStringPolyfill = (encoder, str) => {
  const encodedString = unescape(encodeURIComponent(str));
  const len = encodedString.length;
  writeVarUint(encoder, len);
  for (let i = 0; i < len; i++) {
    write(
      encoder,
      /** @type {number} */
      encodedString.codePointAt(i)
    );
  }
};
var writeVarString = utf8TextEncoder && /** @type {any} */
utf8TextEncoder.encodeInto ? _writeVarStringNative : _writeVarStringPolyfill;
var writeUint8Array = (encoder, uint8Array) => {
  const bufferLen = encoder.cbuf.length;
  const cpos = encoder.cpos;
  const leftCopyLen = min(bufferLen - cpos, uint8Array.length);
  const rightCopyLen = uint8Array.length - leftCopyLen;
  encoder.cbuf.set(uint8Array.subarray(0, leftCopyLen), cpos);
  encoder.cpos += leftCopyLen;
  if (rightCopyLen > 0) {
    encoder.bufs.push(encoder.cbuf);
    encoder.cbuf = new Uint8Array(max(bufferLen * 2, rightCopyLen));
    encoder.cbuf.set(uint8Array.subarray(leftCopyLen));
    encoder.cpos = rightCopyLen;
  }
};
var writeVarUint8Array = (encoder, uint8Array) => {
  writeVarUint(encoder, uint8Array.byteLength);
  writeUint8Array(encoder, uint8Array);
};
var writeOnDataView = (encoder, len) => {
  verifyLen(encoder, len);
  const dview = new DataView(encoder.cbuf.buffer, encoder.cpos, len);
  encoder.cpos += len;
  return dview;
};
var writeFloat32 = (encoder, num) => writeOnDataView(encoder, 4).setFloat32(0, num, false);
var writeFloat64 = (encoder, num) => writeOnDataView(encoder, 8).setFloat64(0, num, false);
var writeBigInt64 = (encoder, num) => (
  /** @type {any} */
  writeOnDataView(encoder, 8).setBigInt64(0, num, false)
);
var floatTestBed = new DataView(new ArrayBuffer(4));
var isFloat32 = (num) => {
  floatTestBed.setFloat32(0, num);
  return floatTestBed.getFloat32(0) === num;
};
var writeAny = (encoder, data) => {
  switch (typeof data) {
    case "string":
      write(encoder, 119);
      writeVarString(encoder, data);
      break;
    case "number":
      if (isInteger(data) && abs(data) <= BITS31) {
        write(encoder, 125);
        writeVarInt(encoder, data);
      } else if (isFloat32(data)) {
        write(encoder, 124);
        writeFloat32(encoder, data);
      } else {
        write(encoder, 123);
        writeFloat64(encoder, data);
      }
      break;
    case "bigint":
      write(encoder, 122);
      writeBigInt64(encoder, data);
      break;
    case "object":
      if (data === null) {
        write(encoder, 126);
      } else if (isArray(data)) {
        write(encoder, 117);
        writeVarUint(encoder, data.length);
        for (let i = 0; i < data.length; i++) {
          writeAny(encoder, data[i]);
        }
      } else if (data instanceof Uint8Array) {
        write(encoder, 116);
        writeVarUint8Array(encoder, data);
      } else {
        write(encoder, 118);
        const keys2 = Object.keys(data);
        writeVarUint(encoder, keys2.length);
        for (let i = 0; i < keys2.length; i++) {
          const key = keys2[i];
          writeVarString(encoder, key);
          writeAny(encoder, data[key]);
        }
      }
      break;
    case "boolean":
      write(encoder, data ? 120 : 121);
      break;
    default:
      write(encoder, 127);
  }
};
var RleEncoder = class extends Encoder {
  /**
   * @param {function(Encoder, T):void} writer
   */
  constructor(writer) {
    super();
    this.w = writer;
    this.s = null;
    this.count = 0;
  }
  /**
   * @param {T} v
   */
  write(v2) {
    if (this.s === v2) {
      this.count++;
    } else {
      if (this.count > 0) {
        writeVarUint(this, this.count - 1);
      }
      this.count = 1;
      this.w(this, v2);
      this.s = v2;
    }
  }
};
var flushUintOptRleEncoder = (encoder) => {
  if (encoder.count > 0) {
    writeVarInt(encoder.encoder, encoder.count === 1 ? encoder.s : -encoder.s);
    if (encoder.count > 1) {
      writeVarUint(encoder.encoder, encoder.count - 2);
    }
  }
};
var UintOptRleEncoder = class {
  constructor() {
    this.encoder = new Encoder();
    this.s = 0;
    this.count = 0;
  }
  /**
   * @param {number} v
   */
  write(v2) {
    if (this.s === v2) {
      this.count++;
    } else {
      flushUintOptRleEncoder(this);
      this.count = 1;
      this.s = v2;
    }
  }
  /**
   * Flush the encoded state and transform this to a Uint8Array.
   *
   * Note that this should only be called once.
   */
  toUint8Array() {
    flushUintOptRleEncoder(this);
    return toUint8Array(this.encoder);
  }
};
var flushIntDiffOptRleEncoder = (encoder) => {
  if (encoder.count > 0) {
    const encodedDiff = encoder.diff * 2 + (encoder.count === 1 ? 0 : 1);
    writeVarInt(encoder.encoder, encodedDiff);
    if (encoder.count > 1) {
      writeVarUint(encoder.encoder, encoder.count - 2);
    }
  }
};
var IntDiffOptRleEncoder = class {
  constructor() {
    this.encoder = new Encoder();
    this.s = 0;
    this.count = 0;
    this.diff = 0;
  }
  /**
   * @param {number} v
   */
  write(v2) {
    if (this.diff === v2 - this.s) {
      this.s = v2;
      this.count++;
    } else {
      flushIntDiffOptRleEncoder(this);
      this.count = 1;
      this.diff = v2 - this.s;
      this.s = v2;
    }
  }
  /**
   * Flush the encoded state and transform this to a Uint8Array.
   *
   * Note that this should only be called once.
   */
  toUint8Array() {
    flushIntDiffOptRleEncoder(this);
    return toUint8Array(this.encoder);
  }
};
var StringEncoder = class {
  constructor() {
    this.sarr = [];
    this.s = "";
    this.lensE = new UintOptRleEncoder();
  }
  /**
   * @param {string} string
   */
  write(string) {
    this.s += string;
    if (this.s.length > 19) {
      this.sarr.push(this.s);
      this.s = "";
    }
    this.lensE.write(string.length);
  }
  toUint8Array() {
    const encoder = new Encoder();
    this.sarr.push(this.s);
    this.s = "";
    writeVarString(encoder, this.sarr.join(""));
    writeUint8Array(encoder, this.lensE.toUint8Array());
    return toUint8Array(encoder);
  }
};

// node_modules/lib0/error.js
var create3 = (s) => new Error(s);
var methodUnimplemented = () => {
  throw create3("Method unimplemented");
};
var unexpectedCase = () => {
  throw create3("Unexpected case");
};

// node_modules/lib0/decoding.js
var errorUnexpectedEndOfArray = create3("Unexpected end of array");
var errorIntegerOutOfRange = create3("Integer out of Range");
var subarray = (arr, begin, len) => {
  if (begin < 0 || len < 0 || begin + len > arr.length) {
    throw errorUnexpectedEndOfArray;
  }
  return new Uint8Array(arr.buffer, arr.byteOffset + begin, len);
};
var subdataview = (arr, begin, len) => {
  if (begin < 0 || len < 0 || begin + len > arr.length) {
    throw errorUnexpectedEndOfArray;
  }
  return new DataView(arr.buffer, arr.byteOffset + begin, len);
};
var Decoder = class {
  /**
   * @param {Uint8Array<Buf>} uint8Array Binary data to decode
   */
  constructor(uint8Array) {
    this.arr = uint8Array;
    this.pos = 0;
  }
};
var createDecoder = (uint8Array) => new Decoder(uint8Array);
var hasContent = (decoder) => decoder.pos !== decoder.arr.length;
var readUint8Array = (decoder, len) => {
  const view = subarray(decoder.arr, decoder.pos, len);
  decoder.pos += len;
  return view;
};
var readVarUint8Array = (decoder) => readUint8Array(decoder, readVarUint(decoder));
var readUint8 = (decoder) => decoder.arr[decoder.pos++];
var readVarUint = (decoder) => {
  let num = 0;
  let mult = 1;
  const len = decoder.arr.length;
  while (decoder.pos < len) {
    const r = decoder.arr[decoder.pos++];
    num = num + (r & BITS7) * mult;
    mult *= 128;
    if (r < BIT8) {
      return num;
    }
    if (num > MAX_SAFE_INTEGER) {
      throw errorIntegerOutOfRange;
    }
  }
  throw errorUnexpectedEndOfArray;
};
var readVarInt = (decoder) => {
  let r = decoder.arr[decoder.pos++];
  let num = r & BITS6;
  let mult = 64;
  const sign = (r & BIT7) > 0 ? -1 : 1;
  if ((r & BIT8) === 0) {
    return sign * num;
  }
  const len = decoder.arr.length;
  while (decoder.pos < len) {
    r = decoder.arr[decoder.pos++];
    num = num + (r & BITS7) * mult;
    mult *= 128;
    if (r < BIT8) {
      return sign * num;
    }
    if (num > MAX_SAFE_INTEGER) {
      throw errorIntegerOutOfRange;
    }
  }
  throw errorUnexpectedEndOfArray;
};
var _readVarStringPolyfill = (decoder) => {
  let remainingLen = readVarUint(decoder);
  if (remainingLen === 0) {
    return "";
  } else {
    let encodedString = String.fromCodePoint(readUint8(decoder));
    if (--remainingLen < 100) {
      while (remainingLen--) {
        encodedString += String.fromCodePoint(readUint8(decoder));
      }
    } else {
      while (remainingLen > 0) {
        const nextLen = remainingLen < 1e4 ? remainingLen : 1e4;
        const bytes = decoder.arr.subarray(decoder.pos, decoder.pos + nextLen);
        decoder.pos += nextLen;
        encodedString += String.fromCodePoint.apply(
          null,
          /** @type {any} */
          bytes
        );
        remainingLen -= nextLen;
      }
    }
    return decodeURIComponent(escape(encodedString));
  }
};
var _readVarStringNative = (decoder) => (
  /** @type any */
  utf8TextDecoder.decode(readVarUint8Array(decoder))
);
var readVarString = utf8TextDecoder ? _readVarStringNative : _readVarStringPolyfill;
var readFromDataView = (decoder, len) => {
  const dv = subdataview(decoder.arr, decoder.pos, len);
  decoder.pos += len;
  return dv;
};
var readFloat32 = (decoder) => readFromDataView(decoder, 4).getFloat32(0, false);
var readFloat64 = (decoder) => readFromDataView(decoder, 8).getFloat64(0, false);
var readBigInt64 = (decoder) => (
  /** @type {any} */
  readFromDataView(decoder, 8).getBigInt64(0, false)
);
var readAnyLookupTable = [
  (decoder) => void 0,
  // CASE 127: undefined
  (decoder) => null,
  // CASE 126: null
  readVarInt,
  // CASE 125: integer
  readFloat32,
  // CASE 124: float32
  readFloat64,
  // CASE 123: float64
  readBigInt64,
  // CASE 122: bigint
  (decoder) => false,
  // CASE 121: boolean (false)
  (decoder) => true,
  // CASE 120: boolean (true)
  readVarString,
  // CASE 119: string
  (decoder) => {
    const len = readVarUint(decoder);
    const obj = {};
    for (let i = 0; i < len; i++) {
      const key = readVarString(decoder);
      obj[key] = readAny(decoder);
    }
    return obj;
  },
  (decoder) => {
    const len = readVarUint(decoder);
    const arr = [];
    for (let i = 0; i < len; i++) {
      arr.push(readAny(decoder));
    }
    return arr;
  },
  readVarUint8Array
  // CASE 116: Uint8Array
];
var readAny = (decoder) => readAnyLookupTable[127 - readUint8(decoder)](decoder);
var RleDecoder = class extends Decoder {
  /**
   * @param {Uint8Array} uint8Array
   * @param {function(Decoder):T} reader
   */
  constructor(uint8Array, reader) {
    super(uint8Array);
    this.reader = reader;
    this.s = null;
    this.count = 0;
  }
  read() {
    if (this.count === 0) {
      this.s = this.reader(this);
      if (hasContent(this)) {
        this.count = readVarUint(this) + 1;
      } else {
        this.count = -1;
      }
    }
    this.count--;
    return (
      /** @type {T} */
      this.s
    );
  }
};
var UintOptRleDecoder = class extends Decoder {
  /**
   * @param {Uint8Array} uint8Array
   */
  constructor(uint8Array) {
    super(uint8Array);
    this.s = 0;
    this.count = 0;
  }
  read() {
    if (this.count === 0) {
      this.s = readVarInt(this);
      const isNegative = isNegativeZero(this.s);
      this.count = 1;
      if (isNegative) {
        this.s = -this.s;
        this.count = readVarUint(this) + 2;
      }
    }
    this.count--;
    return (
      /** @type {number} */
      this.s
    );
  }
};
var IntDiffOptRleDecoder = class extends Decoder {
  /**
   * @param {Uint8Array} uint8Array
   */
  constructor(uint8Array) {
    super(uint8Array);
    this.s = 0;
    this.count = 0;
    this.diff = 0;
  }
  /**
   * @return {number}
   */
  read() {
    if (this.count === 0) {
      const diff = readVarInt(this);
      const hasCount = diff & 1;
      this.diff = floor(diff / 2);
      this.count = 1;
      if (hasCount) {
        this.count = readVarUint(this) + 2;
      }
    }
    this.s += this.diff;
    this.count--;
    return this.s;
  }
};
var StringDecoder = class {
  /**
   * @param {Uint8Array} uint8Array
   */
  constructor(uint8Array) {
    this.decoder = new UintOptRleDecoder(uint8Array);
    this.str = readVarString(this.decoder);
    this.spos = 0;
  }
  /**
   * @return {string}
   */
  read() {
    const end = this.spos + this.decoder.read();
    const res = this.str.slice(this.spos, end);
    this.spos = end;
    return res;
  }
};

// node_modules/lib0/webcrypto.js
var subtle = crypto.subtle;
var getRandomValues = crypto.getRandomValues.bind(crypto);

// node_modules/lib0/random.js
var uint32 = () => getRandomValues(new Uint32Array(1))[0];
var uuidv4Template = "10000000-1000-4000-8000" + -1e11;
var uuidv4 = () => uuidv4Template.replace(
  /[018]/g,
  /** @param {number} c */
  (c) => (c ^ uint32() & 15 >> c / 4).toString(16)
);

// node_modules/lib0/time.js
var getUnixTime = Date.now;

// node_modules/lib0/promise.js
var create4 = (f2) => (
  /** @type {Promise<T>} */
  new Promise(f2)
);
var all = Promise.all.bind(Promise);

// node_modules/lib0/conditions.js
var undefinedToNull = (v2) => v2 === void 0 ? null : v2;

// node_modules/lib0/storage.js
var VarStoragePolyfill = class {
  constructor() {
    this.map = /* @__PURE__ */ new Map();
  }
  /**
   * @param {string} key
   * @param {any} newValue
   */
  setItem(key, newValue) {
    this.map.set(key, newValue);
  }
  /**
   * @param {string} key
   */
  getItem(key) {
    return this.map.get(key);
  }
};
var _localStorage = new VarStoragePolyfill();
var usePolyfill = true;
try {
  if (typeof localStorage !== "undefined" && localStorage) {
    _localStorage = localStorage;
    usePolyfill = false;
  }
} catch (e) {
}
var varStorage = _localStorage;

// node_modules/lib0/trait/equality.js
var EqualityTraitSymbol = Symbol("Equality");
var equals = (a3, b) => a3 === b || !!a3?.[EqualityTraitSymbol]?.(b) || false;

// node_modules/lib0/object.js
var isObject = (o) => typeof o === "object";
var assign = Object.assign;
var keys = Object.keys;
var forEach = (obj, f2) => {
  for (const key in obj) {
    f2(obj[key], key);
  }
};
var size = (obj) => keys(obj).length;
var isEmpty = (obj) => {
  for (const _k in obj) {
    return false;
  }
  return true;
};
var every2 = (obj, f2) => {
  for (const key in obj) {
    if (!f2(obj[key], key)) {
      return false;
    }
  }
  return true;
};
var hasProperty = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
var equalFlat = (a3, b) => a3 === b || size(a3) === size(b) && every2(a3, (val, key) => (val !== void 0 || hasProperty(b, key)) && equals(b[key], val));
var freeze = Object.freeze;
var deepFreeze = (o) => {
  for (const key in o) {
    const c = o[key];
    if (typeof c === "object" || typeof c === "function") {
      deepFreeze(o[key]);
    }
  }
  return freeze(o);
};

// node_modules/lib0/function.js
var callAll = (fs, args2, i = 0) => {
  try {
    for (; i < fs.length; i++) {
      fs[i](...args2);
    }
  } finally {
    if (i < fs.length) {
      callAll(fs, args2, i + 1);
    }
  }
};
var id = (a3) => a3;
var equalityDeep = (a3, b) => {
  if (a3 === b) {
    return true;
  }
  if (a3 == null || b == null || a3.constructor !== b.constructor && (a3.constructor || Object) !== (b.constructor || Object)) {
    return false;
  }
  if (a3[EqualityTraitSymbol] != null) {
    return a3[EqualityTraitSymbol](b);
  }
  switch (a3.constructor) {
    case ArrayBuffer:
      a3 = new Uint8Array(a3);
      b = new Uint8Array(b);
    // eslint-disable-next-line no-fallthrough
    case Uint8Array: {
      if (a3.byteLength !== b.byteLength) {
        return false;
      }
      for (let i = 0; i < a3.length; i++) {
        if (a3[i] !== b[i]) {
          return false;
        }
      }
      break;
    }
    case Set: {
      if (a3.size !== b.size) {
        return false;
      }
      for (const value of a3) {
        if (!b.has(value)) {
          return false;
        }
      }
      break;
    }
    case Map: {
      if (a3.size !== b.size) {
        return false;
      }
      for (const key of a3.keys()) {
        if (!b.has(key) || !equalityDeep(a3.get(key), b.get(key))) {
          return false;
        }
      }
      break;
    }
    case void 0:
    case Object:
      if (size(a3) !== size(b)) {
        return false;
      }
      for (const key in a3) {
        if (!hasProperty(a3, key) || !equalityDeep(a3[key], b[key])) {
          return false;
        }
      }
      break;
    case Array:
      if (a3.length !== b.length) {
        return false;
      }
      for (let i = 0; i < a3.length; i++) {
        if (!equalityDeep(a3[i], b[i])) {
          return false;
        }
      }
      break;
    default:
      return false;
  }
  return true;
};
var isOneOf = (value, options) => options.includes(value);

// node_modules/lib0/environment.js
var isNode = typeof process !== "undefined" && process.release && /node|io\.js/.test(process.release.name) && Object.prototype.toString.call(typeof process !== "undefined" ? process : 0) === "[object process]";
var isMac = typeof navigator !== "undefined" ? /Mac/.test(navigator.platform) : false;
var params;
var args = [];
var computeParams = () => {
  if (params === void 0) {
    if (isNode) {
      params = create();
      const pargs = process.argv;
      let currParamName = null;
      for (let i = 0; i < pargs.length; i++) {
        const parg = pargs[i];
        if (parg[0] === "-") {
          if (currParamName !== null) {
            params.set(currParamName, "");
          }
          currParamName = parg;
        } else {
          if (currParamName !== null) {
            params.set(currParamName, parg);
            currParamName = null;
          } else {
            args.push(parg);
          }
        }
      }
      if (currParamName !== null) {
        params.set(currParamName, "");
      }
    } else if (typeof location === "object") {
      params = create();
      (location.search || "?").slice(1).split("&").forEach((kv) => {
        if (kv.length !== 0) {
          const [key, value] = kv.split("=");
          params.set(`--${fromCamelCase(key, "-")}`, value);
          params.set(`-${fromCamelCase(key, "-")}`, value);
        }
      });
    } else {
      params = create();
    }
  }
  return params;
};
var hasParam = (name) => computeParams().has(name);
var getVariable = (name) => isNode ? undefinedToNull(process.env[name.toUpperCase().replaceAll("-", "_")]) : undefinedToNull(varStorage.getItem(name));
var hasConf = (name) => hasParam("--" + name) || getVariable(name) !== null;
var production = hasConf("production");
var forceColor = isNode && isOneOf(process.env.FORCE_COLOR, ["true", "1", "2"]);
var supportsColor = forceColor || !hasParam("--no-colors") && // @todo deprecate --no-colors
!hasConf("no-color") && (!isNode || process.stdout.isTTY) && (!isNode || hasParam("--color") || getVariable("COLORTERM") !== null || (getVariable("TERM") || "").includes("color"));

// node_modules/lib0/buffer.js
var createUint8ArrayFromLen = (len) => new Uint8Array(len);
var copyUint8Array = (uint8Array) => {
  const newBuf = createUint8ArrayFromLen(uint8Array.byteLength);
  newBuf.set(uint8Array);
  return newBuf;
};

// node_modules/lib0/pair.js
var Pair = class {
  /**
   * @param {L} left
   * @param {R} right
   */
  constructor(left, right) {
    this.left = left;
    this.right = right;
  }
};
var create5 = (left, right) => new Pair(left, right);

// node_modules/lib0/prng.js
var bool = (gen) => gen.next() >= 0.5;
var int53 = (gen, min2, max2) => floor(gen.next() * (max2 + 1 - min2) + min2);
var int32 = (gen, min2, max2) => floor(gen.next() * (max2 + 1 - min2) + min2);
var int31 = (gen, min2, max2) => int32(gen, min2, max2);
var letter = (gen) => fromCharCode(int31(gen, 97, 122));
var word = (gen, minLen = 0, maxLen = 20) => {
  const len = int31(gen, minLen, maxLen);
  let str = "";
  for (let i = 0; i < len; i++) {
    str += letter(gen);
  }
  return str;
};
var oneOf = (gen, array) => array[int31(gen, 0, array.length - 1)];

// node_modules/lib0/schema.js
var schemaSymbol = Symbol("0schema");
var ValidationError = class {
  constructor() {
    this._rerrs = [];
  }
  /**
   * @param {string?} path
   * @param {string} expected
   * @param {string} has
   * @param {string?} message
   */
  extend(path, expected, has, message = null) {
    this._rerrs.push({ path, expected, has, message });
  }
  toString() {
    const s = [];
    for (let i = this._rerrs.length - 1; i > 0; i--) {
      const r = this._rerrs[i];
      s.push(repeat(" ", (this._rerrs.length - i) * 2) + `${r.path != null ? `[${r.path}] ` : ""}${r.has} doesn't match ${r.expected}. ${r.message}`);
    }
    return s.join("\n");
  }
};
var shapeExtends = (a3, b) => {
  if (a3 === b) return true;
  if (a3 == null || b == null || a3.constructor !== b.constructor) return false;
  if (a3[EqualityTraitSymbol]) return equals(a3, b);
  if (isArray(a3)) {
    return every(
      a3,
      (aitem) => some(b, (bitem) => shapeExtends(aitem, bitem))
    );
  } else if (isObject(a3)) {
    return every2(
      a3,
      (aitem, akey) => shapeExtends(aitem, b[akey])
    );
  }
  return false;
};
var Schema = class {
  // this.shape must not be defined on Schema. Otherwise typecheck on metatypes (e.g. $$object) won't work as expected anymore
  /**
   * If true, the more things are added to the shape the more objects this schema will accept (e.g.
   * union). By default, the more objects are added, the the fewer objects this schema will accept.
   * @protected
   */
  static _dilutes = false;
  /**
   * @param {Schema<any>} other
   */
  extends(other) {
    let [a3, b] = [
      /** @type {any} */
      this.shape,
      /** @type {any} */
      other.shape
    ];
    if (
      /** @type {typeof Schema<any>} */
      this.constructor._dilutes
    ) [b, a3] = [a3, b];
    return shapeExtends(a3, b);
  }
  /**
   * Overwrite this when necessary. By default, we only check the `shape` property which every shape
   * should have.
   * @param {Schema<any>} other
   */
  equals(other) {
    return this.constructor === other.constructor && equalityDeep(this.shape, other.shape);
  }
  [schemaSymbol]() {
    return true;
  }
  /**
   * @param {object} other
   */
  [EqualityTraitSymbol](other) {
    return this.equals(
      /** @type {any} */
      other
    );
  }
  /**
   * Use `schema.validate(obj)` with a typed parameter that is already of typed to be an instance of
   * Schema. Validate will check the structure of the parameter and return true iff the instance
   * really is an instance of Schema.
   *
   * @param {T} o
   * @return {boolean}
   */
  validate(o) {
    return this.check(o);
  }
  /* c8 ignore start */
  /**
   * Similar to validate, but this method accepts untyped parameters.
   *
   * @param {any} _o
   * @param {ValidationError} [_err]
   * @return {_o is T}
   */
  check(_o, _err) {
    methodUnimplemented();
  }
  /* c8 ignore stop */
  /**
   * @type {Schema<T?>}
   */
  get nullable() {
    return $union(this, $null);
  }
  /**
   * @type {$Optional<Schema<T>>}
   */
  get optional() {
    return new $Optional(
      /** @type {Schema<T>} */
      this
    );
  }
  /**
   * Cast a variable to a specific type. Returns the casted value, or throws an exception otherwise.
   * Use this if you know that the type is of a specific type and you just want to convince the type
   * system.
   *
   * **Do not rely on these error messages!**
   * Performs an assertion check only if not in a production environment.
   *
   * @template OO
   * @param {OO} o
   * @return {Extract<OO, T> extends never ? T : (OO extends Array<never> ? T : Extract<OO,T>)}
   */
  cast(o) {
    assert(o, this);
    return (
      /** @type {any} */
      o
    );
  }
  /**
   * EXPECTO PATRONUM!! 🪄
   * This function protects against type errors. Though it may not work in the real world.
   *
   * "After all this time?"
   * "Always." - Snape, talking about type safety
   *
   * Ensures that a variable is a a specific type. Returns the value, or throws an exception if the assertion check failed.
   * Use this if you know that the type is of a specific type and you just want to convince the type
   * system.
   *
   * Can be useful when defining lambdas: `s.lambda(s.$number, s.$void).expect((n) => n + 1)`
   *
   * **Do not rely on these error messages!**
   * Performs an assertion check if not in a production environment.
   *
   * @param {T} o
   * @return {o extends T ? T : never}
   */
  expect(o) {
    assert(o, this);
    return o;
  }
};
var $ConstructedBy = class extends Schema {
  /**
   * @param {C} c
   * @param {((o:Instance<C>)=>boolean)|null} check
   */
  constructor(c, check) {
    super();
    this.shape = c;
    this._c = check;
  }
  /**
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is C extends ((...args:any[]) => infer T) ? T : (C extends (new (...args:any[]) => any) ? InstanceType<C> : never)} o
   */
  check(o, err = void 0) {
    const c = o?.constructor === this.shape && (this._c == null || this._c(o));
    !c && err?.extend(null, this.shape.name, o?.constructor.name, o?.constructor !== this.shape ? "Constructor match failed" : "Check failed");
    return c;
  }
};
var $constructedBy = (c, check = null) => new $ConstructedBy(c, check);
var $$constructedBy = $constructedBy($ConstructedBy);
var $Custom = class extends Schema {
  /**
   * @param {(o:any) => boolean} check
   */
  constructor(check) {
    super();
    this.shape = check;
  }
  /**
   * @param {any} o
   * @param {ValidationError} err
   * @return {o is any}
   */
  check(o, err) {
    const c = this.shape(o);
    !c && err?.extend(null, "custom prop", o?.constructor.name, "failed to check custom prop");
    return c;
  }
};
var $custom = (check) => new $Custom(check);
var $$custom = $constructedBy($Custom);
var $Literal = class extends Schema {
  /**
   * @param {Array<T>} literals
   */
  constructor(literals) {
    super();
    this.shape = literals;
  }
  /**
   *
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is T}
   */
  check(o, err) {
    const c = this.shape.some((a3) => a3 === o);
    !c && err?.extend(null, this.shape.join(" | "), o.toString());
    return c;
  }
};
var $literal = (...literals) => new $Literal(literals);
var $$literal = $constructedBy($Literal);
var _regexEscape = (
  /** @type {any} */
  RegExp.escape || /** @type {(str:string) => string} */
  ((str) => str.replace(/[().|&,$^[\]]/g, (s) => "\\" + s))
);
var _schemaStringTemplateToRegex = (s) => {
  if ($string.check(s)) {
    return [_regexEscape(s)];
  }
  if ($$literal.check(s)) {
    return (
      /** @type {Array<string|number>} */
      s.shape.map((v2) => v2 + "")
    );
  }
  if ($$number.check(s)) {
    return ["[+-]?\\d+.?\\d*"];
  }
  if ($$string.check(s)) {
    return [".*"];
  }
  if ($$union.check(s)) {
    return s.shape.map(_schemaStringTemplateToRegex).flat(1);
  }
  unexpectedCase();
};
var $StringTemplate = class extends Schema {
  /**
   * @param {T} shape
   */
  constructor(shape) {
    super();
    this.shape = shape;
    this._r = new RegExp("^" + shape.map(_schemaStringTemplateToRegex).map((opts) => `(${opts.join("|")})`).join("") + "$");
  }
  /**
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is CastStringTemplateArgsToTemplate<T>}
   */
  check(o, err) {
    const c = this._r.exec(o) != null;
    !c && err?.extend(null, this._r.toString(), o.toString(), "String doesn't match string template.");
    return c;
  }
};
var $$stringTemplate = $constructedBy($StringTemplate);
var isOptionalSymbol = Symbol("optional");
var $Optional = class extends Schema {
  /**
   * @param {S} shape
   */
  constructor(shape) {
    super();
    this.shape = shape;
  }
  /**
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is (Unwrap<S>|undefined)}
   */
  check(o, err) {
    const c = o === void 0 || this.shape.check(o);
    !c && err?.extend(null, "undefined (optional)", "()");
    return c;
  }
  get [isOptionalSymbol]() {
    return true;
  }
};
var $$optional = $constructedBy($Optional);
var $Never = class extends Schema {
  /**
   * @param {any} _o
   * @param {ValidationError} [err]
   * @return {_o is never}
   */
  check(_o, err) {
    err?.extend(null, "never", typeof _o);
    return false;
  }
};
var $never = new $Never();
var $$never = $constructedBy($Never);
var $Object = class _$Object extends Schema {
  /**
   * @param {S} shape
   * @param {boolean} partial
   */
  constructor(shape, partial = false) {
    super();
    this.shape = shape;
    this._isPartial = partial;
  }
  static _dilutes = true;
  /**
   * @type {Schema<Partial<$ObjectToType<S>>>}
   */
  get partial() {
    return new _$Object(this.shape, true);
  }
  /**
   * @param {any} o
   * @param {ValidationError} err
   * @return {o is $ObjectToType<S>}
   */
  check(o, err) {
    if (o == null) {
      err?.extend(null, "object", "null");
      return false;
    }
    return every2(this.shape, (vv, vk) => {
      const c = this._isPartial && !hasProperty(o, vk) || vv.check(o[vk], err);
      !c && err?.extend(vk.toString(), vv.toString(), typeof o[vk], "Object property does not match");
      return c;
    });
  }
};
var $object = (def) => (
  /** @type {any} */
  new $Object(def)
);
var $$object = $constructedBy($Object);
var $objectAny = $custom((o) => o != null && (o.constructor === Object || o.constructor == null));
var $Record = class extends Schema {
  /**
   * @param {Keys} keys
   * @param {Values} values
   */
  constructor(keys2, values) {
    super();
    this.shape = {
      keys: keys2,
      values
    };
  }
  /**
   * @param {any} o
   * @param {ValidationError} err
   * @return {o is { [key in Unwrap<Keys>]: Unwrap<Values> }}
   */
  check(o, err) {
    return o != null && every2(o, (vv, vk) => {
      const ck = this.shape.keys.check(vk, err);
      !ck && err?.extend(vk + "", "Record", typeof o, ck ? "Key doesn't match schema" : "Value doesn't match value");
      return ck && this.shape.values.check(vv, err);
    });
  }
};
var $record = (keys2, values) => new $Record(keys2, values);
var $$record = $constructedBy($Record);
var $Tuple = class extends Schema {
  /**
   * @param {S} shape
   */
  constructor(shape) {
    super();
    this.shape = shape;
  }
  /**
   * @param {any} o
   * @param {ValidationError} err
   * @return {o is { [K in keyof S]: S[K] extends Schema<infer Type> ? Type : never }}
   */
  check(o, err) {
    return o != null && every2(this.shape, (vv, vk) => {
      const c = (
        /** @type {Schema<any>} */
        vv.check(o[vk], err)
      );
      !c && err?.extend(vk.toString(), "Tuple", typeof vv);
      return c;
    });
  }
};
var $tuple = (...def) => new $Tuple(def);
var $$tuple = $constructedBy($Tuple);
var $Array = class extends Schema {
  /**
   * @param {Array<S>} v
   */
  constructor(v2) {
    super();
    this.shape = v2.length === 1 ? v2[0] : new $Union(v2);
  }
  /**
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is Array<S extends Schema<infer T> ? T : never>} o
   */
  check(o, err) {
    const c = isArray(o) && every(o, (oi) => this.shape.check(oi));
    !c && err?.extend(null, "Array", "");
    return c;
  }
};
var $array = (...def) => new $Array(def);
var $$array = $constructedBy($Array);
var $arrayAny = $custom((o) => isArray(o));
var $InstanceOf = class extends Schema {
  /**
   * @param {new (...args:any) => T} constructor
   * @param {((o:T) => boolean)|null} check
   */
  constructor(constructor, check) {
    super();
    this.shape = constructor;
    this._c = check;
  }
  /**
   * @param {any} o
   * @param {ValidationError} err
   * @return {o is T}
   */
  check(o, err) {
    const c = o instanceof this.shape && (this._c == null || this._c(o));
    !c && err?.extend(null, this.shape.name, o?.constructor.name);
    return c;
  }
};
var $instanceOf = (c, check = null) => new $InstanceOf(c, check);
var $$instanceOf = $constructedBy($InstanceOf);
var $$schema = $instanceOf(Schema);
var $Lambda = class extends Schema {
  /**
   * @param {Args} args
   */
  constructor(args2) {
    super();
    this.len = args2.length - 1;
    this.args = $tuple(...args2.slice(-1));
    this.res = args2[this.len];
  }
  /**
   * @param {any} f
   * @param {ValidationError} err
   * @return {f is _LArgsToLambdaDef<Args>}
   */
  check(f2, err) {
    const c = f2.constructor === Function && f2.length <= this.len;
    !c && err?.extend(null, "function", typeof f2);
    return c;
  }
};
var $$lambda = $constructedBy($Lambda);
var $function = $custom((o) => typeof o === "function");
var $Intersection = class extends Schema {
  /**
   * @param {T} v
   */
  constructor(v2) {
    super();
    this.shape = v2;
  }
  /**
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is Intersect<UnwrapArray<T>>}
   */
  check(o, err) {
    const c = every(this.shape, (check) => check.check(o, err));
    !c && err?.extend(null, "Intersectinon", typeof o);
    return c;
  }
};
var $$intersect = $constructedBy($Intersection, (o) => o.shape.length > 0);
var $Union = class extends Schema {
  static _dilutes = true;
  /**
   * @param {Array<Schema<S>>} v
   */
  constructor(v2) {
    super();
    this.shape = v2;
  }
  /**
   * @param {any} o
   * @param {ValidationError} [err]
   * @return {o is S}
   */
  check(o, err) {
    const c = some(this.shape, (vv) => vv.check(o, err));
    err?.extend(null, "Union", typeof o);
    return c;
  }
};
var $union = (...schemas) => schemas.findIndex(($s) => $$union.check($s)) >= 0 ? $union(...schemas.map(($s) => $($s)).map(($s) => $$union.check($s) ? $s.shape : [$s]).flat(1)) : schemas.length === 1 ? schemas[0] : new $Union(schemas);
var $$union = (
  /** @type {Schema<$Union<any>>} */
  $constructedBy($Union)
);
var _t = () => true;
var $any = $custom(_t);
var $$any = (
  /** @type {Schema<Schema<any>>} */
  $constructedBy($Custom, (o) => o.shape === _t)
);
var $bigint = $custom((o) => typeof o === "bigint");
var $$bigint = (
  /** @type {Schema<Schema<BigInt>>} */
  $custom((o) => o === $bigint)
);
var $symbol = $custom((o) => typeof o === "symbol");
var $$symbol = (
  /** @type {Schema<Schema<Symbol>>} */
  $custom((o) => o === $symbol)
);
var $number = $custom((o) => typeof o === "number");
var $$number = (
  /** @type {Schema<Schema<number>>} */
  $custom((o) => o === $number)
);
var $string = $custom((o) => typeof o === "string");
var $$string = (
  /** @type {Schema<Schema<string>>} */
  $custom((o) => o === $string)
);
var $boolean = $custom((o) => typeof o === "boolean");
var $$boolean = (
  /** @type {Schema<Schema<Boolean>>} */
  $custom((o) => o === $boolean)
);
var $undefined = $literal(void 0);
var $$undefined = (
  /** @type {Schema<Schema<undefined>>} */
  $constructedBy($Literal, (o) => o.shape.length === 1 && o.shape[0] === void 0)
);
var $void = $literal(void 0);
var $null = $literal(null);
var $$null = (
  /** @type {Schema<Schema<null>>} */
  $constructedBy($Literal, (o) => o.shape.length === 1 && o.shape[0] === null)
);
var $uint8Array = $constructedBy(Uint8Array);
var $$uint8Array = (
  /** @type {Schema<Schema<Uint8Array>>} */
  $constructedBy($ConstructedBy, (o) => o.shape === Uint8Array)
);
var $primitive = $union($number, $string, $null, $undefined, $bigint, $boolean, $symbol);
var $json = (() => {
  const $jsonArr = (
    /** @type {$Array<$any>} */
    $array($any)
  );
  const $jsonRecord = (
    /** @type {$Record<$string,$any>} */
    $record($string, $any)
  );
  const $json2 = $union($number, $string, $null, $boolean, $jsonArr, $jsonRecord);
  $jsonArr.shape = $json2;
  $jsonRecord.shape.values = $json2;
  return $json2;
})();
var $ = (o) => {
  if ($$schema.check(o)) {
    return (
      /** @type {any} */
      o
    );
  } else if ($objectAny.check(o)) {
    const o2 = {};
    for (const k in o) {
      o2[k] = $(o[k]);
    }
    return (
      /** @type {any} */
      $object(o2)
    );
  } else if ($arrayAny.check(o)) {
    return (
      /** @type {any} */
      $union(...o.map($))
    );
  } else if ($primitive.check(o)) {
    return (
      /** @type {any} */
      $literal(o)
    );
  } else if ($function.check(o)) {
    return (
      /** @type {any} */
      $constructedBy(
        /** @type {any} */
        o
      )
    );
  }
  unexpectedCase();
};
var assert = production ? () => {
} : (o, schema) => {
  const err = new ValidationError();
  if (!schema.check(o, err)) {
    throw create3(`Expected value to be of type ${schema.constructor.name}.
${err.toString()}`);
  }
};
var PatternMatcher = class {
  /**
   * @param {Schema<State>} [$state]
   */
  constructor($state) {
    this.patterns = [];
    this.$state = $state;
  }
  /**
   * @template P
   * @template R
   * @param {P} pattern
   * @param {(o:NoInfer<Unwrap<ReadSchema<P>>>,s:State)=>R} handler
   * @return {PatternMatcher<State,Patterns|Pattern<Unwrap<ReadSchema<P>>,R>>}
   */
  if(pattern, handler) {
    this.patterns.push({ if: $(pattern), h: handler });
    return this;
  }
  /**
   * @template R
   * @param {(o:any,s:State)=>R} h
   */
  else(h2) {
    return this.if($any, h2);
  }
  /**
   * @return {State extends undefined
   *   ? <In extends Unwrap<Patterns['if']>>(o:In,state?:undefined)=>PatternMatchResult<Patterns,In>
   *   : <In extends Unwrap<Patterns['if']>>(o:In,state:State)=>PatternMatchResult<Patterns,In>}
   */
  done() {
    return (
      /** @type {any} */
      (o, s) => {
        for (let i = 0; i < this.patterns.length; i++) {
          const p = this.patterns[i];
          if (p.if.check(o)) {
            return p.h(o, s);
          }
        }
        throw create3("Unhandled pattern");
      }
    );
  }
};
var match = (state) => new PatternMatcher(
  /** @type {any} */
  state
);
var _random = (
  /** @type {any} */
  match(
    /** @type {Schema<prng.PRNG>} */
    $any
  ).if($$number, (_o, gen) => int53(gen, MIN_SAFE_INTEGER, MAX_SAFE_INTEGER)).if($$string, (_o, gen) => word(gen)).if($$boolean, (_o, gen) => bool(gen)).if($$bigint, (_o, gen) => BigInt(int53(gen, MIN_SAFE_INTEGER, MAX_SAFE_INTEGER))).if($$union, (o, gen) => random(gen, oneOf(gen, o.shape))).if($$object, (o, gen) => {
    const res = {};
    for (const k in o.shape) {
      let prop = o.shape[k];
      if ($$optional.check(prop)) {
        if (bool(gen)) {
          continue;
        }
        prop = prop.shape;
      }
      res[k] = _random(prop, gen);
    }
    return res;
  }).if($$array, (o, gen) => {
    const arr = [];
    const n = int32(gen, 0, 42);
    for (let i = 0; i < n; i++) {
      arr.push(random(gen, o.shape));
    }
    return arr;
  }).if($$literal, (o, gen) => {
    return oneOf(gen, o.shape);
  }).if($$null, (o, gen) => {
    return null;
  }).if($$lambda, (o, gen) => {
    const res = random(gen, o.res);
    return () => res;
  }).if($$any, (o, gen) => random(gen, oneOf(gen, [
    $number,
    $string,
    $null,
    $undefined,
    $bigint,
    $boolean,
    $array($number),
    $record($union("a", "b", "c"), $number)
  ]))).if($$record, (o, gen) => {
    const res = {};
    const keysN = int53(gen, 0, 3);
    for (let i = 0; i < keysN; i++) {
      const key = random(gen, o.shape.keys);
      const val = random(gen, o.shape.values);
      res[key] = val;
    }
    return res;
  }).done()
);
var random = (gen, schema) => (
  /** @type {any} */
  _random($(schema), gen)
);

// node_modules/lib0/dom.js
var doc = (
  /** @type {Document} */
  typeof document !== "undefined" ? document : {}
);
var $fragment = $custom((el) => el.nodeType === DOCUMENT_FRAGMENT_NODE);
var domParser = (
  /** @type {DOMParser} */
  typeof DOMParser !== "undefined" ? new DOMParser() : null
);
var $element = $custom((el) => el.nodeType === ELEMENT_NODE);
var $text = $custom((el) => el.nodeType === TEXT_NODE);
var mapToStyleString = (m) => map(m, (value, key) => `${key}:${value};`).join("");
var ELEMENT_NODE = doc.ELEMENT_NODE;
var TEXT_NODE = doc.TEXT_NODE;
var CDATA_SECTION_NODE = doc.CDATA_SECTION_NODE;
var COMMENT_NODE = doc.COMMENT_NODE;
var DOCUMENT_NODE = doc.DOCUMENT_NODE;
var DOCUMENT_TYPE_NODE = doc.DOCUMENT_TYPE_NODE;
var DOCUMENT_FRAGMENT_NODE = doc.DOCUMENT_FRAGMENT_NODE;
var $node = $custom((el) => el.nodeType === DOCUMENT_NODE);

// node_modules/lib0/symbol.js
var create6 = Symbol;

// node_modules/lib0/logging.common.js
var BOLD = create6();
var UNBOLD = create6();
var BLUE = create6();
var GREY = create6();
var GREEN = create6();
var RED = create6();
var PURPLE = create6();
var ORANGE = create6();
var UNCOLOR = create6();
var computeNoColorLoggingArgs = (args2) => {
  if (args2.length === 1 && args2[0]?.constructor === Function) {
    args2 = /** @type {Array<string|Symbol|Object|number>} */
    /** @type {[function]} */
    args2[0]();
  }
  const strBuilder = [];
  const logArgs = [];
  let i = 0;
  for (; i < args2.length; i++) {
    const arg = args2[i];
    if (arg === void 0) {
      break;
    } else if (arg.constructor === String || arg.constructor === Number) {
      strBuilder.push(arg);
    } else if (arg.constructor === Object) {
      break;
    }
  }
  if (i > 0) {
    logArgs.push(strBuilder.join(""));
  }
  for (; i < args2.length; i++) {
    const arg = args2[i];
    if (!(arg instanceof Symbol)) {
      logArgs.push(arg);
    }
  }
  return logArgs;
};
var lastLoggingTime = getUnixTime();

// node_modules/lib0/logging.js
var _browserStyleMap = {
  [BOLD]: create5("font-weight", "bold"),
  [UNBOLD]: create5("font-weight", "normal"),
  [BLUE]: create5("color", "blue"),
  [GREEN]: create5("color", "green"),
  [GREY]: create5("color", "grey"),
  [RED]: create5("color", "red"),
  [PURPLE]: create5("color", "purple"),
  [ORANGE]: create5("color", "orange"),
  // not well supported in chrome when debugging node with inspector - TODO: deprecate
  [UNCOLOR]: create5("color", "black")
};
var computeBrowserLoggingArgs = (args2) => {
  if (args2.length === 1 && args2[0]?.constructor === Function) {
    args2 = /** @type {Array<string|Symbol|Object|number>} */
    /** @type {[function]} */
    args2[0]();
  }
  const strBuilder = [];
  const styles = [];
  const currentStyle = create();
  let logArgs = [];
  let i = 0;
  for (; i < args2.length; i++) {
    const arg = args2[i];
    const style = _browserStyleMap[arg];
    if (style !== void 0) {
      currentStyle.set(style.left, style.right);
    } else {
      if (arg === void 0) {
        break;
      }
      if (arg.constructor === String || arg.constructor === Number) {
        const style2 = mapToStyleString(currentStyle);
        if (i > 0 || style2.length > 0) {
          strBuilder.push("%c" + arg);
          styles.push(style2);
        } else {
          strBuilder.push(arg);
        }
      } else {
        break;
      }
    }
  }
  if (i > 0) {
    logArgs = styles;
    logArgs.unshift(strBuilder.join(""));
  }
  for (; i < args2.length; i++) {
    const arg = args2[i];
    if (!(arg instanceof Symbol)) {
      logArgs.push(arg);
    }
  }
  return logArgs;
};
var computeLoggingArgs = supportsColor ? computeBrowserLoggingArgs : computeNoColorLoggingArgs;
var print = (...args2) => {
  console.log(...computeLoggingArgs(args2));
  vconsoles.forEach((vc) => vc.print(args2));
};
var warn = (...args2) => {
  console.warn(...computeLoggingArgs(args2));
  args2.unshift(ORANGE);
  vconsoles.forEach((vc) => vc.print(args2));
};
var vconsoles = create2();

// node_modules/lib0/iterator.js
var createIterator = (next) => ({
  /**
   * @return {IterableIterator<T>}
   */
  [Symbol.iterator]() {
    return this;
  },
  // @ts-ignore
  next
});
var iteratorFilter = (iterator, filter) => createIterator(() => {
  let res;
  do {
    res = iterator.next();
  } while (!res.done && !filter(res.value));
  return res;
});
var iteratorMap = (iterator, fmap) => createIterator(() => {
  const { done, value } = iterator.next();
  return { done, value: done ? void 0 : fmap(value) };
});

// node_modules/yjs/dist/yjs.mjs
var DeleteItem = class {
  /**
   * @param {number} clock
   * @param {number} len
   */
  constructor(clock, len) {
    this.clock = clock;
    this.len = len;
  }
};
var DeleteSet = class {
  constructor() {
    this.clients = /* @__PURE__ */ new Map();
  }
};
var iterateDeletedStructs = (transaction, ds, f2) => ds.clients.forEach((deletes, clientid) => {
  const structs = (
    /** @type {Array<GC|Item>} */
    transaction.doc.store.clients.get(clientid)
  );
  if (structs != null) {
    const lastStruct = structs[structs.length - 1];
    const clockState = lastStruct.id.clock + lastStruct.length;
    for (let i = 0, del2 = deletes[i]; i < deletes.length && del2.clock < clockState; del2 = deletes[++i]) {
      iterateStructs(transaction, structs, del2.clock, del2.len, f2);
    }
  }
});
var findIndexDS = (dis, clock) => {
  let left = 0;
  let right = dis.length - 1;
  while (left <= right) {
    const midindex = floor((left + right) / 2);
    const mid = dis[midindex];
    const midclock = mid.clock;
    if (midclock <= clock) {
      if (clock < midclock + mid.len) {
        return midindex;
      }
      left = midindex + 1;
    } else {
      right = midindex - 1;
    }
  }
  return null;
};
var isDeleted = (ds, id2) => {
  const dis = ds.clients.get(id2.client);
  return dis !== void 0 && findIndexDS(dis, id2.clock) !== null;
};
var sortAndMergeDeleteSet = (ds) => {
  ds.clients.forEach((dels) => {
    dels.sort((a3, b) => a3.clock - b.clock);
    let i, j2;
    for (i = 1, j2 = 1; i < dels.length; i++) {
      const left = dels[j2 - 1];
      const right = dels[i];
      if (left.clock + left.len >= right.clock) {
        dels[j2 - 1] = new DeleteItem(left.clock, max(left.len, right.clock + right.len - left.clock));
      } else {
        if (j2 < i) {
          dels[j2] = right;
        }
        j2++;
      }
    }
    dels.length = j2;
  });
};
var mergeDeleteSets = (dss) => {
  const merged = new DeleteSet();
  for (let dssI = 0; dssI < dss.length; dssI++) {
    dss[dssI].clients.forEach((delsLeft, client) => {
      if (!merged.clients.has(client)) {
        const dels = delsLeft.slice();
        for (let i = dssI + 1; i < dss.length; i++) {
          appendTo(dels, dss[i].clients.get(client) || []);
        }
        merged.clients.set(client, dels);
      }
    });
  }
  sortAndMergeDeleteSet(merged);
  return merged;
};
var addToDeleteSet = (ds, client, clock, length2) => {
  setIfUndefined(ds.clients, client, () => (
    /** @type {Array<DeleteItem>} */
    []
  )).push(new DeleteItem(clock, length2));
};
var createDeleteSet = () => new DeleteSet();
var createDeleteSetFromStructStore = (ss) => {
  const ds = createDeleteSet();
  ss.clients.forEach((structs, client) => {
    const dsitems = [];
    for (let i = 0; i < structs.length; i++) {
      const struct = structs[i];
      if (struct.deleted) {
        const clock = struct.id.clock;
        let len = struct.length;
        if (i + 1 < structs.length) {
          for (let next = structs[i + 1]; i + 1 < structs.length && next.deleted; next = structs[++i + 1]) {
            len += next.length;
          }
        }
        dsitems.push(new DeleteItem(clock, len));
      }
    }
    if (dsitems.length > 0) {
      ds.clients.set(client, dsitems);
    }
  });
  return ds;
};
var writeDeleteSet = (encoder, ds) => {
  writeVarUint(encoder.restEncoder, ds.clients.size);
  from(ds.clients.entries()).sort((a3, b) => b[0] - a3[0]).forEach(([client, dsitems]) => {
    encoder.resetDsCurVal();
    writeVarUint(encoder.restEncoder, client);
    const len = dsitems.length;
    writeVarUint(encoder.restEncoder, len);
    for (let i = 0; i < len; i++) {
      const item = dsitems[i];
      encoder.writeDsClock(item.clock);
      encoder.writeDsLen(item.len);
    }
  });
};
var readDeleteSet = (decoder) => {
  const ds = new DeleteSet();
  const numClients = readVarUint(decoder.restDecoder);
  for (let i = 0; i < numClients; i++) {
    decoder.resetDsCurVal();
    const client = readVarUint(decoder.restDecoder);
    const numberOfDeletes = readVarUint(decoder.restDecoder);
    if (numberOfDeletes > 0) {
      const dsField = setIfUndefined(ds.clients, client, () => (
        /** @type {Array<DeleteItem>} */
        []
      ));
      for (let i2 = 0; i2 < numberOfDeletes; i2++) {
        dsField.push(new DeleteItem(decoder.readDsClock(), decoder.readDsLen()));
      }
    }
  }
  return ds;
};
var readAndApplyDeleteSet = (decoder, transaction, store) => {
  const unappliedDS = new DeleteSet();
  const numClients = readVarUint(decoder.restDecoder);
  for (let i = 0; i < numClients; i++) {
    decoder.resetDsCurVal();
    const client = readVarUint(decoder.restDecoder);
    const numberOfDeletes = readVarUint(decoder.restDecoder);
    const structs = store.clients.get(client) || [];
    const state = getState(store, client);
    for (let i2 = 0; i2 < numberOfDeletes; i2++) {
      const clock = decoder.readDsClock();
      const clockEnd = clock + decoder.readDsLen();
      if (clock < state) {
        if (state < clockEnd) {
          addToDeleteSet(unappliedDS, client, state, clockEnd - state);
        }
        let index = findIndexSS(structs, clock);
        let struct = structs[index];
        if (!struct.deleted && struct.id.clock < clock) {
          structs.splice(index + 1, 0, splitItem(transaction, struct, clock - struct.id.clock));
          index++;
        }
        while (index < structs.length) {
          struct = structs[index++];
          if (struct.id.clock < clockEnd) {
            if (!struct.deleted) {
              if (clockEnd < struct.id.clock + struct.length) {
                structs.splice(index, 0, splitItem(transaction, struct, clockEnd - struct.id.clock));
              }
              struct.delete(transaction);
            }
          } else {
            break;
          }
        }
      } else {
        addToDeleteSet(unappliedDS, client, clock, clockEnd - clock);
      }
    }
  }
  if (unappliedDS.clients.size > 0) {
    const ds = new UpdateEncoderV2();
    writeVarUint(ds.restEncoder, 0);
    writeDeleteSet(ds, unappliedDS);
    return ds.toUint8Array();
  }
  return null;
};
var generateNewClientId = uint32;
var Doc = class _Doc extends ObservableV2 {
  /**
   * @param {DocOpts} opts configuration
   */
  constructor({ guid = uuidv4(), collectionid = null, gc = true, gcFilter = () => true, meta = null, autoLoad = false, shouldLoad = true } = {}) {
    super();
    this.gc = gc;
    this.gcFilter = gcFilter;
    this.clientID = generateNewClientId();
    this.guid = guid;
    this.collectionid = collectionid;
    this.share = /* @__PURE__ */ new Map();
    this.store = new StructStore();
    this._transaction = null;
    this._transactionCleanups = [];
    this.subdocs = /* @__PURE__ */ new Set();
    this._item = null;
    this.shouldLoad = shouldLoad;
    this.autoLoad = autoLoad;
    this.meta = meta;
    this.isLoaded = false;
    this.isSynced = false;
    this.isDestroyed = false;
    this.whenLoaded = create4((resolve) => {
      this.on("load", () => {
        this.isLoaded = true;
        resolve(this);
      });
    });
    const provideSyncedPromise = () => create4((resolve) => {
      const eventHandler = (isSynced) => {
        if (isSynced === void 0 || isSynced === true) {
          this.off("sync", eventHandler);
          resolve();
        }
      };
      this.on("sync", eventHandler);
    });
    this.on("sync", (isSynced) => {
      if (isSynced === false && this.isSynced) {
        this.whenSynced = provideSyncedPromise();
      }
      this.isSynced = isSynced === void 0 || isSynced === true;
      if (this.isSynced && !this.isLoaded) {
        this.emit("load", [this]);
      }
    });
    this.whenSynced = provideSyncedPromise();
  }
  /**
   * Notify the parent document that you request to load data into this subdocument (if it is a subdocument).
   *
   * `load()` might be used in the future to request any provider to load the most current data.
   *
   * It is safe to call `load()` multiple times.
   */
  load() {
    const item = this._item;
    if (item !== null && !this.shouldLoad) {
      transact(
        /** @type {any} */
        item.parent.doc,
        (transaction) => {
          transaction.subdocsLoaded.add(this);
        },
        null,
        true
      );
    }
    this.shouldLoad = true;
  }
  getSubdocs() {
    return this.subdocs;
  }
  getSubdocGuids() {
    return new Set(from(this.subdocs).map((doc2) => doc2.guid));
  }
  /**
   * Changes that happen inside of a transaction are bundled. This means that
   * the observer fires _after_ the transaction is finished and that all changes
   * that happened inside of the transaction are sent as one message to the
   * other peers.
   *
   * @template T
   * @param {function(Transaction):T} f The function that should be executed as a transaction
   * @param {any} [origin] Origin of who started the transaction. Will be stored on transaction.origin
   * @return T
   *
   * @public
   */
  transact(f2, origin = null) {
    return transact(this, f2, origin);
  }
  /**
   * Define a shared data type.
   *
   * Multiple calls of `ydoc.get(name, TypeConstructor)` yield the same result
   * and do not overwrite each other. I.e.
   * `ydoc.get(name, Y.Array) === ydoc.get(name, Y.Array)`
   *
   * After this method is called, the type is also available on `ydoc.share.get(name)`.
   *
   * *Best Practices:*
   * Define all types right after the Y.Doc instance is created and store them in a separate object.
   * Also use the typed methods `getText(name)`, `getArray(name)`, ..
   *
   * @template {typeof AbstractType<any>} Type
   * @example
   *   const ydoc = new Y.Doc(..)
   *   const appState = {
   *     document: ydoc.getText('document')
   *     comments: ydoc.getArray('comments')
   *   }
   *
   * @param {string} name
   * @param {Type} TypeConstructor The constructor of the type definition. E.g. Y.Text, Y.Array, Y.Map, ...
   * @return {InstanceType<Type>} The created type. Constructed with TypeConstructor
   *
   * @public
   */
  get(name, TypeConstructor = (
    /** @type {any} */
    AbstractType
  )) {
    const type = setIfUndefined(this.share, name, () => {
      const t = new TypeConstructor();
      t._integrate(this, null);
      return t;
    });
    const Constr = type.constructor;
    if (TypeConstructor !== AbstractType && Constr !== TypeConstructor) {
      if (Constr === AbstractType) {
        const t = new TypeConstructor();
        t._map = type._map;
        type._map.forEach(
          /** @param {Item?} n */
          (n) => {
            for (; n !== null; n = n.left) {
              n.parent = t;
            }
          }
        );
        t._start = type._start;
        for (let n = t._start; n !== null; n = n.right) {
          n.parent = t;
        }
        t._length = type._length;
        this.share.set(name, t);
        t._integrate(this, null);
        return (
          /** @type {InstanceType<Type>} */
          t
        );
      } else {
        throw new Error(`Type with the name ${name} has already been defined with a different constructor`);
      }
    }
    return (
      /** @type {InstanceType<Type>} */
      type
    );
  }
  /**
   * @template T
   * @param {string} [name]
   * @return {YArray<T>}
   *
   * @public
   */
  getArray(name = "") {
    return (
      /** @type {YArray<T>} */
      this.get(name, YArray)
    );
  }
  /**
   * @param {string} [name]
   * @return {YText}
   *
   * @public
   */
  getText(name = "") {
    return this.get(name, YText);
  }
  /**
   * @template T
   * @param {string} [name]
   * @return {YMap<T>}
   *
   * @public
   */
  getMap(name = "") {
    return (
      /** @type {YMap<T>} */
      this.get(name, YMap)
    );
  }
  /**
   * @param {string} [name]
   * @return {YXmlElement}
   *
   * @public
   */
  getXmlElement(name = "") {
    return (
      /** @type {YXmlElement<{[key:string]:string}>} */
      this.get(name, YXmlElement)
    );
  }
  /**
   * @param {string} [name]
   * @return {YXmlFragment}
   *
   * @public
   */
  getXmlFragment(name = "") {
    return this.get(name, YXmlFragment);
  }
  /**
   * Converts the entire document into a js object, recursively traversing each yjs type
   * Doesn't log types that have not been defined (using ydoc.getType(..)).
   *
   * @deprecated Do not use this method and rather call toJSON directly on the shared types.
   *
   * @return {Object<string, any>}
   */
  toJSON() {
    const doc2 = {};
    this.share.forEach((value, key) => {
      doc2[key] = value.toJSON();
    });
    return doc2;
  }
  /**
   * Emit `destroy` event and unregister all event handlers.
   */
  destroy() {
    this.isDestroyed = true;
    from(this.subdocs).forEach((subdoc) => subdoc.destroy());
    const item = this._item;
    if (item !== null) {
      this._item = null;
      const content = (
        /** @type {ContentDoc} */
        item.content
      );
      content.doc = new _Doc({ guid: this.guid, ...content.opts, shouldLoad: false });
      content.doc._item = item;
      transact(
        /** @type {any} */
        item.parent.doc,
        (transaction) => {
          const doc2 = content.doc;
          if (!item.deleted) {
            transaction.subdocsAdded.add(doc2);
          }
          transaction.subdocsRemoved.add(this);
        },
        null,
        true
      );
    }
    this.emit("destroyed", [true]);
    this.emit("destroy", [this]);
    super.destroy();
  }
};
var DSDecoderV1 = class {
  /**
   * @param {decoding.Decoder} decoder
   */
  constructor(decoder) {
    this.restDecoder = decoder;
  }
  resetDsCurVal() {
  }
  /**
   * @return {number}
   */
  readDsClock() {
    return readVarUint(this.restDecoder);
  }
  /**
   * @return {number}
   */
  readDsLen() {
    return readVarUint(this.restDecoder);
  }
};
var UpdateDecoderV1 = class extends DSDecoderV1 {
  /**
   * @return {ID}
   */
  readLeftID() {
    return createID(readVarUint(this.restDecoder), readVarUint(this.restDecoder));
  }
  /**
   * @return {ID}
   */
  readRightID() {
    return createID(readVarUint(this.restDecoder), readVarUint(this.restDecoder));
  }
  /**
   * Read the next client id.
   * Use this in favor of readID whenever possible to reduce the number of objects created.
   */
  readClient() {
    return readVarUint(this.restDecoder);
  }
  /**
   * @return {number} info An unsigned 8-bit integer
   */
  readInfo() {
    return readUint8(this.restDecoder);
  }
  /**
   * @return {string}
   */
  readString() {
    return readVarString(this.restDecoder);
  }
  /**
   * @return {boolean} isKey
   */
  readParentInfo() {
    return readVarUint(this.restDecoder) === 1;
  }
  /**
   * @return {number} info An unsigned 8-bit integer
   */
  readTypeRef() {
    return readVarUint(this.restDecoder);
  }
  /**
   * Write len of a struct - well suited for Opt RLE encoder.
   *
   * @return {number} len
   */
  readLen() {
    return readVarUint(this.restDecoder);
  }
  /**
   * @return {any}
   */
  readAny() {
    return readAny(this.restDecoder);
  }
  /**
   * @return {Uint8Array}
   */
  readBuf() {
    return copyUint8Array(readVarUint8Array(this.restDecoder));
  }
  /**
   * Legacy implementation uses JSON parse. We use any-decoding in v2.
   *
   * @return {any}
   */
  readJSON() {
    return JSON.parse(readVarString(this.restDecoder));
  }
  /**
   * @return {string}
   */
  readKey() {
    return readVarString(this.restDecoder);
  }
};
var DSDecoderV2 = class {
  /**
   * @param {decoding.Decoder} decoder
   */
  constructor(decoder) {
    this.dsCurrVal = 0;
    this.restDecoder = decoder;
  }
  resetDsCurVal() {
    this.dsCurrVal = 0;
  }
  /**
   * @return {number}
   */
  readDsClock() {
    this.dsCurrVal += readVarUint(this.restDecoder);
    return this.dsCurrVal;
  }
  /**
   * @return {number}
   */
  readDsLen() {
    const diff = readVarUint(this.restDecoder) + 1;
    this.dsCurrVal += diff;
    return diff;
  }
};
var UpdateDecoderV2 = class extends DSDecoderV2 {
  /**
   * @param {decoding.Decoder} decoder
   */
  constructor(decoder) {
    super(decoder);
    this.keys = [];
    readVarUint(decoder);
    this.keyClockDecoder = new IntDiffOptRleDecoder(readVarUint8Array(decoder));
    this.clientDecoder = new UintOptRleDecoder(readVarUint8Array(decoder));
    this.leftClockDecoder = new IntDiffOptRleDecoder(readVarUint8Array(decoder));
    this.rightClockDecoder = new IntDiffOptRleDecoder(readVarUint8Array(decoder));
    this.infoDecoder = new RleDecoder(readVarUint8Array(decoder), readUint8);
    this.stringDecoder = new StringDecoder(readVarUint8Array(decoder));
    this.parentInfoDecoder = new RleDecoder(readVarUint8Array(decoder), readUint8);
    this.typeRefDecoder = new UintOptRleDecoder(readVarUint8Array(decoder));
    this.lenDecoder = new UintOptRleDecoder(readVarUint8Array(decoder));
  }
  /**
   * @return {ID}
   */
  readLeftID() {
    return new ID(this.clientDecoder.read(), this.leftClockDecoder.read());
  }
  /**
   * @return {ID}
   */
  readRightID() {
    return new ID(this.clientDecoder.read(), this.rightClockDecoder.read());
  }
  /**
   * Read the next client id.
   * Use this in favor of readID whenever possible to reduce the number of objects created.
   */
  readClient() {
    return this.clientDecoder.read();
  }
  /**
   * @return {number} info An unsigned 8-bit integer
   */
  readInfo() {
    return (
      /** @type {number} */
      this.infoDecoder.read()
    );
  }
  /**
   * @return {string}
   */
  readString() {
    return this.stringDecoder.read();
  }
  /**
   * @return {boolean}
   */
  readParentInfo() {
    return this.parentInfoDecoder.read() === 1;
  }
  /**
   * @return {number} An unsigned 8-bit integer
   */
  readTypeRef() {
    return this.typeRefDecoder.read();
  }
  /**
   * Write len of a struct - well suited for Opt RLE encoder.
   *
   * @return {number}
   */
  readLen() {
    return this.lenDecoder.read();
  }
  /**
   * @return {any}
   */
  readAny() {
    return readAny(this.restDecoder);
  }
  /**
   * @return {Uint8Array}
   */
  readBuf() {
    return readVarUint8Array(this.restDecoder);
  }
  /**
   * This is mainly here for legacy purposes.
   *
   * Initial we incoded objects using JSON. Now we use the much faster lib0/any-encoder. This method mainly exists for legacy purposes for the v1 encoder.
   *
   * @return {any}
   */
  readJSON() {
    return readAny(this.restDecoder);
  }
  /**
   * @return {string}
   */
  readKey() {
    const keyClock = this.keyClockDecoder.read();
    if (keyClock < this.keys.length) {
      return this.keys[keyClock];
    } else {
      const key = this.stringDecoder.read();
      this.keys.push(key);
      return key;
    }
  }
};
var DSEncoderV1 = class {
  constructor() {
    this.restEncoder = createEncoder();
  }
  toUint8Array() {
    return toUint8Array(this.restEncoder);
  }
  resetDsCurVal() {
  }
  /**
   * @param {number} clock
   */
  writeDsClock(clock) {
    writeVarUint(this.restEncoder, clock);
  }
  /**
   * @param {number} len
   */
  writeDsLen(len) {
    writeVarUint(this.restEncoder, len);
  }
};
var UpdateEncoderV1 = class extends DSEncoderV1 {
  /**
   * @param {ID} id
   */
  writeLeftID(id2) {
    writeVarUint(this.restEncoder, id2.client);
    writeVarUint(this.restEncoder, id2.clock);
  }
  /**
   * @param {ID} id
   */
  writeRightID(id2) {
    writeVarUint(this.restEncoder, id2.client);
    writeVarUint(this.restEncoder, id2.clock);
  }
  /**
   * Use writeClient and writeClock instead of writeID if possible.
   * @param {number} client
   */
  writeClient(client) {
    writeVarUint(this.restEncoder, client);
  }
  /**
   * @param {number} info An unsigned 8-bit integer
   */
  writeInfo(info) {
    writeUint8(this.restEncoder, info);
  }
  /**
   * @param {string} s
   */
  writeString(s) {
    writeVarString(this.restEncoder, s);
  }
  /**
   * @param {boolean} isYKey
   */
  writeParentInfo(isYKey) {
    writeVarUint(this.restEncoder, isYKey ? 1 : 0);
  }
  /**
   * @param {number} info An unsigned 8-bit integer
   */
  writeTypeRef(info) {
    writeVarUint(this.restEncoder, info);
  }
  /**
   * Write len of a struct - well suited for Opt RLE encoder.
   *
   * @param {number} len
   */
  writeLen(len) {
    writeVarUint(this.restEncoder, len);
  }
  /**
   * @param {any} any
   */
  writeAny(any2) {
    writeAny(this.restEncoder, any2);
  }
  /**
   * @param {Uint8Array} buf
   */
  writeBuf(buf) {
    writeVarUint8Array(this.restEncoder, buf);
  }
  /**
   * @param {any} embed
   */
  writeJSON(embed) {
    writeVarString(this.restEncoder, JSON.stringify(embed));
  }
  /**
   * @param {string} key
   */
  writeKey(key) {
    writeVarString(this.restEncoder, key);
  }
};
var DSEncoderV2 = class {
  constructor() {
    this.restEncoder = createEncoder();
    this.dsCurrVal = 0;
  }
  toUint8Array() {
    return toUint8Array(this.restEncoder);
  }
  resetDsCurVal() {
    this.dsCurrVal = 0;
  }
  /**
   * @param {number} clock
   */
  writeDsClock(clock) {
    const diff = clock - this.dsCurrVal;
    this.dsCurrVal = clock;
    writeVarUint(this.restEncoder, diff);
  }
  /**
   * @param {number} len
   */
  writeDsLen(len) {
    if (len === 0) {
      unexpectedCase();
    }
    writeVarUint(this.restEncoder, len - 1);
    this.dsCurrVal += len;
  }
};
var UpdateEncoderV2 = class extends DSEncoderV2 {
  constructor() {
    super();
    this.keyMap = /* @__PURE__ */ new Map();
    this.keyClock = 0;
    this.keyClockEncoder = new IntDiffOptRleEncoder();
    this.clientEncoder = new UintOptRleEncoder();
    this.leftClockEncoder = new IntDiffOptRleEncoder();
    this.rightClockEncoder = new IntDiffOptRleEncoder();
    this.infoEncoder = new RleEncoder(writeUint8);
    this.stringEncoder = new StringEncoder();
    this.parentInfoEncoder = new RleEncoder(writeUint8);
    this.typeRefEncoder = new UintOptRleEncoder();
    this.lenEncoder = new UintOptRleEncoder();
  }
  toUint8Array() {
    const encoder = createEncoder();
    writeVarUint(encoder, 0);
    writeVarUint8Array(encoder, this.keyClockEncoder.toUint8Array());
    writeVarUint8Array(encoder, this.clientEncoder.toUint8Array());
    writeVarUint8Array(encoder, this.leftClockEncoder.toUint8Array());
    writeVarUint8Array(encoder, this.rightClockEncoder.toUint8Array());
    writeVarUint8Array(encoder, toUint8Array(this.infoEncoder));
    writeVarUint8Array(encoder, this.stringEncoder.toUint8Array());
    writeVarUint8Array(encoder, toUint8Array(this.parentInfoEncoder));
    writeVarUint8Array(encoder, this.typeRefEncoder.toUint8Array());
    writeVarUint8Array(encoder, this.lenEncoder.toUint8Array());
    writeUint8Array(encoder, toUint8Array(this.restEncoder));
    return toUint8Array(encoder);
  }
  /**
   * @param {ID} id
   */
  writeLeftID(id2) {
    this.clientEncoder.write(id2.client);
    this.leftClockEncoder.write(id2.clock);
  }
  /**
   * @param {ID} id
   */
  writeRightID(id2) {
    this.clientEncoder.write(id2.client);
    this.rightClockEncoder.write(id2.clock);
  }
  /**
   * @param {number} client
   */
  writeClient(client) {
    this.clientEncoder.write(client);
  }
  /**
   * @param {number} info An unsigned 8-bit integer
   */
  writeInfo(info) {
    this.infoEncoder.write(info);
  }
  /**
   * @param {string} s
   */
  writeString(s) {
    this.stringEncoder.write(s);
  }
  /**
   * @param {boolean} isYKey
   */
  writeParentInfo(isYKey) {
    this.parentInfoEncoder.write(isYKey ? 1 : 0);
  }
  /**
   * @param {number} info An unsigned 8-bit integer
   */
  writeTypeRef(info) {
    this.typeRefEncoder.write(info);
  }
  /**
   * Write len of a struct - well suited for Opt RLE encoder.
   *
   * @param {number} len
   */
  writeLen(len) {
    this.lenEncoder.write(len);
  }
  /**
   * @param {any} any
   */
  writeAny(any2) {
    writeAny(this.restEncoder, any2);
  }
  /**
   * @param {Uint8Array} buf
   */
  writeBuf(buf) {
    writeVarUint8Array(this.restEncoder, buf);
  }
  /**
   * This is mainly here for legacy purposes.
   *
   * Initial we incoded objects using JSON. Now we use the much faster lib0/any-encoder. This method mainly exists for legacy purposes for the v1 encoder.
   *
   * @param {any} embed
   */
  writeJSON(embed) {
    writeAny(this.restEncoder, embed);
  }
  /**
   * Property keys are often reused. For example, in y-prosemirror the key `bold` might
   * occur very often. For a 3d application, the key `position` might occur very often.
   *
   * We cache these keys in a Map and refer to them via a unique number.
   *
   * @param {string} key
   */
  writeKey(key) {
    const clock = this.keyMap.get(key);
    if (clock === void 0) {
      this.keyClockEncoder.write(this.keyClock++);
      this.stringEncoder.write(key);
    } else {
      this.keyClockEncoder.write(clock);
    }
  }
};
var writeStructs = (encoder, structs, client, clock) => {
  clock = max(clock, structs[0].id.clock);
  const startNewStructs = findIndexSS(structs, clock);
  writeVarUint(encoder.restEncoder, structs.length - startNewStructs);
  encoder.writeClient(client);
  writeVarUint(encoder.restEncoder, clock);
  const firstStruct = structs[startNewStructs];
  firstStruct.write(encoder, clock - firstStruct.id.clock);
  for (let i = startNewStructs + 1; i < structs.length; i++) {
    structs[i].write(encoder, 0);
  }
};
var writeClientsStructs = (encoder, store, _sm) => {
  const sm = /* @__PURE__ */ new Map();
  _sm.forEach((clock, client) => {
    if (getState(store, client) > clock) {
      sm.set(client, clock);
    }
  });
  getStateVector(store).forEach((_clock, client) => {
    if (!_sm.has(client)) {
      sm.set(client, 0);
    }
  });
  writeVarUint(encoder.restEncoder, sm.size);
  from(sm.entries()).sort((a3, b) => b[0] - a3[0]).forEach(([client, clock]) => {
    writeStructs(
      encoder,
      /** @type {Array<GC|Item>} */
      store.clients.get(client),
      client,
      clock
    );
  });
};
var readClientsStructRefs = (decoder, doc2) => {
  const clientRefs = create();
  const numOfStateUpdates = readVarUint(decoder.restDecoder);
  for (let i = 0; i < numOfStateUpdates; i++) {
    const numberOfStructs = readVarUint(decoder.restDecoder);
    const refs = new Array(numberOfStructs);
    const client = decoder.readClient();
    let clock = readVarUint(decoder.restDecoder);
    clientRefs.set(client, { i: 0, refs });
    for (let i2 = 0; i2 < numberOfStructs; i2++) {
      const info = decoder.readInfo();
      switch (BITS5 & info) {
        case 0: {
          const len = decoder.readLen();
          refs[i2] = new GC(createID(client, clock), len);
          clock += len;
          break;
        }
        case 10: {
          const len = readVarUint(decoder.restDecoder);
          refs[i2] = new Skip(createID(client, clock), len);
          clock += len;
          break;
        }
        default: {
          const cantCopyParentInfo = (info & (BIT7 | BIT8)) === 0;
          const struct = new Item(
            createID(client, clock),
            null,
            // left
            (info & BIT8) === BIT8 ? decoder.readLeftID() : null,
            // origin
            null,
            // right
            (info & BIT7) === BIT7 ? decoder.readRightID() : null,
            // right origin
            cantCopyParentInfo ? decoder.readParentInfo() ? doc2.get(decoder.readString()) : decoder.readLeftID() : null,
            // parent
            cantCopyParentInfo && (info & BIT6) === BIT6 ? decoder.readString() : null,
            // parentSub
            readItemContent(decoder, info)
            // item content
          );
          refs[i2] = struct;
          clock += struct.length;
        }
      }
    }
  }
  return clientRefs;
};
var integrateStructs = (transaction, store, clientsStructRefs) => {
  const stack = [];
  let clientsStructRefsIds = from(clientsStructRefs.keys()).sort((a3, b) => a3 - b);
  if (clientsStructRefsIds.length === 0) {
    return null;
  }
  const getNextStructTarget = () => {
    if (clientsStructRefsIds.length === 0) {
      return null;
    }
    let nextStructsTarget = (
      /** @type {{i:number,refs:Array<GC|Item>}} */
      clientsStructRefs.get(clientsStructRefsIds[clientsStructRefsIds.length - 1])
    );
    while (nextStructsTarget.refs.length === nextStructsTarget.i) {
      clientsStructRefsIds.pop();
      if (clientsStructRefsIds.length > 0) {
        nextStructsTarget = /** @type {{i:number,refs:Array<GC|Item>}} */
        clientsStructRefs.get(clientsStructRefsIds[clientsStructRefsIds.length - 1]);
      } else {
        return null;
      }
    }
    return nextStructsTarget;
  };
  let curStructsTarget = getNextStructTarget();
  if (curStructsTarget === null) {
    return null;
  }
  const restStructs = new StructStore();
  const missingSV = /* @__PURE__ */ new Map();
  const updateMissingSv = (client, clock) => {
    const mclock = missingSV.get(client);
    if (mclock == null || mclock > clock) {
      missingSV.set(client, clock);
    }
  };
  let stackHead = (
    /** @type {any} */
    curStructsTarget.refs[
      /** @type {any} */
      curStructsTarget.i++
    ]
  );
  const state = /* @__PURE__ */ new Map();
  const addStackToRestSS = () => {
    for (const item of stack) {
      const client = item.id.client;
      const inapplicableItems = clientsStructRefs.get(client);
      if (inapplicableItems) {
        inapplicableItems.i--;
        restStructs.clients.set(client, inapplicableItems.refs.slice(inapplicableItems.i));
        clientsStructRefs.delete(client);
        inapplicableItems.i = 0;
        inapplicableItems.refs = [];
      } else {
        restStructs.clients.set(client, [item]);
      }
      clientsStructRefsIds = clientsStructRefsIds.filter((c) => c !== client);
    }
    stack.length = 0;
  };
  while (true) {
    if (stackHead.constructor !== Skip) {
      const localClock = setIfUndefined(state, stackHead.id.client, () => getState(store, stackHead.id.client));
      const offset = localClock - stackHead.id.clock;
      if (offset < 0) {
        stack.push(stackHead);
        updateMissingSv(stackHead.id.client, stackHead.id.clock - 1);
        addStackToRestSS();
      } else {
        const missing = stackHead.getMissing(transaction, store);
        if (missing !== null) {
          stack.push(stackHead);
          const structRefs = clientsStructRefs.get(
            /** @type {number} */
            missing
          ) || { refs: [], i: 0 };
          if (structRefs.refs.length === structRefs.i) {
            updateMissingSv(
              /** @type {number} */
              missing,
              getState(store, missing)
            );
            addStackToRestSS();
          } else {
            stackHead = structRefs.refs[structRefs.i++];
            continue;
          }
        } else if (offset === 0 || offset < stackHead.length) {
          stackHead.integrate(transaction, offset);
          state.set(stackHead.id.client, stackHead.id.clock + stackHead.length);
        }
      }
    }
    if (stack.length > 0) {
      stackHead = /** @type {GC|Item} */
      stack.pop();
    } else if (curStructsTarget !== null && curStructsTarget.i < curStructsTarget.refs.length) {
      stackHead = /** @type {GC|Item} */
      curStructsTarget.refs[curStructsTarget.i++];
    } else {
      curStructsTarget = getNextStructTarget();
      if (curStructsTarget === null) {
        break;
      } else {
        stackHead = /** @type {GC|Item} */
        curStructsTarget.refs[curStructsTarget.i++];
      }
    }
  }
  if (restStructs.clients.size > 0) {
    const encoder = new UpdateEncoderV2();
    writeClientsStructs(encoder, restStructs, /* @__PURE__ */ new Map());
    writeVarUint(encoder.restEncoder, 0);
    return { missing: missingSV, update: encoder.toUint8Array() };
  }
  return null;
};
var writeStructsFromTransaction = (encoder, transaction) => writeClientsStructs(encoder, transaction.doc.store, transaction.beforeState);
var readUpdateV2 = (decoder, ydoc, transactionOrigin, structDecoder = new UpdateDecoderV2(decoder)) => transact(ydoc, (transaction) => {
  transaction.local = false;
  let retry = false;
  const doc2 = transaction.doc;
  const store = doc2.store;
  const ss = readClientsStructRefs(structDecoder, doc2);
  const restStructs = integrateStructs(transaction, store, ss);
  const pending = store.pendingStructs;
  if (pending) {
    for (const [client, clock] of pending.missing) {
      if (clock < getState(store, client)) {
        retry = true;
        break;
      }
    }
    if (restStructs) {
      for (const [client, clock] of restStructs.missing) {
        const mclock = pending.missing.get(client);
        if (mclock == null || mclock > clock) {
          pending.missing.set(client, clock);
        }
      }
      pending.update = mergeUpdatesV2([pending.update, restStructs.update]);
    }
  } else {
    store.pendingStructs = restStructs;
  }
  const dsRest = readAndApplyDeleteSet(structDecoder, transaction, store);
  if (store.pendingDs) {
    const pendingDSUpdate = new UpdateDecoderV2(createDecoder(store.pendingDs));
    readVarUint(pendingDSUpdate.restDecoder);
    const dsRest2 = readAndApplyDeleteSet(pendingDSUpdate, transaction, store);
    if (dsRest && dsRest2) {
      store.pendingDs = mergeUpdatesV2([dsRest, dsRest2]);
    } else {
      store.pendingDs = dsRest || dsRest2;
    }
  } else {
    store.pendingDs = dsRest;
  }
  if (retry) {
    const update = (
      /** @type {{update: Uint8Array}} */
      store.pendingStructs.update
    );
    store.pendingStructs = null;
    applyUpdateV2(transaction.doc, update);
  }
}, transactionOrigin, false);
var applyUpdateV2 = (ydoc, update, transactionOrigin, YDecoder = UpdateDecoderV2) => {
  const decoder = createDecoder(update);
  readUpdateV2(decoder, ydoc, transactionOrigin, new YDecoder(decoder));
};
var applyUpdate = (ydoc, update, transactionOrigin) => applyUpdateV2(ydoc, update, transactionOrigin, UpdateDecoderV1);
var writeStateAsUpdate = (encoder, doc2, targetStateVector = /* @__PURE__ */ new Map()) => {
  writeClientsStructs(encoder, doc2.store, targetStateVector);
  writeDeleteSet(encoder, createDeleteSetFromStructStore(doc2.store));
};
var encodeStateAsUpdateV2 = (doc2, encodedTargetStateVector = new Uint8Array([0]), encoder = new UpdateEncoderV2()) => {
  const targetStateVector = decodeStateVector(encodedTargetStateVector);
  writeStateAsUpdate(encoder, doc2, targetStateVector);
  const updates = [encoder.toUint8Array()];
  if (doc2.store.pendingDs) {
    updates.push(doc2.store.pendingDs);
  }
  if (doc2.store.pendingStructs) {
    updates.push(diffUpdateV2(doc2.store.pendingStructs.update, encodedTargetStateVector));
  }
  if (updates.length > 1) {
    if (encoder.constructor === UpdateEncoderV1) {
      return mergeUpdates(updates.map((update, i) => i === 0 ? update : convertUpdateFormatV2ToV1(update)));
    } else if (encoder.constructor === UpdateEncoderV2) {
      return mergeUpdatesV2(updates);
    }
  }
  return updates[0];
};
var encodeStateAsUpdate = (doc2, encodedTargetStateVector) => encodeStateAsUpdateV2(doc2, encodedTargetStateVector, new UpdateEncoderV1());
var readStateVector = (decoder) => {
  const ss = /* @__PURE__ */ new Map();
  const ssLength = readVarUint(decoder.restDecoder);
  for (let i = 0; i < ssLength; i++) {
    const client = readVarUint(decoder.restDecoder);
    const clock = readVarUint(decoder.restDecoder);
    ss.set(client, clock);
  }
  return ss;
};
var decodeStateVector = (decodedState) => readStateVector(new DSDecoderV1(createDecoder(decodedState)));
var writeStateVector = (encoder, sv) => {
  writeVarUint(encoder.restEncoder, sv.size);
  from(sv.entries()).sort((a3, b) => b[0] - a3[0]).forEach(([client, clock]) => {
    writeVarUint(encoder.restEncoder, client);
    writeVarUint(encoder.restEncoder, clock);
  });
  return encoder;
};
var writeDocumentStateVector = (encoder, doc2) => writeStateVector(encoder, getStateVector(doc2.store));
var encodeStateVectorV2 = (doc2, encoder = new DSEncoderV2()) => {
  if (doc2 instanceof Map) {
    writeStateVector(encoder, doc2);
  } else {
    writeDocumentStateVector(encoder, doc2);
  }
  return encoder.toUint8Array();
};
var encodeStateVector = (doc2) => encodeStateVectorV2(doc2, new DSEncoderV1());
var EventHandler = class {
  constructor() {
    this.l = [];
  }
};
var createEventHandler = () => new EventHandler();
var addEventHandlerListener = (eventHandler, f2) => eventHandler.l.push(f2);
var removeEventHandlerListener = (eventHandler, f2) => {
  const l = eventHandler.l;
  const len = l.length;
  eventHandler.l = l.filter((g) => f2 !== g);
  if (len === eventHandler.l.length) {
    console.error("[yjs] Tried to remove event handler that doesn't exist.");
  }
};
var callEventHandlerListeners = (eventHandler, arg0, arg1) => callAll(eventHandler.l, [arg0, arg1]);
var ID = class {
  /**
   * @param {number} client client id
   * @param {number} clock unique per client id, continuous number
   */
  constructor(client, clock) {
    this.client = client;
    this.clock = clock;
  }
};
var compareIDs = (a3, b) => a3 === b || a3 !== null && b !== null && a3.client === b.client && a3.clock === b.clock;
var createID = (client, clock) => new ID(client, clock);
var findRootTypeKey = (type) => {
  for (const [key, value] of type.doc.share.entries()) {
    if (value === type) {
      return key;
    }
  }
  throw unexpectedCase();
};
var isParentOf = (parent, child) => {
  while (child !== null) {
    if (child.parent === parent) {
      return true;
    }
    child = /** @type {AbstractType<any>} */
    child.parent._item;
  }
  return false;
};
var Snapshot = class {
  /**
   * @param {DeleteSet} ds
   * @param {Map<number,number>} sv state map
   */
  constructor(ds, sv) {
    this.ds = ds;
    this.sv = sv;
  }
};
var createSnapshot = (ds, sm) => new Snapshot(ds, sm);
var emptySnapshot = createSnapshot(createDeleteSet(), /* @__PURE__ */ new Map());
var isVisible = (item, snapshot) => snapshot === void 0 ? !item.deleted : snapshot.sv.has(item.id.client) && (snapshot.sv.get(item.id.client) || 0) > item.id.clock && !isDeleted(snapshot.ds, item.id);
var splitSnapshotAffectedStructs = (transaction, snapshot) => {
  const meta = setIfUndefined(transaction.meta, splitSnapshotAffectedStructs, create2);
  const store = transaction.doc.store;
  if (!meta.has(snapshot)) {
    snapshot.sv.forEach((clock, client) => {
      if (clock < getState(store, client)) {
        getItemCleanStart(transaction, createID(client, clock));
      }
    });
    iterateDeletedStructs(transaction, snapshot.ds, (_item) => {
    });
    meta.add(snapshot);
  }
};
var StructStore = class {
  constructor() {
    this.clients = /* @__PURE__ */ new Map();
    this.pendingStructs = null;
    this.pendingDs = null;
  }
};
var getStateVector = (store) => {
  const sm = /* @__PURE__ */ new Map();
  store.clients.forEach((structs, client) => {
    const struct = structs[structs.length - 1];
    sm.set(client, struct.id.clock + struct.length);
  });
  return sm;
};
var getState = (store, client) => {
  const structs = store.clients.get(client);
  if (structs === void 0) {
    return 0;
  }
  const lastStruct = structs[structs.length - 1];
  return lastStruct.id.clock + lastStruct.length;
};
var addStruct = (store, struct) => {
  let structs = store.clients.get(struct.id.client);
  if (structs === void 0) {
    structs = [];
    store.clients.set(struct.id.client, structs);
  } else {
    const lastStruct = structs[structs.length - 1];
    if (lastStruct.id.clock + lastStruct.length !== struct.id.clock) {
      throw unexpectedCase();
    }
  }
  structs.push(struct);
};
var findIndexSS = (structs, clock) => {
  let left = 0;
  let right = structs.length - 1;
  let mid = structs[right];
  let midclock = mid.id.clock;
  if (midclock === clock) {
    return right;
  }
  let midindex = floor(clock / (midclock + mid.length - 1) * right);
  while (left <= right) {
    mid = structs[midindex];
    midclock = mid.id.clock;
    if (midclock <= clock) {
      if (clock < midclock + mid.length) {
        return midindex;
      }
      left = midindex + 1;
    } else {
      right = midindex - 1;
    }
    midindex = floor((left + right) / 2);
  }
  throw unexpectedCase();
};
var find = (store, id2) => {
  const structs = store.clients.get(id2.client);
  return structs[findIndexSS(structs, id2.clock)];
};
var getItem = (
  /** @type {function(StructStore,ID):Item} */
  find
);
var findIndexCleanStart = (transaction, structs, clock) => {
  const index = findIndexSS(structs, clock);
  const struct = structs[index];
  if (struct.id.clock < clock && struct instanceof Item) {
    structs.splice(index + 1, 0, splitItem(transaction, struct, clock - struct.id.clock));
    return index + 1;
  }
  return index;
};
var getItemCleanStart = (transaction, id2) => {
  const structs = (
    /** @type {Array<Item>} */
    transaction.doc.store.clients.get(id2.client)
  );
  return structs[findIndexCleanStart(transaction, structs, id2.clock)];
};
var getItemCleanEnd = (transaction, store, id2) => {
  const structs = store.clients.get(id2.client);
  const index = findIndexSS(structs, id2.clock);
  const struct = structs[index];
  if (id2.clock !== struct.id.clock + struct.length - 1 && struct.constructor !== GC) {
    structs.splice(index + 1, 0, splitItem(transaction, struct, id2.clock - struct.id.clock + 1));
  }
  return struct;
};
var replaceStruct = (store, struct, newStruct) => {
  const structs = (
    /** @type {Array<GC|Item>} */
    store.clients.get(struct.id.client)
  );
  structs[findIndexSS(structs, struct.id.clock)] = newStruct;
};
var iterateStructs = (transaction, structs, clockStart, len, f2) => {
  if (len === 0) {
    return;
  }
  const clockEnd = clockStart + len;
  let index = findIndexCleanStart(transaction, structs, clockStart);
  let struct;
  do {
    struct = structs[index++];
    if (clockEnd < struct.id.clock + struct.length) {
      findIndexCleanStart(transaction, structs, clockEnd);
    }
    f2(struct);
  } while (index < structs.length && structs[index].id.clock < clockEnd);
};
var Transaction = class {
  /**
   * @param {Doc} doc
   * @param {any} origin
   * @param {boolean} local
   */
  constructor(doc2, origin, local) {
    this.doc = doc2;
    this.deleteSet = new DeleteSet();
    this.beforeState = getStateVector(doc2.store);
    this.afterState = /* @__PURE__ */ new Map();
    this.changed = /* @__PURE__ */ new Map();
    this.changedParentTypes = /* @__PURE__ */ new Map();
    this._mergeStructs = [];
    this.origin = origin;
    this.meta = /* @__PURE__ */ new Map();
    this.local = local;
    this.subdocsAdded = /* @__PURE__ */ new Set();
    this.subdocsRemoved = /* @__PURE__ */ new Set();
    this.subdocsLoaded = /* @__PURE__ */ new Set();
    this._needFormattingCleanup = false;
  }
};
var writeUpdateMessageFromTransaction = (encoder, transaction) => {
  if (transaction.deleteSet.clients.size === 0 && !any(transaction.afterState, (clock, client) => transaction.beforeState.get(client) !== clock)) {
    return false;
  }
  sortAndMergeDeleteSet(transaction.deleteSet);
  writeStructsFromTransaction(encoder, transaction);
  writeDeleteSet(encoder, transaction.deleteSet);
  return true;
};
var addChangedTypeToTransaction = (transaction, type, parentSub) => {
  const item = type._item;
  if (item === null || item.id.clock < (transaction.beforeState.get(item.id.client) || 0) && !item.deleted) {
    setIfUndefined(transaction.changed, type, create2).add(parentSub);
  }
};
var tryToMergeWithLefts = (structs, pos) => {
  let right = structs[pos];
  let left = structs[pos - 1];
  let i = pos;
  for (; i > 0; right = left, left = structs[--i - 1]) {
    if (left.deleted === right.deleted && left.constructor === right.constructor) {
      if (left.mergeWith(right)) {
        if (right instanceof Item && right.parentSub !== null && /** @type {AbstractType<any>} */
        right.parent._map.get(right.parentSub) === right) {
          right.parent._map.set(
            right.parentSub,
            /** @type {Item} */
            left
          );
        }
        continue;
      }
    }
    break;
  }
  const merged = pos - i;
  if (merged) {
    structs.splice(pos + 1 - merged, merged);
  }
  return merged;
};
var tryGcDeleteSet = (ds, store, gcFilter) => {
  for (const [client, deleteItems] of ds.clients.entries()) {
    const structs = (
      /** @type {Array<GC|Item>} */
      store.clients.get(client)
    );
    for (let di = deleteItems.length - 1; di >= 0; di--) {
      const deleteItem = deleteItems[di];
      const endDeleteItemClock = deleteItem.clock + deleteItem.len;
      for (let si = findIndexSS(structs, deleteItem.clock), struct = structs[si]; si < structs.length && struct.id.clock < endDeleteItemClock; struct = structs[++si]) {
        const struct2 = structs[si];
        if (deleteItem.clock + deleteItem.len <= struct2.id.clock) {
          break;
        }
        if (struct2 instanceof Item && struct2.deleted && !struct2.keep && gcFilter(struct2)) {
          struct2.gc(store, false);
        }
      }
    }
  }
};
var tryMergeDeleteSet = (ds, store) => {
  ds.clients.forEach((deleteItems, client) => {
    const structs = (
      /** @type {Array<GC|Item>} */
      store.clients.get(client)
    );
    for (let di = deleteItems.length - 1; di >= 0; di--) {
      const deleteItem = deleteItems[di];
      const mostRightIndexToCheck = min(structs.length - 1, 1 + findIndexSS(structs, deleteItem.clock + deleteItem.len - 1));
      for (let si = mostRightIndexToCheck, struct = structs[si]; si > 0 && struct.id.clock >= deleteItem.clock; struct = structs[si]) {
        si -= 1 + tryToMergeWithLefts(structs, si);
      }
    }
  });
};
var cleanupTransactions = (transactionCleanups, i) => {
  if (i < transactionCleanups.length) {
    const transaction = transactionCleanups[i];
    const doc2 = transaction.doc;
    const store = doc2.store;
    const ds = transaction.deleteSet;
    const mergeStructs = transaction._mergeStructs;
    try {
      sortAndMergeDeleteSet(ds);
      transaction.afterState = getStateVector(transaction.doc.store);
      doc2.emit("beforeObserverCalls", [transaction, doc2]);
      const fs = [];
      transaction.changed.forEach(
        (subs, itemtype) => fs.push(() => {
          if (itemtype._item === null || !itemtype._item.deleted) {
            itemtype._callObserver(transaction, subs);
          }
        })
      );
      fs.push(() => {
        transaction.changedParentTypes.forEach((events, type) => {
          if (type._dEH.l.length > 0 && (type._item === null || !type._item.deleted)) {
            fs.push(() => {
              events = events.filter(
                (event) => event.target._item === null || !event.target._item.deleted
              );
              events.forEach((event) => {
                event.currentTarget = type;
                event._path = null;
              });
              events.sort((event1, event2) => event1.path.length - event2.path.length);
              callEventHandlerListeners(type._dEH, events, transaction);
            });
          }
        });
        fs.push(() => doc2.emit("afterTransaction", [transaction, doc2]));
        fs.push(() => {
          if (transaction._needFormattingCleanup) {
            cleanupYTextAfterTransaction(transaction);
          }
        });
      });
      callAll(fs, []);
    } finally {
      if (doc2.gc) {
        tryGcDeleteSet(ds, store, doc2.gcFilter);
      }
      tryMergeDeleteSet(ds, store);
      transaction.afterState.forEach((clock, client) => {
        const beforeClock = transaction.beforeState.get(client) || 0;
        if (beforeClock !== clock) {
          const structs = (
            /** @type {Array<GC|Item>} */
            store.clients.get(client)
          );
          const firstChangePos = max(findIndexSS(structs, beforeClock), 1);
          for (let i2 = structs.length - 1; i2 >= firstChangePos; ) {
            i2 -= 1 + tryToMergeWithLefts(structs, i2);
          }
        }
      });
      for (let i2 = mergeStructs.length - 1; i2 >= 0; i2--) {
        const { client, clock } = mergeStructs[i2].id;
        const structs = (
          /** @type {Array<GC|Item>} */
          store.clients.get(client)
        );
        const replacedStructPos = findIndexSS(structs, clock);
        if (replacedStructPos + 1 < structs.length) {
          if (tryToMergeWithLefts(structs, replacedStructPos + 1) > 1) {
            continue;
          }
        }
        if (replacedStructPos > 0) {
          tryToMergeWithLefts(structs, replacedStructPos);
        }
      }
      if (!transaction.local && transaction.afterState.get(doc2.clientID) !== transaction.beforeState.get(doc2.clientID)) {
        print(ORANGE, BOLD, "[yjs] ", UNBOLD, RED, "Changed the client-id because another client seems to be using it.");
        doc2.clientID = generateNewClientId();
      }
      doc2.emit("afterTransactionCleanup", [transaction, doc2]);
      if (doc2._observers.has("update")) {
        const encoder = new UpdateEncoderV1();
        const hasContent2 = writeUpdateMessageFromTransaction(encoder, transaction);
        if (hasContent2) {
          doc2.emit("update", [encoder.toUint8Array(), transaction.origin, doc2, transaction]);
        }
      }
      if (doc2._observers.has("updateV2")) {
        const encoder = new UpdateEncoderV2();
        const hasContent2 = writeUpdateMessageFromTransaction(encoder, transaction);
        if (hasContent2) {
          doc2.emit("updateV2", [encoder.toUint8Array(), transaction.origin, doc2, transaction]);
        }
      }
      const { subdocsAdded, subdocsLoaded, subdocsRemoved } = transaction;
      if (subdocsAdded.size > 0 || subdocsRemoved.size > 0 || subdocsLoaded.size > 0) {
        subdocsAdded.forEach((subdoc) => {
          subdoc.clientID = doc2.clientID;
          if (subdoc.collectionid == null) {
            subdoc.collectionid = doc2.collectionid;
          }
          doc2.subdocs.add(subdoc);
        });
        subdocsRemoved.forEach((subdoc) => doc2.subdocs.delete(subdoc));
        doc2.emit("subdocs", [{ loaded: subdocsLoaded, added: subdocsAdded, removed: subdocsRemoved }, doc2, transaction]);
        subdocsRemoved.forEach((subdoc) => subdoc.destroy());
      }
      if (transactionCleanups.length <= i + 1) {
        doc2._transactionCleanups = [];
        doc2.emit("afterAllTransactions", [doc2, transactionCleanups]);
      } else {
        cleanupTransactions(transactionCleanups, i + 1);
      }
    }
  }
};
var transact = (doc2, f2, origin = null, local = true) => {
  const transactionCleanups = doc2._transactionCleanups;
  let initialCall = false;
  let result = null;
  if (doc2._transaction === null) {
    initialCall = true;
    doc2._transaction = new Transaction(doc2, origin, local);
    transactionCleanups.push(doc2._transaction);
    if (transactionCleanups.length === 1) {
      doc2.emit("beforeAllTransactions", [doc2]);
    }
    doc2.emit("beforeTransaction", [doc2._transaction, doc2]);
  }
  try {
    result = f2(doc2._transaction);
  } finally {
    if (initialCall) {
      const finishCleanup = doc2._transaction === transactionCleanups[0];
      doc2._transaction = null;
      if (finishCleanup) {
        cleanupTransactions(transactionCleanups, 0);
      }
    }
  }
  return result;
};
var StackItem = class {
  /**
   * @param {DeleteSet} deletions
   * @param {DeleteSet} insertions
   */
  constructor(deletions, insertions) {
    this.insertions = insertions;
    this.deletions = deletions;
    this.meta = /* @__PURE__ */ new Map();
  }
};
var clearUndoManagerStackItem = (tr, um, stackItem) => {
  iterateDeletedStructs(tr, stackItem.deletions, (item) => {
    if (item instanceof Item && um.scope.some((type) => type === tr.doc || isParentOf(
      /** @type {AbstractType<any>} */
      type,
      item
    ))) {
      keepItem(item, false);
    }
  });
};
var popStackItem = (undoManager, stack, eventType) => {
  let _tr = null;
  const doc2 = undoManager.doc;
  const scope = undoManager.scope;
  transact(doc2, (transaction) => {
    while (stack.length > 0 && undoManager.currStackItem === null) {
      const store = doc2.store;
      const stackItem = (
        /** @type {StackItem} */
        stack.pop()
      );
      const itemsToRedo = /* @__PURE__ */ new Set();
      const itemsToDelete = [];
      let performedChange = false;
      iterateDeletedStructs(transaction, stackItem.insertions, (struct) => {
        if (struct instanceof Item) {
          if (struct.redone !== null) {
            let { item, diff } = followRedone(store, struct.id);
            if (diff > 0) {
              item = getItemCleanStart(transaction, createID(item.id.client, item.id.clock + diff));
            }
            struct = item;
          }
          if (!struct.deleted && scope.some((type) => type === transaction.doc || isParentOf(
            /** @type {AbstractType<any>} */
            type,
            /** @type {Item} */
            struct
          ))) {
            itemsToDelete.push(struct);
          }
        }
      });
      iterateDeletedStructs(transaction, stackItem.deletions, (struct) => {
        if (struct instanceof Item && scope.some((type) => type === transaction.doc || isParentOf(
          /** @type {AbstractType<any>} */
          type,
          struct
        )) && // Never redo structs in stackItem.insertions because they were created and deleted in the same capture interval.
        !isDeleted(stackItem.insertions, struct.id)) {
          itemsToRedo.add(struct);
        }
      });
      itemsToRedo.forEach((struct) => {
        performedChange = redoItem(transaction, struct, itemsToRedo, stackItem.insertions, undoManager.ignoreRemoteMapChanges, undoManager) !== null || performedChange;
      });
      for (let i = itemsToDelete.length - 1; i >= 0; i--) {
        const item = itemsToDelete[i];
        if (undoManager.deleteFilter(item)) {
          item.delete(transaction);
          performedChange = true;
        }
      }
      undoManager.currStackItem = performedChange ? stackItem : null;
    }
    transaction.changed.forEach((subProps, type) => {
      if (subProps.has(null) && type._searchMarker) {
        type._searchMarker.length = 0;
      }
    });
    _tr = transaction;
  }, undoManager);
  const res = undoManager.currStackItem;
  if (res != null) {
    const changedParentTypes = _tr.changedParentTypes;
    undoManager.emit("stack-item-popped", [{ stackItem: res, type: eventType, changedParentTypes, origin: undoManager }, undoManager]);
    undoManager.currStackItem = null;
  }
  return res;
};
var UndoManager = class extends ObservableV2 {
  /**
   * @param {Doc|AbstractType<any>|Array<AbstractType<any>>} typeScope Limits the scope of the UndoManager. If this is set to a ydoc instance, all changes on that ydoc will be undone. If set to a specific type, only changes on that type or its children will be undone. Also accepts an array of types.
   * @param {UndoManagerOptions} options
   */
  constructor(typeScope, {
    captureTimeout = 500,
    captureTransaction = (_tr) => true,
    deleteFilter = () => true,
    trackedOrigins = /* @__PURE__ */ new Set([null]),
    ignoreRemoteMapChanges = false,
    doc: doc2 = (
      /** @type {Doc} */
      isArray(typeScope) ? typeScope[0].doc : typeScope instanceof Doc ? typeScope : typeScope.doc
    )
  } = {}) {
    super();
    this.scope = [];
    this.doc = doc2;
    this.addToScope(typeScope);
    this.deleteFilter = deleteFilter;
    trackedOrigins.add(this);
    this.trackedOrigins = trackedOrigins;
    this.captureTransaction = captureTransaction;
    this.undoStack = [];
    this.redoStack = [];
    this.undoing = false;
    this.redoing = false;
    this.currStackItem = null;
    this.lastChange = 0;
    this.ignoreRemoteMapChanges = ignoreRemoteMapChanges;
    this.captureTimeout = captureTimeout;
    this.afterTransactionHandler = (transaction) => {
      if (!this.captureTransaction(transaction) || !this.scope.some((type) => transaction.changedParentTypes.has(
        /** @type {AbstractType<any>} */
        type
      ) || type === this.doc) || !this.trackedOrigins.has(transaction.origin) && (!transaction.origin || !this.trackedOrigins.has(transaction.origin.constructor))) {
        return;
      }
      const undoing = this.undoing;
      const redoing = this.redoing;
      const stack = undoing ? this.redoStack : this.undoStack;
      if (undoing) {
        this.stopCapturing();
      } else if (!redoing) {
        this.clear(false, true);
      }
      const insertions = new DeleteSet();
      transaction.afterState.forEach((endClock, client) => {
        const startClock = transaction.beforeState.get(client) || 0;
        const len = endClock - startClock;
        if (len > 0) {
          addToDeleteSet(insertions, client, startClock, len);
        }
      });
      const now = getUnixTime();
      let didAdd = false;
      if (this.lastChange > 0 && now - this.lastChange < this.captureTimeout && stack.length > 0 && !undoing && !redoing) {
        const lastOp = stack[stack.length - 1];
        lastOp.deletions = mergeDeleteSets([lastOp.deletions, transaction.deleteSet]);
        lastOp.insertions = mergeDeleteSets([lastOp.insertions, insertions]);
      } else {
        stack.push(new StackItem(transaction.deleteSet, insertions));
        didAdd = true;
      }
      if (!undoing && !redoing) {
        this.lastChange = now;
      }
      iterateDeletedStructs(
        transaction,
        transaction.deleteSet,
        /** @param {Item|GC} item */
        (item) => {
          if (item instanceof Item && this.scope.some((type) => type === transaction.doc || isParentOf(
            /** @type {AbstractType<any>} */
            type,
            item
          ))) {
            keepItem(item, true);
          }
        }
      );
      const changeEvent = [{ stackItem: stack[stack.length - 1], origin: transaction.origin, type: undoing ? "redo" : "undo", changedParentTypes: transaction.changedParentTypes }, this];
      if (didAdd) {
        this.emit("stack-item-added", changeEvent);
      } else {
        this.emit("stack-item-updated", changeEvent);
      }
    };
    this.destroy = this.destroy.bind(this);
    this.doc.on("afterTransaction", this.afterTransactionHandler);
    this.doc.on("destroy", this.destroy);
  }
  /**
   * Extend the scope.
   *
   * @param {Array<AbstractType<any> | Doc> | AbstractType<any> | Doc} ytypes
   */
  addToScope(ytypes) {
    const tmpSet = new Set(this.scope);
    ytypes = isArray(ytypes) ? ytypes : [ytypes];
    ytypes.forEach((ytype) => {
      if (!tmpSet.has(ytype)) {
        tmpSet.add(ytype);
        if (ytype instanceof AbstractType ? ytype.doc !== this.doc : ytype !== this.doc) warn("[yjs#509] Not same Y.Doc");
        this.scope.push(ytype);
      }
    });
  }
  /**
   * @param {any} origin
   */
  addTrackedOrigin(origin) {
    this.trackedOrigins.add(origin);
  }
  /**
   * @param {any} origin
   */
  removeTrackedOrigin(origin) {
    this.trackedOrigins.delete(origin);
  }
  clear(clearUndoStack = true, clearRedoStack = true) {
    if (clearUndoStack && this.canUndo() || clearRedoStack && this.canRedo()) {
      this.doc.transact((tr) => {
        if (clearUndoStack) {
          this.undoStack.forEach((item) => clearUndoManagerStackItem(tr, this, item));
          this.undoStack = [];
        }
        if (clearRedoStack) {
          this.redoStack.forEach((item) => clearUndoManagerStackItem(tr, this, item));
          this.redoStack = [];
        }
        this.emit("stack-cleared", [{ undoStackCleared: clearUndoStack, redoStackCleared: clearRedoStack }]);
      });
    }
  }
  /**
   * UndoManager merges Undo-StackItem if they are created within time-gap
   * smaller than `options.captureTimeout`. Call `um.stopCapturing()` so that the next
   * StackItem won't be merged.
   *
   *
   * @example
   *     // without stopCapturing
   *     ytext.insert(0, 'a')
   *     ytext.insert(1, 'b')
   *     um.undo()
   *     ytext.toString() // => '' (note that 'ab' was removed)
   *     // with stopCapturing
   *     ytext.insert(0, 'a')
   *     um.stopCapturing()
   *     ytext.insert(0, 'b')
   *     um.undo()
   *     ytext.toString() // => 'a' (note that only 'b' was removed)
   *
   */
  stopCapturing() {
    this.lastChange = 0;
  }
  /**
   * Undo last changes on type.
   *
   * @return {StackItem?} Returns StackItem if a change was applied
   */
  undo() {
    this.undoing = true;
    let res;
    try {
      res = popStackItem(this, this.undoStack, "undo");
    } finally {
      this.undoing = false;
    }
    return res;
  }
  /**
   * Redo last undo operation.
   *
   * @return {StackItem?} Returns StackItem if a change was applied
   */
  redo() {
    this.redoing = true;
    let res;
    try {
      res = popStackItem(this, this.redoStack, "redo");
    } finally {
      this.redoing = false;
    }
    return res;
  }
  /**
   * Are undo steps available?
   *
   * @return {boolean} `true` if undo is possible
   */
  canUndo() {
    return this.undoStack.length > 0;
  }
  /**
   * Are redo steps available?
   *
   * @return {boolean} `true` if redo is possible
   */
  canRedo() {
    return this.redoStack.length > 0;
  }
  destroy() {
    this.trackedOrigins.delete(this);
    this.doc.off("afterTransaction", this.afterTransactionHandler);
    this.doc.off("destroy", this.destroy);
    super.destroy();
  }
};
function* lazyStructReaderGenerator(decoder) {
  const numOfStateUpdates = readVarUint(decoder.restDecoder);
  for (let i = 0; i < numOfStateUpdates; i++) {
    const numberOfStructs = readVarUint(decoder.restDecoder);
    const client = decoder.readClient();
    let clock = readVarUint(decoder.restDecoder);
    for (let i2 = 0; i2 < numberOfStructs; i2++) {
      const info = decoder.readInfo();
      if (info === 10) {
        const len = readVarUint(decoder.restDecoder);
        yield new Skip(createID(client, clock), len);
        clock += len;
      } else if ((BITS5 & info) !== 0) {
        const cantCopyParentInfo = (info & (BIT7 | BIT8)) === 0;
        const struct = new Item(
          createID(client, clock),
          null,
          // left
          (info & BIT8) === BIT8 ? decoder.readLeftID() : null,
          // origin
          null,
          // right
          (info & BIT7) === BIT7 ? decoder.readRightID() : null,
          // right origin
          // @ts-ignore Force writing a string here.
          cantCopyParentInfo ? decoder.readParentInfo() ? decoder.readString() : decoder.readLeftID() : null,
          // parent
          cantCopyParentInfo && (info & BIT6) === BIT6 ? decoder.readString() : null,
          // parentSub
          readItemContent(decoder, info)
          // item content
        );
        yield struct;
        clock += struct.length;
      } else {
        const len = decoder.readLen();
        yield new GC(createID(client, clock), len);
        clock += len;
      }
    }
  }
}
var LazyStructReader = class {
  /**
   * @param {UpdateDecoderV1 | UpdateDecoderV2} decoder
   * @param {boolean} filterSkips
   */
  constructor(decoder, filterSkips) {
    this.gen = lazyStructReaderGenerator(decoder);
    this.curr = null;
    this.done = false;
    this.filterSkips = filterSkips;
    this.next();
  }
  /**
   * @return {Item | GC | Skip |null}
   */
  next() {
    do {
      this.curr = this.gen.next().value || null;
    } while (this.filterSkips && this.curr !== null && this.curr.constructor === Skip);
    return this.curr;
  }
};
var LazyStructWriter = class {
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   */
  constructor(encoder) {
    this.currClient = 0;
    this.startClock = 0;
    this.written = 0;
    this.encoder = encoder;
    this.clientStructs = [];
  }
};
var mergeUpdates = (updates) => mergeUpdatesV2(updates, UpdateDecoderV1, UpdateEncoderV1);
var sliceStruct = (left, diff) => {
  if (left.constructor === GC) {
    const { client, clock } = left.id;
    return new GC(createID(client, clock + diff), left.length - diff);
  } else if (left.constructor === Skip) {
    const { client, clock } = left.id;
    return new Skip(createID(client, clock + diff), left.length - diff);
  } else {
    const leftItem = (
      /** @type {Item} */
      left
    );
    const { client, clock } = leftItem.id;
    return new Item(
      createID(client, clock + diff),
      null,
      createID(client, clock + diff - 1),
      null,
      leftItem.rightOrigin,
      leftItem.parent,
      leftItem.parentSub,
      leftItem.content.splice(diff)
    );
  }
};
var mergeUpdatesV2 = (updates, YDecoder = UpdateDecoderV2, YEncoder = UpdateEncoderV2) => {
  if (updates.length === 1) {
    return updates[0];
  }
  const updateDecoders = updates.map((update) => new YDecoder(createDecoder(update)));
  let lazyStructDecoders = updateDecoders.map((decoder) => new LazyStructReader(decoder, true));
  let currWrite = null;
  const updateEncoder = new YEncoder();
  const lazyStructEncoder = new LazyStructWriter(updateEncoder);
  while (true) {
    lazyStructDecoders = lazyStructDecoders.filter((dec) => dec.curr !== null);
    lazyStructDecoders.sort(
      /** @type {function(any,any):number} */
      (dec1, dec2) => {
        if (dec1.curr.id.client === dec2.curr.id.client) {
          const clockDiff = dec1.curr.id.clock - dec2.curr.id.clock;
          if (clockDiff === 0) {
            return dec1.curr.constructor === dec2.curr.constructor ? 0 : dec1.curr.constructor === Skip ? 1 : -1;
          } else {
            return clockDiff;
          }
        } else {
          return dec2.curr.id.client - dec1.curr.id.client;
        }
      }
    );
    if (lazyStructDecoders.length === 0) {
      break;
    }
    const currDecoder = lazyStructDecoders[0];
    const firstClient = (
      /** @type {Item | GC} */
      currDecoder.curr.id.client
    );
    if (currWrite !== null) {
      let curr = (
        /** @type {Item | GC | null} */
        currDecoder.curr
      );
      let iterated = false;
      while (curr !== null && curr.id.clock + curr.length <= currWrite.struct.id.clock + currWrite.struct.length && curr.id.client >= currWrite.struct.id.client) {
        curr = currDecoder.next();
        iterated = true;
      }
      if (curr === null || // current decoder is empty
      curr.id.client !== firstClient || // check whether there is another decoder that has has updates from `firstClient`
      iterated && curr.id.clock > currWrite.struct.id.clock + currWrite.struct.length) {
        continue;
      }
      if (firstClient !== currWrite.struct.id.client) {
        writeStructToLazyStructWriter(lazyStructEncoder, currWrite.struct, currWrite.offset);
        currWrite = { struct: curr, offset: 0 };
        currDecoder.next();
      } else {
        if (currWrite.struct.id.clock + currWrite.struct.length < curr.id.clock) {
          if (currWrite.struct.constructor === Skip) {
            currWrite.struct.length = curr.id.clock + curr.length - currWrite.struct.id.clock;
          } else {
            writeStructToLazyStructWriter(lazyStructEncoder, currWrite.struct, currWrite.offset);
            const diff = curr.id.clock - currWrite.struct.id.clock - currWrite.struct.length;
            const struct = new Skip(createID(firstClient, currWrite.struct.id.clock + currWrite.struct.length), diff);
            currWrite = { struct, offset: 0 };
          }
        } else {
          const diff = currWrite.struct.id.clock + currWrite.struct.length - curr.id.clock;
          if (diff > 0) {
            if (currWrite.struct.constructor === Skip) {
              currWrite.struct.length -= diff;
            } else {
              curr = sliceStruct(curr, diff);
            }
          }
          if (!currWrite.struct.mergeWith(
            /** @type {any} */
            curr
          )) {
            writeStructToLazyStructWriter(lazyStructEncoder, currWrite.struct, currWrite.offset);
            currWrite = { struct: curr, offset: 0 };
            currDecoder.next();
          }
        }
      }
    } else {
      currWrite = { struct: (
        /** @type {Item | GC} */
        currDecoder.curr
      ), offset: 0 };
      currDecoder.next();
    }
    for (let next = currDecoder.curr; next !== null && next.id.client === firstClient && next.id.clock === currWrite.struct.id.clock + currWrite.struct.length && next.constructor !== Skip; next = currDecoder.next()) {
      writeStructToLazyStructWriter(lazyStructEncoder, currWrite.struct, currWrite.offset);
      currWrite = { struct: next, offset: 0 };
    }
  }
  if (currWrite !== null) {
    writeStructToLazyStructWriter(lazyStructEncoder, currWrite.struct, currWrite.offset);
    currWrite = null;
  }
  finishLazyStructWriting(lazyStructEncoder);
  const dss = updateDecoders.map((decoder) => readDeleteSet(decoder));
  const ds = mergeDeleteSets(dss);
  writeDeleteSet(updateEncoder, ds);
  return updateEncoder.toUint8Array();
};
var diffUpdateV2 = (update, sv, YDecoder = UpdateDecoderV2, YEncoder = UpdateEncoderV2) => {
  const state = decodeStateVector(sv);
  const encoder = new YEncoder();
  const lazyStructWriter = new LazyStructWriter(encoder);
  const decoder = new YDecoder(createDecoder(update));
  const reader = new LazyStructReader(decoder, false);
  while (reader.curr) {
    const curr = reader.curr;
    const currClient = curr.id.client;
    const svClock = state.get(currClient) || 0;
    if (reader.curr.constructor === Skip) {
      reader.next();
      continue;
    }
    if (curr.id.clock + curr.length > svClock) {
      writeStructToLazyStructWriter(lazyStructWriter, curr, max(svClock - curr.id.clock, 0));
      reader.next();
      while (reader.curr && reader.curr.id.client === currClient) {
        writeStructToLazyStructWriter(lazyStructWriter, reader.curr, 0);
        reader.next();
      }
    } else {
      while (reader.curr && reader.curr.id.client === currClient && reader.curr.id.clock + reader.curr.length <= svClock) {
        reader.next();
      }
    }
  }
  finishLazyStructWriting(lazyStructWriter);
  const ds = readDeleteSet(decoder);
  writeDeleteSet(encoder, ds);
  return encoder.toUint8Array();
};
var flushLazyStructWriter = (lazyWriter) => {
  if (lazyWriter.written > 0) {
    lazyWriter.clientStructs.push({ written: lazyWriter.written, restEncoder: toUint8Array(lazyWriter.encoder.restEncoder) });
    lazyWriter.encoder.restEncoder = createEncoder();
    lazyWriter.written = 0;
  }
};
var writeStructToLazyStructWriter = (lazyWriter, struct, offset) => {
  if (lazyWriter.written > 0 && lazyWriter.currClient !== struct.id.client) {
    flushLazyStructWriter(lazyWriter);
  }
  if (lazyWriter.written === 0) {
    lazyWriter.currClient = struct.id.client;
    lazyWriter.encoder.writeClient(struct.id.client);
    writeVarUint(lazyWriter.encoder.restEncoder, struct.id.clock + offset);
  }
  struct.write(lazyWriter.encoder, offset);
  lazyWriter.written++;
};
var finishLazyStructWriting = (lazyWriter) => {
  flushLazyStructWriter(lazyWriter);
  const restEncoder = lazyWriter.encoder.restEncoder;
  writeVarUint(restEncoder, lazyWriter.clientStructs.length);
  for (let i = 0; i < lazyWriter.clientStructs.length; i++) {
    const partStructs = lazyWriter.clientStructs[i];
    writeVarUint(restEncoder, partStructs.written);
    writeUint8Array(restEncoder, partStructs.restEncoder);
  }
};
var convertUpdateFormat = (update, blockTransformer, YDecoder, YEncoder) => {
  const updateDecoder = new YDecoder(createDecoder(update));
  const lazyDecoder = new LazyStructReader(updateDecoder, false);
  const updateEncoder = new YEncoder();
  const lazyWriter = new LazyStructWriter(updateEncoder);
  for (let curr = lazyDecoder.curr; curr !== null; curr = lazyDecoder.next()) {
    writeStructToLazyStructWriter(lazyWriter, blockTransformer(curr), 0);
  }
  finishLazyStructWriting(lazyWriter);
  const ds = readDeleteSet(updateDecoder);
  writeDeleteSet(updateEncoder, ds);
  return updateEncoder.toUint8Array();
};
var convertUpdateFormatV2ToV1 = (update) => convertUpdateFormat(update, id, UpdateDecoderV2, UpdateEncoderV1);
var errorComputeChanges = "You must not compute changes after the event-handler fired.";
var YEvent = class {
  /**
   * @param {T} target The changed type.
   * @param {Transaction} transaction
   */
  constructor(target, transaction) {
    this.target = target;
    this.currentTarget = target;
    this.transaction = transaction;
    this._changes = null;
    this._keys = null;
    this._delta = null;
    this._path = null;
  }
  /**
   * Computes the path from `y` to the changed type.
   *
   * @todo v14 should standardize on path: Array<{parent, index}> because that is easier to work with.
   *
   * The following property holds:
   * @example
   *   let type = y
   *   event.path.forEach(dir => {
   *     type = type.get(dir)
   *   })
   *   type === event.target // => true
   */
  get path() {
    return this._path || (this._path = getPathTo(this.currentTarget, this.target));
  }
  /**
   * Check if a struct is deleted by this event.
   *
   * In contrast to change.deleted, this method also returns true if the struct was added and then deleted.
   *
   * @param {AbstractStruct} struct
   * @return {boolean}
   */
  deletes(struct) {
    return isDeleted(this.transaction.deleteSet, struct.id);
  }
  /**
   * @type {Map<string, { action: 'add' | 'update' | 'delete', oldValue: any }>}
   */
  get keys() {
    if (this._keys === null) {
      if (this.transaction.doc._transactionCleanups.length === 0) {
        throw create3(errorComputeChanges);
      }
      const keys2 = /* @__PURE__ */ new Map();
      const target = this.target;
      const changed = (
        /** @type Set<string|null> */
        this.transaction.changed.get(target)
      );
      changed.forEach((key) => {
        if (key !== null) {
          const item = (
            /** @type {Item} */
            target._map.get(key)
          );
          let action;
          let oldValue;
          if (this.adds(item)) {
            let prev = item.left;
            while (prev !== null && this.adds(prev)) {
              prev = prev.left;
            }
            if (this.deletes(item)) {
              if (prev !== null && this.deletes(prev)) {
                action = "delete";
                oldValue = last(prev.content.getContent());
              } else {
                return;
              }
            } else {
              if (prev !== null && this.deletes(prev)) {
                action = "update";
                oldValue = last(prev.content.getContent());
              } else {
                action = "add";
                oldValue = void 0;
              }
            }
          } else {
            if (this.deletes(item)) {
              action = "delete";
              oldValue = last(
                /** @type {Item} */
                item.content.getContent()
              );
            } else {
              return;
            }
          }
          keys2.set(key, { action, oldValue });
        }
      });
      this._keys = keys2;
    }
    return this._keys;
  }
  /**
   * This is a computed property. Note that this can only be safely computed during the
   * event call. Computing this property after other changes happened might result in
   * unexpected behavior (incorrect computation of deltas). A safe way to collect changes
   * is to store the `changes` or the `delta` object. Avoid storing the `transaction` object.
   *
   * @type {Array<{insert?: string | Array<any> | object | AbstractType<any>, retain?: number, delete?: number, attributes?: Object<string, any>}>}
   */
  get delta() {
    return this.changes.delta;
  }
  /**
   * Check if a struct is added by this event.
   *
   * In contrast to change.deleted, this method also returns true if the struct was added and then deleted.
   *
   * @param {AbstractStruct} struct
   * @return {boolean}
   */
  adds(struct) {
    return struct.id.clock >= (this.transaction.beforeState.get(struct.id.client) || 0);
  }
  /**
   * This is a computed property. Note that this can only be safely computed during the
   * event call. Computing this property after other changes happened might result in
   * unexpected behavior (incorrect computation of deltas). A safe way to collect changes
   * is to store the `changes` or the `delta` object. Avoid storing the `transaction` object.
   *
   * @type {{added:Set<Item>,deleted:Set<Item>,keys:Map<string,{action:'add'|'update'|'delete',oldValue:any}>,delta:Array<{insert?:Array<any>|string, delete?:number, retain?:number}>}}
   */
  get changes() {
    let changes2 = this._changes;
    if (changes2 === null) {
      if (this.transaction.doc._transactionCleanups.length === 0) {
        throw create3(errorComputeChanges);
      }
      const target = this.target;
      const added = create2();
      const deleted = create2();
      const delta = [];
      changes2 = {
        added,
        deleted,
        delta,
        keys: this.keys
      };
      const changed = (
        /** @type Set<string|null> */
        this.transaction.changed.get(target)
      );
      if (changed.has(null)) {
        let lastOp = null;
        const packOp = () => {
          if (lastOp) {
            delta.push(lastOp);
          }
        };
        for (let item = target._start; item !== null; item = item.right) {
          if (item.deleted) {
            if (this.deletes(item) && !this.adds(item)) {
              if (lastOp === null || lastOp.delete === void 0) {
                packOp();
                lastOp = { delete: 0 };
              }
              lastOp.delete += item.length;
              deleted.add(item);
            }
          } else {
            if (this.adds(item)) {
              if (lastOp === null || lastOp.insert === void 0) {
                packOp();
                lastOp = { insert: [] };
              }
              lastOp.insert = lastOp.insert.concat(item.content.getContent());
              added.add(item);
            } else {
              if (lastOp === null || lastOp.retain === void 0) {
                packOp();
                lastOp = { retain: 0 };
              }
              lastOp.retain += item.length;
            }
          }
        }
        if (lastOp !== null && lastOp.retain === void 0) {
          packOp();
        }
      }
      this._changes = changes2;
    }
    return (
      /** @type {any} */
      changes2
    );
  }
};
var getPathTo = (parent, child) => {
  const path = [];
  while (child._item !== null && child !== parent) {
    if (child._item.parentSub !== null) {
      path.unshift(child._item.parentSub);
    } else {
      let i = 0;
      let c = (
        /** @type {AbstractType<any>} */
        child._item.parent._start
      );
      while (c !== child._item && c !== null) {
        if (!c.deleted && c.countable) {
          i += c.length;
        }
        c = c.right;
      }
      path.unshift(i);
    }
    child = /** @type {AbstractType<any>} */
    child._item.parent;
  }
  return path;
};
var warnPrematureAccess = () => {
  warn("Invalid access: Add Yjs type to a document before reading data.");
};
var maxSearchMarker = 80;
var globalSearchMarkerTimestamp = 0;
var ArraySearchMarker = class {
  /**
   * @param {Item} p
   * @param {number} index
   */
  constructor(p, index) {
    p.marker = true;
    this.p = p;
    this.index = index;
    this.timestamp = globalSearchMarkerTimestamp++;
  }
};
var refreshMarkerTimestamp = (marker) => {
  marker.timestamp = globalSearchMarkerTimestamp++;
};
var overwriteMarker = (marker, p, index) => {
  marker.p.marker = false;
  marker.p = p;
  p.marker = true;
  marker.index = index;
  marker.timestamp = globalSearchMarkerTimestamp++;
};
var markPosition = (searchMarker, p, index) => {
  if (searchMarker.length >= maxSearchMarker) {
    const marker = searchMarker.reduce((a3, b) => a3.timestamp < b.timestamp ? a3 : b);
    overwriteMarker(marker, p, index);
    return marker;
  } else {
    const pm = new ArraySearchMarker(p, index);
    searchMarker.push(pm);
    return pm;
  }
};
var findMarker = (yarray, index) => {
  if (yarray._start === null || index === 0 || yarray._searchMarker === null) {
    return null;
  }
  const marker = yarray._searchMarker.length === 0 ? null : yarray._searchMarker.reduce((a3, b) => abs(index - a3.index) < abs(index - b.index) ? a3 : b);
  let p = yarray._start;
  let pindex = 0;
  if (marker !== null) {
    p = marker.p;
    pindex = marker.index;
    refreshMarkerTimestamp(marker);
  }
  while (p.right !== null && pindex < index) {
    if (!p.deleted && p.countable) {
      if (index < pindex + p.length) {
        break;
      }
      pindex += p.length;
    }
    p = p.right;
  }
  while (p.left !== null && pindex > index) {
    p = p.left;
    if (!p.deleted && p.countable) {
      pindex -= p.length;
    }
  }
  while (p.left !== null && p.left.id.client === p.id.client && p.left.id.clock + p.left.length === p.id.clock) {
    p = p.left;
    if (!p.deleted && p.countable) {
      pindex -= p.length;
    }
  }
  if (marker !== null && abs(marker.index - pindex) < /** @type {YText|YArray<any>} */
  p.parent.length / maxSearchMarker) {
    overwriteMarker(marker, p, pindex);
    return marker;
  } else {
    return markPosition(yarray._searchMarker, p, pindex);
  }
};
var updateMarkerChanges = (searchMarker, index, len) => {
  for (let i = searchMarker.length - 1; i >= 0; i--) {
    const m = searchMarker[i];
    if (len > 0) {
      let p = m.p;
      p.marker = false;
      while (p && (p.deleted || !p.countable)) {
        p = p.left;
        if (p && !p.deleted && p.countable) {
          m.index -= p.length;
        }
      }
      if (p === null || p.marker === true) {
        searchMarker.splice(i, 1);
        continue;
      }
      m.p = p;
      p.marker = true;
    }
    if (index < m.index || len > 0 && index === m.index) {
      m.index = max(index, m.index + len);
    }
  }
};
var callTypeObservers = (type, transaction, event) => {
  const changedType = type;
  const changedParentTypes = transaction.changedParentTypes;
  while (true) {
    setIfUndefined(changedParentTypes, type, () => []).push(event);
    if (type._item === null) {
      break;
    }
    type = /** @type {AbstractType<any>} */
    type._item.parent;
  }
  callEventHandlerListeners(changedType._eH, event, transaction);
};
var AbstractType = class {
  constructor() {
    this._item = null;
    this._map = /* @__PURE__ */ new Map();
    this._start = null;
    this.doc = null;
    this._length = 0;
    this._eH = createEventHandler();
    this._dEH = createEventHandler();
    this._searchMarker = null;
  }
  /**
   * @return {AbstractType<any>|null}
   */
  get parent() {
    return this._item ? (
      /** @type {AbstractType<any>} */
      this._item.parent
    ) : null;
  }
  /**
   * Integrate this type into the Yjs instance.
   *
   * * Save this struct in the os
   * * This type is sent to other client
   * * Observer functions are fired
   *
   * @param {Doc} y The Yjs instance
   * @param {Item|null} item
   */
  _integrate(y2, item) {
    this.doc = y2;
    this._item = item;
  }
  /**
   * @return {AbstractType<EventType>}
   */
  _copy() {
    throw methodUnimplemented();
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {AbstractType<EventType>}
   */
  clone() {
    throw methodUnimplemented();
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} _encoder
   */
  _write(_encoder) {
  }
  /**
   * The first non-deleted item
   */
  get _first() {
    let n = this._start;
    while (n !== null && n.deleted) {
      n = n.right;
    }
    return n;
  }
  /**
   * Creates YEvent and calls all type observers.
   * Must be implemented by each type.
   *
   * @param {Transaction} transaction
   * @param {Set<null|string>} _parentSubs Keys changed on this type. `null` if list was modified.
   */
  _callObserver(transaction, _parentSubs) {
    if (!transaction.local && this._searchMarker) {
      this._searchMarker.length = 0;
    }
  }
  /**
   * Observe all events that are created on this type.
   *
   * @param {function(EventType, Transaction):void} f Observer function
   */
  observe(f2) {
    addEventHandlerListener(this._eH, f2);
  }
  /**
   * Observe all events that are created by this type and its children.
   *
   * @param {function(Array<YEvent<any>>,Transaction):void} f Observer function
   */
  observeDeep(f2) {
    addEventHandlerListener(this._dEH, f2);
  }
  /**
   * Unregister an observer function.
   *
   * @param {function(EventType,Transaction):void} f Observer function
   */
  unobserve(f2) {
    removeEventHandlerListener(this._eH, f2);
  }
  /**
   * Unregister an observer function.
   *
   * @param {function(Array<YEvent<any>>,Transaction):void} f Observer function
   */
  unobserveDeep(f2) {
    removeEventHandlerListener(this._dEH, f2);
  }
  /**
   * @abstract
   * @return {any}
   */
  toJSON() {
  }
};
var typeListSlice = (type, start2, end) => {
  type.doc ?? warnPrematureAccess();
  if (start2 < 0) {
    start2 = type._length + start2;
  }
  if (end < 0) {
    end = type._length + end;
  }
  let len = end - start2;
  const cs = [];
  let n = type._start;
  while (n !== null && len > 0) {
    if (n.countable && !n.deleted) {
      const c = n.content.getContent();
      if (c.length <= start2) {
        start2 -= c.length;
      } else {
        for (let i = start2; i < c.length && len > 0; i++) {
          cs.push(c[i]);
          len--;
        }
        start2 = 0;
      }
    }
    n = n.right;
  }
  return cs;
};
var typeListToArray = (type) => {
  type.doc ?? warnPrematureAccess();
  const cs = [];
  let n = type._start;
  while (n !== null) {
    if (n.countable && !n.deleted) {
      const c = n.content.getContent();
      for (let i = 0; i < c.length; i++) {
        cs.push(c[i]);
      }
    }
    n = n.right;
  }
  return cs;
};
var typeListForEach = (type, f2) => {
  let index = 0;
  let n = type._start;
  type.doc ?? warnPrematureAccess();
  while (n !== null) {
    if (n.countable && !n.deleted) {
      const c = n.content.getContent();
      for (let i = 0; i < c.length; i++) {
        f2(c[i], index++, type);
      }
    }
    n = n.right;
  }
};
var typeListMap = (type, f2) => {
  const result = [];
  typeListForEach(type, (c, i) => {
    result.push(f2(c, i, type));
  });
  return result;
};
var typeListCreateIterator = (type) => {
  let n = type._start;
  let currentContent = null;
  let currentContentIndex = 0;
  return {
    [Symbol.iterator]() {
      return this;
    },
    next: () => {
      if (currentContent === null) {
        while (n !== null && n.deleted) {
          n = n.right;
        }
        if (n === null) {
          return {
            done: true,
            value: void 0
          };
        }
        currentContent = n.content.getContent();
        currentContentIndex = 0;
        n = n.right;
      }
      const value = currentContent[currentContentIndex++];
      if (currentContent.length <= currentContentIndex) {
        currentContent = null;
      }
      return {
        done: false,
        value
      };
    }
  };
};
var typeListGet = (type, index) => {
  type.doc ?? warnPrematureAccess();
  const marker = findMarker(type, index);
  let n = type._start;
  if (marker !== null) {
    n = marker.p;
    index -= marker.index;
  }
  for (; n !== null; n = n.right) {
    if (!n.deleted && n.countable) {
      if (index < n.length) {
        return n.content.getContent()[index];
      }
      index -= n.length;
    }
  }
};
var typeListInsertGenericsAfter = (transaction, parent, referenceItem, content) => {
  let left = referenceItem;
  const doc2 = transaction.doc;
  const ownClientId = doc2.clientID;
  const store = doc2.store;
  const right = referenceItem === null ? parent._start : referenceItem.right;
  let jsonContent = [];
  const packJsonContent = () => {
    if (jsonContent.length > 0) {
      left = new Item(createID(ownClientId, getState(store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, new ContentAny(jsonContent));
      left.integrate(transaction, 0);
      jsonContent = [];
    }
  };
  content.forEach((c) => {
    if (c === null) {
      jsonContent.push(c);
    } else {
      switch (c.constructor) {
        case Number:
        case Object:
        case Boolean:
        case Array:
        case String:
          jsonContent.push(c);
          break;
        default:
          packJsonContent();
          switch (c.constructor) {
            case Uint8Array:
            case ArrayBuffer:
              left = new Item(createID(ownClientId, getState(store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, new ContentBinary(new Uint8Array(
                /** @type {Uint8Array} */
                c
              )));
              left.integrate(transaction, 0);
              break;
            case Doc:
              left = new Item(createID(ownClientId, getState(store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, new ContentDoc(
                /** @type {Doc} */
                c
              ));
              left.integrate(transaction, 0);
              break;
            default:
              if (c instanceof AbstractType) {
                left = new Item(createID(ownClientId, getState(store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, new ContentType(c));
                left.integrate(transaction, 0);
              } else {
                throw new Error("Unexpected content type in insert operation");
              }
          }
      }
    }
  });
  packJsonContent();
};
var lengthExceeded = () => create3("Length exceeded!");
var typeListInsertGenerics = (transaction, parent, index, content) => {
  if (index > parent._length) {
    throw lengthExceeded();
  }
  if (index === 0) {
    if (parent._searchMarker) {
      updateMarkerChanges(parent._searchMarker, index, content.length);
    }
    return typeListInsertGenericsAfter(transaction, parent, null, content);
  }
  const startIndex = index;
  const marker = findMarker(parent, index);
  let n = parent._start;
  if (marker !== null) {
    n = marker.p;
    index -= marker.index;
    if (index === 0) {
      n = n.prev;
      index += n && n.countable && !n.deleted ? n.length : 0;
    }
  }
  for (; n !== null; n = n.right) {
    if (!n.deleted && n.countable) {
      if (index <= n.length) {
        if (index < n.length) {
          getItemCleanStart(transaction, createID(n.id.client, n.id.clock + index));
        }
        break;
      }
      index -= n.length;
    }
  }
  if (parent._searchMarker) {
    updateMarkerChanges(parent._searchMarker, startIndex, content.length);
  }
  return typeListInsertGenericsAfter(transaction, parent, n, content);
};
var typeListPushGenerics = (transaction, parent, content) => {
  const marker = (parent._searchMarker || []).reduce((maxMarker, currMarker) => currMarker.index > maxMarker.index ? currMarker : maxMarker, { index: 0, p: parent._start });
  let n = marker.p;
  if (n) {
    while (n.right) {
      n = n.right;
    }
  }
  return typeListInsertGenericsAfter(transaction, parent, n, content);
};
var typeListDelete = (transaction, parent, index, length2) => {
  if (length2 === 0) {
    return;
  }
  const startIndex = index;
  const startLength = length2;
  const marker = findMarker(parent, index);
  let n = parent._start;
  if (marker !== null) {
    n = marker.p;
    index -= marker.index;
  }
  for (; n !== null && index > 0; n = n.right) {
    if (!n.deleted && n.countable) {
      if (index < n.length) {
        getItemCleanStart(transaction, createID(n.id.client, n.id.clock + index));
      }
      index -= n.length;
    }
  }
  while (length2 > 0 && n !== null) {
    if (!n.deleted) {
      if (length2 < n.length) {
        getItemCleanStart(transaction, createID(n.id.client, n.id.clock + length2));
      }
      n.delete(transaction);
      length2 -= n.length;
    }
    n = n.right;
  }
  if (length2 > 0) {
    throw lengthExceeded();
  }
  if (parent._searchMarker) {
    updateMarkerChanges(
      parent._searchMarker,
      startIndex,
      -startLength + length2
      /* in case we remove the above exception */
    );
  }
};
var typeMapDelete = (transaction, parent, key) => {
  const c = parent._map.get(key);
  if (c !== void 0) {
    c.delete(transaction);
  }
};
var typeMapSet = (transaction, parent, key, value) => {
  const left = parent._map.get(key) || null;
  const doc2 = transaction.doc;
  const ownClientId = doc2.clientID;
  let content;
  if (value == null) {
    content = new ContentAny([value]);
  } else {
    switch (value.constructor) {
      case Number:
      case Object:
      case Boolean:
      case Array:
      case String:
      case Date:
      case BigInt:
        content = new ContentAny([value]);
        break;
      case Uint8Array:
        content = new ContentBinary(
          /** @type {Uint8Array} */
          value
        );
        break;
      case Doc:
        content = new ContentDoc(
          /** @type {Doc} */
          value
        );
        break;
      default:
        if (value instanceof AbstractType) {
          content = new ContentType(value);
        } else {
          throw new Error("Unexpected content type");
        }
    }
  }
  new Item(createID(ownClientId, getState(doc2.store, ownClientId)), left, left && left.lastId, null, null, parent, key, content).integrate(transaction, 0);
};
var typeMapGet = (parent, key) => {
  parent.doc ?? warnPrematureAccess();
  const val = parent._map.get(key);
  return val !== void 0 && !val.deleted ? val.content.getContent()[val.length - 1] : void 0;
};
var typeMapGetAll = (parent) => {
  const res = {};
  parent.doc ?? warnPrematureAccess();
  parent._map.forEach((value, key) => {
    if (!value.deleted) {
      res[key] = value.content.getContent()[value.length - 1];
    }
  });
  return res;
};
var typeMapHas = (parent, key) => {
  parent.doc ?? warnPrematureAccess();
  const val = parent._map.get(key);
  return val !== void 0 && !val.deleted;
};
var typeMapGetAllSnapshot = (parent, snapshot) => {
  const res = {};
  parent._map.forEach((value, key) => {
    let v2 = value;
    while (v2 !== null && (!snapshot.sv.has(v2.id.client) || v2.id.clock >= (snapshot.sv.get(v2.id.client) || 0))) {
      v2 = v2.left;
    }
    if (v2 !== null && isVisible(v2, snapshot)) {
      res[key] = v2.content.getContent()[v2.length - 1];
    }
  });
  return res;
};
var createMapIterator = (type) => {
  type.doc ?? warnPrematureAccess();
  return iteratorFilter(
    type._map.entries(),
    /** @param {any} entry */
    (entry2) => !entry2[1].deleted
  );
};
var YArrayEvent = class extends YEvent {
};
var YArray = class _YArray extends AbstractType {
  constructor() {
    super();
    this._prelimContent = [];
    this._searchMarker = [];
  }
  /**
   * Construct a new YArray containing the specified items.
   * @template {Object<string,any>|Array<any>|number|null|string|Uint8Array} T
   * @param {Array<T>} items
   * @return {YArray<T>}
   */
  static from(items) {
    const a3 = new _YArray();
    a3.push(items);
    return a3;
  }
  /**
   * Integrate this type into the Yjs instance.
   *
   * * Save this struct in the os
   * * This type is sent to other client
   * * Observer functions are fired
   *
   * @param {Doc} y The Yjs instance
   * @param {Item} item
   */
  _integrate(y2, item) {
    super._integrate(y2, item);
    this.insert(
      0,
      /** @type {Array<any>} */
      this._prelimContent
    );
    this._prelimContent = null;
  }
  /**
   * @return {YArray<T>}
   */
  _copy() {
    return new _YArray();
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YArray<T>}
   */
  clone() {
    const arr = new _YArray();
    arr.insert(0, this.toArray().map(
      (el) => el instanceof AbstractType ? (
        /** @type {typeof el} */
        el.clone()
      ) : el
    ));
    return arr;
  }
  get length() {
    this.doc ?? warnPrematureAccess();
    return this._length;
  }
  /**
   * Creates YArrayEvent and calls observers.
   *
   * @param {Transaction} transaction
   * @param {Set<null|string>} parentSubs Keys changed on this type. `null` if list was modified.
   */
  _callObserver(transaction, parentSubs) {
    super._callObserver(transaction, parentSubs);
    callTypeObservers(this, transaction, new YArrayEvent(this, transaction));
  }
  /**
   * Inserts new content at an index.
   *
   * Important: This function expects an array of content. Not just a content
   * object. The reason for this "weirdness" is that inserting several elements
   * is very efficient when it is done as a single operation.
   *
   * @example
   *  // Insert character 'a' at position 0
   *  yarray.insert(0, ['a'])
   *  // Insert numbers 1, 2 at position 1
   *  yarray.insert(1, [1, 2])
   *
   * @param {number} index The index to insert content at.
   * @param {Array<T>} content The array of content
   */
  insert(index, content) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeListInsertGenerics(
          transaction,
          this,
          index,
          /** @type {any} */
          content
        );
      });
    } else {
      this._prelimContent.splice(index, 0, ...content);
    }
  }
  /**
   * Appends content to this YArray.
   *
   * @param {Array<T>} content Array of content to append.
   *
   * @todo Use the following implementation in all types.
   */
  push(content) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeListPushGenerics(
          transaction,
          this,
          /** @type {any} */
          content
        );
      });
    } else {
      this._prelimContent.push(...content);
    }
  }
  /**
   * Prepends content to this YArray.
   *
   * @param {Array<T>} content Array of content to prepend.
   */
  unshift(content) {
    this.insert(0, content);
  }
  /**
   * Deletes elements starting from an index.
   *
   * @param {number} index Index at which to start deleting elements
   * @param {number} length The number of elements to remove. Defaults to 1.
   */
  delete(index, length2 = 1) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeListDelete(transaction, this, index, length2);
      });
    } else {
      this._prelimContent.splice(index, length2);
    }
  }
  /**
   * Returns the i-th element from a YArray.
   *
   * @param {number} index The index of the element to return from the YArray
   * @return {T}
   */
  get(index) {
    return typeListGet(this, index);
  }
  /**
   * Transforms this YArray to a JavaScript Array.
   *
   * @return {Array<T>}
   */
  toArray() {
    return typeListToArray(this);
  }
  /**
   * Returns a portion of this YArray into a JavaScript Array selected
   * from start to end (end not included).
   *
   * @param {number} [start]
   * @param {number} [end]
   * @return {Array<T>}
   */
  slice(start2 = 0, end = this.length) {
    return typeListSlice(this, start2, end);
  }
  /**
   * Transforms this Shared Type to a JSON object.
   *
   * @return {Array<any>}
   */
  toJSON() {
    return this.map((c) => c instanceof AbstractType ? c.toJSON() : c);
  }
  /**
   * Returns an Array with the result of calling a provided function on every
   * element of this YArray.
   *
   * @template M
   * @param {function(T,number,YArray<T>):M} f Function that produces an element of the new Array
   * @return {Array<M>} A new array with each element being the result of the
   *                 callback function
   */
  map(f2) {
    return typeListMap(
      this,
      /** @type {any} */
      f2
    );
  }
  /**
   * Executes a provided function once on every element of this YArray.
   *
   * @param {function(T,number,YArray<T>):void} f A function to execute on every element of this YArray.
   */
  forEach(f2) {
    typeListForEach(this, f2);
  }
  /**
   * @return {IterableIterator<T>}
   */
  [Symbol.iterator]() {
    return typeListCreateIterator(this);
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   */
  _write(encoder) {
    encoder.writeTypeRef(YArrayRefID);
  }
};
var readYArray = (_decoder) => new YArray();
var YMapEvent = class extends YEvent {
  /**
   * @param {YMap<T>} ymap The YArray that changed.
   * @param {Transaction} transaction
   * @param {Set<any>} subs The keys that changed.
   */
  constructor(ymap, transaction, subs) {
    super(ymap, transaction);
    this.keysChanged = subs;
  }
};
var YMap = class _YMap extends AbstractType {
  /**
   *
   * @param {Iterable<readonly [string, any]>=} entries - an optional iterable to initialize the YMap
   */
  constructor(entries) {
    super();
    this._prelimContent = null;
    if (entries === void 0) {
      this._prelimContent = /* @__PURE__ */ new Map();
    } else {
      this._prelimContent = new Map(entries);
    }
  }
  /**
   * Integrate this type into the Yjs instance.
   *
   * * Save this struct in the os
   * * This type is sent to other client
   * * Observer functions are fired
   *
   * @param {Doc} y The Yjs instance
   * @param {Item} item
   */
  _integrate(y2, item) {
    super._integrate(y2, item);
    this._prelimContent.forEach((value, key) => {
      this.set(key, value);
    });
    this._prelimContent = null;
  }
  /**
   * @return {YMap<MapType>}
   */
  _copy() {
    return new _YMap();
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YMap<MapType>}
   */
  clone() {
    const map2 = new _YMap();
    this.forEach((value, key) => {
      map2.set(key, value instanceof AbstractType ? (
        /** @type {typeof value} */
        value.clone()
      ) : value);
    });
    return map2;
  }
  /**
   * Creates YMapEvent and calls observers.
   *
   * @param {Transaction} transaction
   * @param {Set<null|string>} parentSubs Keys changed on this type. `null` if list was modified.
   */
  _callObserver(transaction, parentSubs) {
    callTypeObservers(this, transaction, new YMapEvent(this, transaction, parentSubs));
  }
  /**
   * Transforms this Shared Type to a JSON object.
   *
   * @return {Object<string,any>}
   */
  toJSON() {
    this.doc ?? warnPrematureAccess();
    const map2 = {};
    this._map.forEach((item, key) => {
      if (!item.deleted) {
        const v2 = item.content.getContent()[item.length - 1];
        map2[key] = v2 instanceof AbstractType ? v2.toJSON() : v2;
      }
    });
    return map2;
  }
  /**
   * Returns the size of the YMap (count of key/value pairs)
   *
   * @return {number}
   */
  get size() {
    return [...createMapIterator(this)].length;
  }
  /**
   * Returns the keys for each element in the YMap Type.
   *
   * @return {IterableIterator<string>}
   */
  keys() {
    return iteratorMap(
      createMapIterator(this),
      /** @param {any} v */
      (v2) => v2[0]
    );
  }
  /**
   * Returns the values for each element in the YMap Type.
   *
   * @return {IterableIterator<MapType>}
   */
  values() {
    return iteratorMap(
      createMapIterator(this),
      /** @param {any} v */
      (v2) => v2[1].content.getContent()[v2[1].length - 1]
    );
  }
  /**
   * Returns an Iterator of [key, value] pairs
   *
   * @return {IterableIterator<[string, MapType]>}
   */
  entries() {
    return iteratorMap(
      createMapIterator(this),
      /** @param {any} v */
      (v2) => (
        /** @type {any} */
        [v2[0], v2[1].content.getContent()[v2[1].length - 1]]
      )
    );
  }
  /**
   * Executes a provided function on once on every key-value pair.
   *
   * @param {function(MapType,string,YMap<MapType>):void} f A function to execute on every element of this YArray.
   */
  forEach(f2) {
    this.doc ?? warnPrematureAccess();
    this._map.forEach((item, key) => {
      if (!item.deleted) {
        f2(item.content.getContent()[item.length - 1], key, this);
      }
    });
  }
  /**
   * Returns an Iterator of [key, value] pairs
   *
   * @return {IterableIterator<[string, MapType]>}
   */
  [Symbol.iterator]() {
    return this.entries();
  }
  /**
   * Remove a specified element from this YMap.
   *
   * @param {string} key The key of the element to remove.
   */
  delete(key) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeMapDelete(transaction, this, key);
      });
    } else {
      this._prelimContent.delete(key);
    }
  }
  /**
   * Adds or updates an element with a specified key and value.
   * @template {MapType} VAL
   *
   * @param {string} key The key of the element to add to this YMap
   * @param {VAL} value The value of the element to add
   * @return {VAL}
   */
  set(key, value) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeMapSet(
          transaction,
          this,
          key,
          /** @type {any} */
          value
        );
      });
    } else {
      this._prelimContent.set(key, value);
    }
    return value;
  }
  /**
   * Returns a specified element from this YMap.
   *
   * @param {string} key
   * @return {MapType|undefined}
   */
  get(key) {
    return (
      /** @type {any} */
      typeMapGet(this, key)
    );
  }
  /**
   * Returns a boolean indicating whether the specified key exists or not.
   *
   * @param {string} key The key to test.
   * @return {boolean}
   */
  has(key) {
    return typeMapHas(this, key);
  }
  /**
   * Removes all elements from this YMap.
   */
  clear() {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        this.forEach(function(_value, key, map2) {
          typeMapDelete(transaction, map2, key);
        });
      });
    } else {
      this._prelimContent.clear();
    }
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   */
  _write(encoder) {
    encoder.writeTypeRef(YMapRefID);
  }
};
var readYMap = (_decoder) => new YMap();
var equalAttrs = (a3, b) => a3 === b || typeof a3 === "object" && typeof b === "object" && a3 && b && equalFlat(a3, b);
var ItemTextListPosition = class {
  /**
   * @param {Item|null} left
   * @param {Item|null} right
   * @param {number} index
   * @param {Map<string,any>} currentAttributes
   */
  constructor(left, right, index, currentAttributes) {
    this.left = left;
    this.right = right;
    this.index = index;
    this.currentAttributes = currentAttributes;
  }
  /**
   * Only call this if you know that this.right is defined
   */
  forward() {
    if (this.right === null) {
      unexpectedCase();
    }
    switch (this.right.content.constructor) {
      case ContentFormat:
        if (!this.right.deleted) {
          updateCurrentAttributes(
            this.currentAttributes,
            /** @type {ContentFormat} */
            this.right.content
          );
        }
        break;
      default:
        if (!this.right.deleted) {
          this.index += this.right.length;
        }
        break;
    }
    this.left = this.right;
    this.right = this.right.right;
  }
};
var findNextPosition = (transaction, pos, count2) => {
  while (pos.right !== null && count2 > 0) {
    switch (pos.right.content.constructor) {
      case ContentFormat:
        if (!pos.right.deleted) {
          updateCurrentAttributes(
            pos.currentAttributes,
            /** @type {ContentFormat} */
            pos.right.content
          );
        }
        break;
      default:
        if (!pos.right.deleted) {
          if (count2 < pos.right.length) {
            getItemCleanStart(transaction, createID(pos.right.id.client, pos.right.id.clock + count2));
          }
          pos.index += pos.right.length;
          count2 -= pos.right.length;
        }
        break;
    }
    pos.left = pos.right;
    pos.right = pos.right.right;
  }
  return pos;
};
var findPosition = (transaction, parent, index, useSearchMarker) => {
  const currentAttributes = /* @__PURE__ */ new Map();
  const marker = useSearchMarker ? findMarker(parent, index) : null;
  if (marker) {
    const pos = new ItemTextListPosition(marker.p.left, marker.p, marker.index, currentAttributes);
    return findNextPosition(transaction, pos, index - marker.index);
  } else {
    const pos = new ItemTextListPosition(null, parent._start, 0, currentAttributes);
    return findNextPosition(transaction, pos, index);
  }
};
var insertNegatedAttributes = (transaction, parent, currPos, negatedAttributes) => {
  while (currPos.right !== null && (currPos.right.deleted === true || currPos.right.content.constructor === ContentFormat && equalAttrs(
    negatedAttributes.get(
      /** @type {ContentFormat} */
      currPos.right.content.key
    ),
    /** @type {ContentFormat} */
    currPos.right.content.value
  ))) {
    if (!currPos.right.deleted) {
      negatedAttributes.delete(
        /** @type {ContentFormat} */
        currPos.right.content.key
      );
    }
    currPos.forward();
  }
  const doc2 = transaction.doc;
  const ownClientId = doc2.clientID;
  negatedAttributes.forEach((val, key) => {
    const left = currPos.left;
    const right = currPos.right;
    const nextFormat = new Item(createID(ownClientId, getState(doc2.store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, new ContentFormat(key, val));
    nextFormat.integrate(transaction, 0);
    currPos.right = nextFormat;
    currPos.forward();
  });
};
var updateCurrentAttributes = (currentAttributes, format) => {
  const { key, value } = format;
  if (value === null) {
    currentAttributes.delete(key);
  } else {
    currentAttributes.set(key, value);
  }
};
var minimizeAttributeChanges = (currPos, attributes) => {
  while (true) {
    if (currPos.right === null) {
      break;
    } else if (currPos.right.deleted || currPos.right.content.constructor === ContentFormat && equalAttrs(
      attributes[
        /** @type {ContentFormat} */
        currPos.right.content.key
      ] ?? null,
      /** @type {ContentFormat} */
      currPos.right.content.value
    )) ;
    else {
      break;
    }
    currPos.forward();
  }
};
var insertAttributes = (transaction, parent, currPos, attributes) => {
  const doc2 = transaction.doc;
  const ownClientId = doc2.clientID;
  const negatedAttributes = /* @__PURE__ */ new Map();
  for (const key in attributes) {
    const val = attributes[key];
    const currentVal = currPos.currentAttributes.get(key) ?? null;
    if (!equalAttrs(currentVal, val)) {
      negatedAttributes.set(key, currentVal);
      const { left, right } = currPos;
      currPos.right = new Item(createID(ownClientId, getState(doc2.store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, new ContentFormat(key, val));
      currPos.right.integrate(transaction, 0);
      currPos.forward();
    }
  }
  return negatedAttributes;
};
var insertText = (transaction, parent, currPos, text2, attributes) => {
  currPos.currentAttributes.forEach((_val, key) => {
    if (attributes[key] === void 0) {
      attributes[key] = null;
    }
  });
  const doc2 = transaction.doc;
  const ownClientId = doc2.clientID;
  minimizeAttributeChanges(currPos, attributes);
  const negatedAttributes = insertAttributes(transaction, parent, currPos, attributes);
  const content = text2.constructor === String ? new ContentString(
    /** @type {string} */
    text2
  ) : text2 instanceof AbstractType ? new ContentType(text2) : new ContentEmbed(text2);
  let { left, right, index } = currPos;
  if (parent._searchMarker) {
    updateMarkerChanges(parent._searchMarker, currPos.index, content.getLength());
  }
  right = new Item(createID(ownClientId, getState(doc2.store, ownClientId)), left, left && left.lastId, right, right && right.id, parent, null, content);
  right.integrate(transaction, 0);
  currPos.right = right;
  currPos.index = index;
  currPos.forward();
  insertNegatedAttributes(transaction, parent, currPos, negatedAttributes);
};
var formatText = (transaction, parent, currPos, length2, attributes) => {
  const doc2 = transaction.doc;
  const ownClientId = doc2.clientID;
  minimizeAttributeChanges(currPos, attributes);
  const negatedAttributes = insertAttributes(transaction, parent, currPos, attributes);
  iterationLoop: while (currPos.right !== null && (length2 > 0 || negatedAttributes.size > 0 && (currPos.right.deleted || currPos.right.content.constructor === ContentFormat))) {
    if (!currPos.right.deleted) {
      switch (currPos.right.content.constructor) {
        case ContentFormat: {
          const { key, value } = (
            /** @type {ContentFormat} */
            currPos.right.content
          );
          const attr = attributes[key];
          if (attr !== void 0) {
            if (equalAttrs(attr, value)) {
              negatedAttributes.delete(key);
            } else {
              if (length2 === 0) {
                break iterationLoop;
              }
              negatedAttributes.set(key, value);
            }
            currPos.right.delete(transaction);
          } else {
            currPos.currentAttributes.set(key, value);
          }
          break;
        }
        default:
          if (length2 < currPos.right.length) {
            getItemCleanStart(transaction, createID(currPos.right.id.client, currPos.right.id.clock + length2));
          }
          length2 -= currPos.right.length;
          break;
      }
    }
    currPos.forward();
  }
  if (length2 > 0) {
    let newlines = "";
    for (; length2 > 0; length2--) {
      newlines += "\n";
    }
    currPos.right = new Item(createID(ownClientId, getState(doc2.store, ownClientId)), currPos.left, currPos.left && currPos.left.lastId, currPos.right, currPos.right && currPos.right.id, parent, null, new ContentString(newlines));
    currPos.right.integrate(transaction, 0);
    currPos.forward();
  }
  insertNegatedAttributes(transaction, parent, currPos, negatedAttributes);
};
var cleanupFormattingGap = (transaction, start2, curr, startAttributes, currAttributes) => {
  let end = start2;
  const endFormats = create();
  while (end && (!end.countable || end.deleted)) {
    if (!end.deleted && end.content.constructor === ContentFormat) {
      const cf = (
        /** @type {ContentFormat} */
        end.content
      );
      endFormats.set(cf.key, cf);
    }
    end = end.right;
  }
  let cleanups = 0;
  let reachedCurr = false;
  while (start2 !== end) {
    if (curr === start2) {
      reachedCurr = true;
    }
    if (!start2.deleted) {
      const content = start2.content;
      switch (content.constructor) {
        case ContentFormat: {
          const { key, value } = (
            /** @type {ContentFormat} */
            content
          );
          const startAttrValue = startAttributes.get(key) ?? null;
          if (endFormats.get(key) !== content || startAttrValue === value) {
            start2.delete(transaction);
            cleanups++;
            if (!reachedCurr && (currAttributes.get(key) ?? null) === value && startAttrValue !== value) {
              if (startAttrValue === null) {
                currAttributes.delete(key);
              } else {
                currAttributes.set(key, startAttrValue);
              }
            }
          }
          if (!reachedCurr && !start2.deleted) {
            updateCurrentAttributes(
              currAttributes,
              /** @type {ContentFormat} */
              content
            );
          }
          break;
        }
      }
    }
    start2 = /** @type {Item} */
    start2.right;
  }
  return cleanups;
};
var cleanupContextlessFormattingGap = (transaction, item) => {
  while (item && item.right && (item.right.deleted || !item.right.countable)) {
    item = item.right;
  }
  const attrs = /* @__PURE__ */ new Set();
  while (item && (item.deleted || !item.countable)) {
    if (!item.deleted && item.content.constructor === ContentFormat) {
      const key = (
        /** @type {ContentFormat} */
        item.content.key
      );
      if (attrs.has(key)) {
        item.delete(transaction);
      } else {
        attrs.add(key);
      }
    }
    item = item.left;
  }
};
var cleanupYTextFormatting = (type) => {
  let res = 0;
  transact(
    /** @type {Doc} */
    type.doc,
    (transaction) => {
      let start2 = (
        /** @type {Item} */
        type._start
      );
      let end = type._start;
      let startAttributes = create();
      const currentAttributes = copy(startAttributes);
      while (end) {
        if (end.deleted === false) {
          switch (end.content.constructor) {
            case ContentFormat:
              updateCurrentAttributes(
                currentAttributes,
                /** @type {ContentFormat} */
                end.content
              );
              break;
            default:
              res += cleanupFormattingGap(transaction, start2, end, startAttributes, currentAttributes);
              startAttributes = copy(currentAttributes);
              start2 = end;
              break;
          }
        }
        end = end.right;
      }
    }
  );
  return res;
};
var cleanupYTextAfterTransaction = (transaction) => {
  const needFullCleanup = /* @__PURE__ */ new Set();
  const doc2 = transaction.doc;
  for (const [client, afterClock] of transaction.afterState.entries()) {
    const clock = transaction.beforeState.get(client) || 0;
    if (afterClock === clock) {
      continue;
    }
    iterateStructs(
      transaction,
      /** @type {Array<Item|GC>} */
      doc2.store.clients.get(client),
      clock,
      afterClock,
      (item) => {
        if (!item.deleted && /** @type {Item} */
        item.content.constructor === ContentFormat && item.constructor !== GC) {
          needFullCleanup.add(
            /** @type {any} */
            item.parent
          );
        }
      }
    );
  }
  transact(doc2, (t) => {
    iterateDeletedStructs(transaction, transaction.deleteSet, (item) => {
      if (item instanceof GC || !/** @type {YText} */
      item.parent._hasFormatting || needFullCleanup.has(
        /** @type {YText} */
        item.parent
      )) {
        return;
      }
      const parent = (
        /** @type {YText} */
        item.parent
      );
      if (item.content.constructor === ContentFormat) {
        needFullCleanup.add(parent);
      } else {
        cleanupContextlessFormattingGap(t, item);
      }
    });
    for (const yText of needFullCleanup) {
      cleanupYTextFormatting(yText);
    }
  });
};
var deleteText = (transaction, currPos, length2) => {
  const startLength = length2;
  const startAttrs = copy(currPos.currentAttributes);
  const start2 = currPos.right;
  while (length2 > 0 && currPos.right !== null) {
    if (currPos.right.deleted === false) {
      switch (currPos.right.content.constructor) {
        case ContentType:
        case ContentEmbed:
        case ContentString:
          if (length2 < currPos.right.length) {
            getItemCleanStart(transaction, createID(currPos.right.id.client, currPos.right.id.clock + length2));
          }
          length2 -= currPos.right.length;
          currPos.right.delete(transaction);
          break;
      }
    }
    currPos.forward();
  }
  if (start2) {
    cleanupFormattingGap(transaction, start2, currPos.right, startAttrs, currPos.currentAttributes);
  }
  const parent = (
    /** @type {AbstractType<any>} */
    /** @type {Item} */
    (currPos.left || currPos.right).parent
  );
  if (parent._searchMarker) {
    updateMarkerChanges(parent._searchMarker, currPos.index, -startLength + length2);
  }
  return currPos;
};
var YTextEvent = class extends YEvent {
  /**
   * @param {YText} ytext
   * @param {Transaction} transaction
   * @param {Set<any>} subs The keys that changed
   */
  constructor(ytext, transaction, subs) {
    super(ytext, transaction);
    this.childListChanged = false;
    this.keysChanged = /* @__PURE__ */ new Set();
    subs.forEach((sub) => {
      if (sub === null) {
        this.childListChanged = true;
      } else {
        this.keysChanged.add(sub);
      }
    });
  }
  /**
   * @type {{added:Set<Item>,deleted:Set<Item>,keys:Map<string,{action:'add'|'update'|'delete',oldValue:any}>,delta:Array<{insert?:Array<any>|string, delete?:number, retain?:number}>}}
   */
  get changes() {
    if (this._changes === null) {
      const changes2 = {
        keys: this.keys,
        delta: this.delta,
        added: /* @__PURE__ */ new Set(),
        deleted: /* @__PURE__ */ new Set()
      };
      this._changes = changes2;
    }
    return (
      /** @type {any} */
      this._changes
    );
  }
  /**
   * Compute the changes in the delta format.
   * A {@link https://quilljs.com/docs/delta/|Quill Delta}) that represents the changes on the document.
   *
   * @type {Array<{insert?:string|object|AbstractType<any>, delete?:number, retain?:number, attributes?: Object<string,any>}>}
   *
   * @public
   */
  get delta() {
    if (this._delta === null) {
      const y2 = (
        /** @type {Doc} */
        this.target.doc
      );
      const delta = [];
      transact(y2, (transaction) => {
        const currentAttributes = /* @__PURE__ */ new Map();
        const oldAttributes = /* @__PURE__ */ new Map();
        let item = this.target._start;
        let action = null;
        const attributes = {};
        let insert = "";
        let retain = 0;
        let deleteLen = 0;
        const addOp = () => {
          if (action !== null) {
            let op = null;
            switch (action) {
              case "delete":
                if (deleteLen > 0) {
                  op = { delete: deleteLen };
                }
                deleteLen = 0;
                break;
              case "insert":
                if (typeof insert === "object" || insert.length > 0) {
                  op = { insert };
                  if (currentAttributes.size > 0) {
                    op.attributes = {};
                    currentAttributes.forEach((value, key) => {
                      if (value !== null) {
                        op.attributes[key] = value;
                      }
                    });
                  }
                }
                insert = "";
                break;
              case "retain":
                if (retain > 0) {
                  op = { retain };
                  if (!isEmpty(attributes)) {
                    op.attributes = assign({}, attributes);
                  }
                }
                retain = 0;
                break;
            }
            if (op) delta.push(op);
            action = null;
          }
        };
        while (item !== null) {
          switch (item.content.constructor) {
            case ContentType:
            case ContentEmbed:
              if (this.adds(item)) {
                if (!this.deletes(item)) {
                  addOp();
                  action = "insert";
                  insert = item.content.getContent()[0];
                  addOp();
                }
              } else if (this.deletes(item)) {
                if (action !== "delete") {
                  addOp();
                  action = "delete";
                }
                deleteLen += 1;
              } else if (!item.deleted) {
                if (action !== "retain") {
                  addOp();
                  action = "retain";
                }
                retain += 1;
              }
              break;
            case ContentString:
              if (this.adds(item)) {
                if (!this.deletes(item)) {
                  if (action !== "insert") {
                    addOp();
                    action = "insert";
                  }
                  insert += /** @type {ContentString} */
                  item.content.str;
                }
              } else if (this.deletes(item)) {
                if (action !== "delete") {
                  addOp();
                  action = "delete";
                }
                deleteLen += item.length;
              } else if (!item.deleted) {
                if (action !== "retain") {
                  addOp();
                  action = "retain";
                }
                retain += item.length;
              }
              break;
            case ContentFormat: {
              const { key, value } = (
                /** @type {ContentFormat} */
                item.content
              );
              if (this.adds(item)) {
                if (!this.deletes(item)) {
                  const curVal = currentAttributes.get(key) ?? null;
                  if (!equalAttrs(curVal, value)) {
                    if (action === "retain") {
                      addOp();
                    }
                    if (equalAttrs(value, oldAttributes.get(key) ?? null)) {
                      delete attributes[key];
                    } else {
                      attributes[key] = value;
                    }
                  } else if (value !== null) {
                    item.delete(transaction);
                  }
                }
              } else if (this.deletes(item)) {
                oldAttributes.set(key, value);
                const curVal = currentAttributes.get(key) ?? null;
                if (!equalAttrs(curVal, value)) {
                  if (action === "retain") {
                    addOp();
                  }
                  attributes[key] = curVal;
                }
              } else if (!item.deleted) {
                oldAttributes.set(key, value);
                const attr = attributes[key];
                if (attr !== void 0) {
                  if (!equalAttrs(attr, value)) {
                    if (action === "retain") {
                      addOp();
                    }
                    if (value === null) {
                      delete attributes[key];
                    } else {
                      attributes[key] = value;
                    }
                  } else if (attr !== null) {
                    item.delete(transaction);
                  }
                }
              }
              if (!item.deleted) {
                if (action === "insert") {
                  addOp();
                }
                updateCurrentAttributes(
                  currentAttributes,
                  /** @type {ContentFormat} */
                  item.content
                );
              }
              break;
            }
          }
          item = item.right;
        }
        addOp();
        while (delta.length > 0) {
          const lastOp = delta[delta.length - 1];
          if (lastOp.retain !== void 0 && lastOp.attributes === void 0) {
            delta.pop();
          } else {
            break;
          }
        }
      });
      this._delta = delta;
    }
    return (
      /** @type {any} */
      this._delta
    );
  }
};
var YText = class _YText extends AbstractType {
  /**
   * @param {String} [string] The initial value of the YText.
   */
  constructor(string) {
    super();
    this._pending = string !== void 0 ? [() => this.insert(0, string)] : [];
    this._searchMarker = [];
    this._hasFormatting = false;
  }
  /**
   * Number of characters of this text type.
   *
   * @type {number}
   */
  get length() {
    this.doc ?? warnPrematureAccess();
    return this._length;
  }
  /**
   * @param {Doc} y
   * @param {Item} item
   */
  _integrate(y2, item) {
    super._integrate(y2, item);
    try {
      this._pending.forEach((f2) => f2());
    } catch (e) {
      console.error(e);
    }
    this._pending = null;
  }
  _copy() {
    return new _YText();
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YText}
   */
  clone() {
    const text2 = new _YText();
    text2.applyDelta(this.toDelta());
    return text2;
  }
  /**
   * Creates YTextEvent and calls observers.
   *
   * @param {Transaction} transaction
   * @param {Set<null|string>} parentSubs Keys changed on this type. `null` if list was modified.
   */
  _callObserver(transaction, parentSubs) {
    super._callObserver(transaction, parentSubs);
    const event = new YTextEvent(this, transaction, parentSubs);
    callTypeObservers(this, transaction, event);
    if (!transaction.local && this._hasFormatting) {
      transaction._needFormattingCleanup = true;
    }
  }
  /**
   * Returns the unformatted string representation of this YText type.
   *
   * @public
   */
  toString() {
    this.doc ?? warnPrematureAccess();
    let str = "";
    let n = this._start;
    while (n !== null) {
      if (!n.deleted && n.countable && n.content.constructor === ContentString) {
        str += /** @type {ContentString} */
        n.content.str;
      }
      n = n.right;
    }
    return str;
  }
  /**
   * Returns the unformatted string representation of this YText type.
   *
   * @return {string}
   * @public
   */
  toJSON() {
    return this.toString();
  }
  /**
   * Apply a {@link Delta} on this shared YText type.
   *
   * @param {Array<any>} delta The changes to apply on this element.
   * @param {object}  opts
   * @param {boolean} [opts.sanitize] Sanitize input delta. Removes ending newlines if set to true.
   *
   *
   * @public
   */
  applyDelta(delta, { sanitize = true } = {}) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        const currPos = new ItemTextListPosition(null, this._start, 0, /* @__PURE__ */ new Map());
        for (let i = 0; i < delta.length; i++) {
          const op = delta[i];
          if (op.insert !== void 0) {
            const ins = !sanitize && typeof op.insert === "string" && i === delta.length - 1 && currPos.right === null && op.insert.slice(-1) === "\n" ? op.insert.slice(0, -1) : op.insert;
            if (typeof ins !== "string" || ins.length > 0) {
              insertText(transaction, this, currPos, ins, op.attributes || {});
            }
          } else if (op.retain !== void 0) {
            formatText(transaction, this, currPos, op.retain, op.attributes || {});
          } else if (op.delete !== void 0) {
            deleteText(transaction, currPos, op.delete);
          }
        }
      });
    } else {
      this._pending.push(() => this.applyDelta(delta));
    }
  }
  /**
   * Returns the Delta representation of this YText type.
   *
   * @param {Snapshot} [snapshot]
   * @param {Snapshot} [prevSnapshot]
   * @param {function('removed' | 'added', ID):any} [computeYChange]
   * @return {any} The Delta representation of this type.
   *
   * @public
   */
  toDelta(snapshot, prevSnapshot, computeYChange) {
    this.doc ?? warnPrematureAccess();
    const ops = [];
    const currentAttributes = /* @__PURE__ */ new Map();
    const doc2 = (
      /** @type {Doc} */
      this.doc
    );
    let str = "";
    let n = this._start;
    function packStr() {
      if (str.length > 0) {
        const attributes = {};
        let addAttributes = false;
        currentAttributes.forEach((value, key) => {
          addAttributes = true;
          attributes[key] = value;
        });
        const op = { insert: str };
        if (addAttributes) {
          op.attributes = attributes;
        }
        ops.push(op);
        str = "";
      }
    }
    const computeDelta = () => {
      while (n !== null) {
        if (isVisible(n, snapshot) || prevSnapshot !== void 0 && isVisible(n, prevSnapshot)) {
          switch (n.content.constructor) {
            case ContentString: {
              const cur = currentAttributes.get("ychange");
              if (snapshot !== void 0 && !isVisible(n, snapshot)) {
                if (cur === void 0 || cur.user !== n.id.client || cur.type !== "removed") {
                  packStr();
                  currentAttributes.set("ychange", computeYChange ? computeYChange("removed", n.id) : { type: "removed" });
                }
              } else if (prevSnapshot !== void 0 && !isVisible(n, prevSnapshot)) {
                if (cur === void 0 || cur.user !== n.id.client || cur.type !== "added") {
                  packStr();
                  currentAttributes.set("ychange", computeYChange ? computeYChange("added", n.id) : { type: "added" });
                }
              } else if (cur !== void 0) {
                packStr();
                currentAttributes.delete("ychange");
              }
              str += /** @type {ContentString} */
              n.content.str;
              break;
            }
            case ContentType:
            case ContentEmbed: {
              packStr();
              const op = {
                insert: n.content.getContent()[0]
              };
              if (currentAttributes.size > 0) {
                const attrs = (
                  /** @type {Object<string,any>} */
                  {}
                );
                op.attributes = attrs;
                currentAttributes.forEach((value, key) => {
                  attrs[key] = value;
                });
              }
              ops.push(op);
              break;
            }
            case ContentFormat:
              if (isVisible(n, snapshot)) {
                packStr();
                updateCurrentAttributes(
                  currentAttributes,
                  /** @type {ContentFormat} */
                  n.content
                );
              }
              break;
          }
        }
        n = n.right;
      }
      packStr();
    };
    if (snapshot || prevSnapshot) {
      transact(doc2, (transaction) => {
        if (snapshot) {
          splitSnapshotAffectedStructs(transaction, snapshot);
        }
        if (prevSnapshot) {
          splitSnapshotAffectedStructs(transaction, prevSnapshot);
        }
        computeDelta();
      }, "cleanup");
    } else {
      computeDelta();
    }
    return ops;
  }
  /**
   * Insert text at a given index.
   *
   * @param {number} index The index at which to start inserting.
   * @param {String} text The text to insert at the specified position.
   * @param {TextAttributes} [attributes] Optionally define some formatting
   *                                    information to apply on the inserted
   *                                    Text.
   * @public
   */
  insert(index, text2, attributes) {
    if (text2.length <= 0) {
      return;
    }
    const y2 = this.doc;
    if (y2 !== null) {
      transact(y2, (transaction) => {
        const pos = findPosition(transaction, this, index, !attributes);
        if (!attributes) {
          attributes = {};
          pos.currentAttributes.forEach((v2, k) => {
            attributes[k] = v2;
          });
        }
        insertText(transaction, this, pos, text2, attributes);
      });
    } else {
      this._pending.push(() => this.insert(index, text2, attributes));
    }
  }
  /**
   * Inserts an embed at a index.
   *
   * @param {number} index The index to insert the embed at.
   * @param {Object | AbstractType<any>} embed The Object that represents the embed.
   * @param {TextAttributes} [attributes] Attribute information to apply on the
   *                                    embed
   *
   * @public
   */
  insertEmbed(index, embed, attributes) {
    const y2 = this.doc;
    if (y2 !== null) {
      transact(y2, (transaction) => {
        const pos = findPosition(transaction, this, index, !attributes);
        insertText(transaction, this, pos, embed, attributes || {});
      });
    } else {
      this._pending.push(() => this.insertEmbed(index, embed, attributes || {}));
    }
  }
  /**
   * Deletes text starting from an index.
   *
   * @param {number} index Index at which to start deleting.
   * @param {number} length The number of characters to remove. Defaults to 1.
   *
   * @public
   */
  delete(index, length2) {
    if (length2 === 0) {
      return;
    }
    const y2 = this.doc;
    if (y2 !== null) {
      transact(y2, (transaction) => {
        deleteText(transaction, findPosition(transaction, this, index, true), length2);
      });
    } else {
      this._pending.push(() => this.delete(index, length2));
    }
  }
  /**
   * Assigns properties to a range of text.
   *
   * @param {number} index The position where to start formatting.
   * @param {number} length The amount of characters to assign properties to.
   * @param {TextAttributes} attributes Attribute information to apply on the
   *                                    text.
   *
   * @public
   */
  format(index, length2, attributes) {
    if (length2 === 0) {
      return;
    }
    const y2 = this.doc;
    if (y2 !== null) {
      transact(y2, (transaction) => {
        const pos = findPosition(transaction, this, index, false);
        if (pos.right === null) {
          return;
        }
        formatText(transaction, this, pos, length2, attributes);
      });
    } else {
      this._pending.push(() => this.format(index, length2, attributes));
    }
  }
  /**
   * Removes an attribute.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @param {String} attributeName The attribute name that is to be removed.
   *
   * @public
   */
  removeAttribute(attributeName) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeMapDelete(transaction, this, attributeName);
      });
    } else {
      this._pending.push(() => this.removeAttribute(attributeName));
    }
  }
  /**
   * Sets or updates an attribute.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @param {String} attributeName The attribute name that is to be set.
   * @param {any} attributeValue The attribute value that is to be set.
   *
   * @public
   */
  setAttribute(attributeName, attributeValue) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeMapSet(transaction, this, attributeName, attributeValue);
      });
    } else {
      this._pending.push(() => this.setAttribute(attributeName, attributeValue));
    }
  }
  /**
   * Returns an attribute value that belongs to the attribute name.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @param {String} attributeName The attribute name that identifies the
   *                               queried value.
   * @return {any} The queried attribute value.
   *
   * @public
   */
  getAttribute(attributeName) {
    return (
      /** @type {any} */
      typeMapGet(this, attributeName)
    );
  }
  /**
   * Returns all attribute name/value pairs in a JSON Object.
   *
   * @note Xml-Text nodes don't have attributes. You can use this feature to assign properties to complete text-blocks.
   *
   * @return {Object<string, any>} A JSON Object that describes the attributes.
   *
   * @public
   */
  getAttributes() {
    return typeMapGetAll(this);
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   */
  _write(encoder) {
    encoder.writeTypeRef(YTextRefID);
  }
};
var readYText = (_decoder) => new YText();
var YXmlTreeWalker = class {
  /**
   * @param {YXmlFragment | YXmlElement} root
   * @param {function(AbstractType<any>):boolean} [f]
   */
  constructor(root, f2 = () => true) {
    this._filter = f2;
    this._root = root;
    this._currentNode = /** @type {Item} */
    root._start;
    this._firstCall = true;
    root.doc ?? warnPrematureAccess();
  }
  [Symbol.iterator]() {
    return this;
  }
  /**
   * Get the next node.
   *
   * @return {IteratorResult<YXmlElement|YXmlText|YXmlHook>} The next node.
   *
   * @public
   */
  next() {
    let n = this._currentNode;
    let type = n && n.content && /** @type {any} */
    n.content.type;
    if (n !== null && (!this._firstCall || n.deleted || !this._filter(type))) {
      do {
        type = /** @type {any} */
        n.content.type;
        if (!n.deleted && (type.constructor === YXmlElement || type.constructor === YXmlFragment) && type._start !== null) {
          n = type._start;
        } else {
          while (n !== null) {
            const nxt = n.next;
            if (nxt !== null) {
              n = nxt;
              break;
            } else if (n.parent === this._root) {
              n = null;
            } else {
              n = /** @type {AbstractType<any>} */
              n.parent._item;
            }
          }
        }
      } while (n !== null && (n.deleted || !this._filter(
        /** @type {ContentType} */
        n.content.type
      )));
    }
    this._firstCall = false;
    if (n === null) {
      return { value: void 0, done: true };
    }
    this._currentNode = n;
    return { value: (
      /** @type {any} */
      n.content.type
    ), done: false };
  }
};
var YXmlFragment = class _YXmlFragment extends AbstractType {
  constructor() {
    super();
    this._prelimContent = [];
  }
  /**
   * @type {YXmlElement|YXmlText|null}
   */
  get firstChild() {
    const first = this._first;
    return first ? first.content.getContent()[0] : null;
  }
  /**
   * Integrate this type into the Yjs instance.
   *
   * * Save this struct in the os
   * * This type is sent to other client
   * * Observer functions are fired
   *
   * @param {Doc} y The Yjs instance
   * @param {Item} item
   */
  _integrate(y2, item) {
    super._integrate(y2, item);
    this.insert(
      0,
      /** @type {Array<any>} */
      this._prelimContent
    );
    this._prelimContent = null;
  }
  _copy() {
    return new _YXmlFragment();
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YXmlFragment}
   */
  clone() {
    const el = new _YXmlFragment();
    el.insert(0, this.toArray().map((item) => item instanceof AbstractType ? item.clone() : item));
    return el;
  }
  get length() {
    this.doc ?? warnPrematureAccess();
    return this._prelimContent === null ? this._length : this._prelimContent.length;
  }
  /**
   * Create a subtree of childNodes.
   *
   * @example
   * const walker = elem.createTreeWalker(dom => dom.nodeName === 'div')
   * for (let node in walker) {
   *   // `node` is a div node
   *   nop(node)
   * }
   *
   * @param {function(AbstractType<any>):boolean} filter Function that is called on each child element and
   *                          returns a Boolean indicating whether the child
   *                          is to be included in the subtree.
   * @return {YXmlTreeWalker} A subtree and a position within it.
   *
   * @public
   */
  createTreeWalker(filter) {
    return new YXmlTreeWalker(this, filter);
  }
  /**
   * Returns the first YXmlElement that matches the query.
   * Similar to DOM's {@link querySelector}.
   *
   * Query support:
   *   - tagname
   * TODO:
   *   - id
   *   - attribute
   *
   * @param {CSS_Selector} query The query on the children.
   * @return {YXmlElement|YXmlText|YXmlHook|null} The first element that matches the query or null.
   *
   * @public
   */
  querySelector(query2) {
    query2 = query2.toUpperCase();
    const iterator = new YXmlTreeWalker(this, (element2) => element2.nodeName && element2.nodeName.toUpperCase() === query2);
    const next = iterator.next();
    if (next.done) {
      return null;
    } else {
      return next.value;
    }
  }
  /**
   * Returns all YXmlElements that match the query.
   * Similar to Dom's {@link querySelectorAll}.
   *
   * @todo Does not yet support all queries. Currently only query by tagName.
   *
   * @param {CSS_Selector} query The query on the children
   * @return {Array<YXmlElement|YXmlText|YXmlHook|null>} The elements that match this query.
   *
   * @public
   */
  querySelectorAll(query2) {
    query2 = query2.toUpperCase();
    return from(new YXmlTreeWalker(this, (element2) => element2.nodeName && element2.nodeName.toUpperCase() === query2));
  }
  /**
   * Creates YXmlEvent and calls observers.
   *
   * @param {Transaction} transaction
   * @param {Set<null|string>} parentSubs Keys changed on this type. `null` if list was modified.
   */
  _callObserver(transaction, parentSubs) {
    callTypeObservers(this, transaction, new YXmlEvent(this, parentSubs, transaction));
  }
  /**
   * Get the string representation of all the children of this YXmlFragment.
   *
   * @return {string} The string representation of all children.
   */
  toString() {
    return typeListMap(this, (xml) => xml.toString()).join("");
  }
  /**
   * @return {string}
   */
  toJSON() {
    return this.toString();
  }
  /**
   * Creates a Dom Element that mirrors this YXmlElement.
   *
   * @param {Document} [_document=document] The document object (you must define
   *                                        this when calling this method in
   *                                        nodejs)
   * @param {Object<string, any>} [hooks={}] Optional property to customize how hooks
   *                                             are presented in the DOM
   * @param {any} [binding] You should not set this property. This is
   *                               used if DomBinding wants to create a
   *                               association to the created DOM type.
   * @return {Node} The {@link https://developer.mozilla.org/en-US/docs/Web/API/Element|Dom Element}
   *
   * @public
   */
  toDOM(_document = document, hooks = {}, binding2) {
    const fragment = _document.createDocumentFragment();
    if (binding2 !== void 0) {
      binding2._createAssociation(fragment, this);
    }
    typeListForEach(this, (xmlType) => {
      fragment.insertBefore(xmlType.toDOM(_document, hooks, binding2), null);
    });
    return fragment;
  }
  /**
   * Inserts new content at an index.
   *
   * @example
   *  // Insert character 'a' at position 0
   *  xml.insert(0, [new Y.XmlText('text')])
   *
   * @param {number} index The index to insert content at
   * @param {Array<YXmlElement|YXmlText>} content The array of content
   */
  insert(index, content) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeListInsertGenerics(transaction, this, index, content);
      });
    } else {
      this._prelimContent.splice(index, 0, ...content);
    }
  }
  /**
   * Inserts new content at an index.
   *
   * @example
   *  // Insert character 'a' at position 0
   *  xml.insert(0, [new Y.XmlText('text')])
   *
   * @param {null|Item|YXmlElement|YXmlText} ref The index to insert content at
   * @param {Array<YXmlElement|YXmlText>} content The array of content
   */
  insertAfter(ref, content) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        const refItem = ref && ref instanceof AbstractType ? ref._item : ref;
        typeListInsertGenericsAfter(transaction, this, refItem, content);
      });
    } else {
      const pc = (
        /** @type {Array<any>} */
        this._prelimContent
      );
      const index = ref === null ? 0 : pc.findIndex((el) => el === ref) + 1;
      if (index === 0 && ref !== null) {
        throw create3("Reference item not found");
      }
      pc.splice(index, 0, ...content);
    }
  }
  /**
   * Deletes elements starting from an index.
   *
   * @param {number} index Index at which to start deleting elements
   * @param {number} [length=1] The number of elements to remove. Defaults to 1.
   */
  delete(index, length2 = 1) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeListDelete(transaction, this, index, length2);
      });
    } else {
      this._prelimContent.splice(index, length2);
    }
  }
  /**
   * Transforms this YArray to a JavaScript Array.
   *
   * @return {Array<YXmlElement|YXmlText|YXmlHook>}
   */
  toArray() {
    return typeListToArray(this);
  }
  /**
   * Appends content to this YArray.
   *
   * @param {Array<YXmlElement|YXmlText>} content Array of content to append.
   */
  push(content) {
    this.insert(this.length, content);
  }
  /**
   * Prepends content to this YArray.
   *
   * @param {Array<YXmlElement|YXmlText>} content Array of content to prepend.
   */
  unshift(content) {
    this.insert(0, content);
  }
  /**
   * Returns the i-th element from a YArray.
   *
   * @param {number} index The index of the element to return from the YArray
   * @return {YXmlElement|YXmlText}
   */
  get(index) {
    return typeListGet(this, index);
  }
  /**
   * Returns a portion of this YXmlFragment into a JavaScript Array selected
   * from start to end (end not included).
   *
   * @param {number} [start]
   * @param {number} [end]
   * @return {Array<YXmlElement|YXmlText>}
   */
  slice(start2 = 0, end = this.length) {
    return typeListSlice(this, start2, end);
  }
  /**
   * Executes a provided function on once on every child element.
   *
   * @param {function(YXmlElement|YXmlText,number, typeof self):void} f A function to execute on every element of this YArray.
   */
  forEach(f2) {
    typeListForEach(this, f2);
  }
  /**
   * Transform the properties of this type to binary and write it to an
   * BinaryEncoder.
   *
   * This is called when this Item is sent to a remote peer.
   *
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder The encoder to write data to.
   */
  _write(encoder) {
    encoder.writeTypeRef(YXmlFragmentRefID);
  }
};
var readYXmlFragment = (_decoder) => new YXmlFragment();
var YXmlElement = class _YXmlElement extends YXmlFragment {
  constructor(nodeName = "UNDEFINED") {
    super();
    this.nodeName = nodeName;
    this._prelimAttrs = /* @__PURE__ */ new Map();
  }
  /**
   * @type {YXmlElement|YXmlText|null}
   */
  get nextSibling() {
    const n = this._item ? this._item.next : null;
    return n ? (
      /** @type {YXmlElement|YXmlText} */
      /** @type {ContentType} */
      n.content.type
    ) : null;
  }
  /**
   * @type {YXmlElement|YXmlText|null}
   */
  get prevSibling() {
    const n = this._item ? this._item.prev : null;
    return n ? (
      /** @type {YXmlElement|YXmlText} */
      /** @type {ContentType} */
      n.content.type
    ) : null;
  }
  /**
   * Integrate this type into the Yjs instance.
   *
   * * Save this struct in the os
   * * This type is sent to other client
   * * Observer functions are fired
   *
   * @param {Doc} y The Yjs instance
   * @param {Item} item
   */
  _integrate(y2, item) {
    super._integrate(y2, item);
    /** @type {Map<string, any>} */
    this._prelimAttrs.forEach((value, key) => {
      this.setAttribute(key, value);
    });
    this._prelimAttrs = null;
  }
  /**
   * Creates an Item with the same effect as this Item (without position effect)
   *
   * @return {YXmlElement}
   */
  _copy() {
    return new _YXmlElement(this.nodeName);
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YXmlElement<KV>}
   */
  clone() {
    const el = new _YXmlElement(this.nodeName);
    const attrs = this.getAttributes();
    forEach(attrs, (value, key) => {
      el.setAttribute(
        key,
        /** @type {any} */
        value
      );
    });
    el.insert(0, this.toArray().map((v2) => v2 instanceof AbstractType ? v2.clone() : v2));
    return el;
  }
  /**
   * Returns the XML serialization of this YXmlElement.
   * The attributes are ordered by attribute-name, so you can easily use this
   * method to compare YXmlElements
   *
   * @return {string} The string representation of this type.
   *
   * @public
   */
  toString() {
    const attrs = this.getAttributes();
    const stringBuilder = [];
    const keys2 = [];
    for (const key in attrs) {
      keys2.push(key);
    }
    keys2.sort();
    const keysLen = keys2.length;
    for (let i = 0; i < keysLen; i++) {
      const key = keys2[i];
      stringBuilder.push(key + '="' + attrs[key] + '"');
    }
    const nodeName = this.nodeName.toLocaleLowerCase();
    const attrsString = stringBuilder.length > 0 ? " " + stringBuilder.join(" ") : "";
    return `<${nodeName}${attrsString}>${super.toString()}</${nodeName}>`;
  }
  /**
   * Removes an attribute from this YXmlElement.
   *
   * @param {string} attributeName The attribute name that is to be removed.
   *
   * @public
   */
  removeAttribute(attributeName) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeMapDelete(transaction, this, attributeName);
      });
    } else {
      this._prelimAttrs.delete(attributeName);
    }
  }
  /**
   * Sets or updates an attribute.
   *
   * @template {keyof KV & string} KEY
   *
   * @param {KEY} attributeName The attribute name that is to be set.
   * @param {KV[KEY]} attributeValue The attribute value that is to be set.
   *
   * @public
   */
  setAttribute(attributeName, attributeValue) {
    if (this.doc !== null) {
      transact(this.doc, (transaction) => {
        typeMapSet(transaction, this, attributeName, attributeValue);
      });
    } else {
      this._prelimAttrs.set(attributeName, attributeValue);
    }
  }
  /**
   * Returns an attribute value that belongs to the attribute name.
   *
   * @template {keyof KV & string} KEY
   *
   * @param {KEY} attributeName The attribute name that identifies the
   *                               queried value.
   * @return {KV[KEY]|undefined} The queried attribute value.
   *
   * @public
   */
  getAttribute(attributeName) {
    return (
      /** @type {any} */
      typeMapGet(this, attributeName)
    );
  }
  /**
   * Returns whether an attribute exists
   *
   * @param {string} attributeName The attribute name to check for existence.
   * @return {boolean} whether the attribute exists.
   *
   * @public
   */
  hasAttribute(attributeName) {
    return (
      /** @type {any} */
      typeMapHas(this, attributeName)
    );
  }
  /**
   * Returns all attribute name/value pairs in a JSON Object.
   *
   * @param {Snapshot} [snapshot]
   * @return {{ [Key in Extract<keyof KV,string>]?: KV[Key]}} A JSON Object that describes the attributes.
   *
   * @public
   */
  getAttributes(snapshot) {
    return (
      /** @type {any} */
      snapshot ? typeMapGetAllSnapshot(this, snapshot) : typeMapGetAll(this)
    );
  }
  /**
   * Creates a Dom Element that mirrors this YXmlElement.
   *
   * @param {Document} [_document=document] The document object (you must define
   *                                        this when calling this method in
   *                                        nodejs)
   * @param {Object<string, any>} [hooks={}] Optional property to customize how hooks
   *                                             are presented in the DOM
   * @param {any} [binding] You should not set this property. This is
   *                               used if DomBinding wants to create a
   *                               association to the created DOM type.
   * @return {Node} The {@link https://developer.mozilla.org/en-US/docs/Web/API/Element|Dom Element}
   *
   * @public
   */
  toDOM(_document = document, hooks = {}, binding2) {
    const dom = _document.createElement(this.nodeName);
    const attrs = this.getAttributes();
    for (const key in attrs) {
      const value = attrs[key];
      if (typeof value === "string") {
        dom.setAttribute(key, value);
      }
    }
    typeListForEach(this, (yxml) => {
      dom.appendChild(yxml.toDOM(_document, hooks, binding2));
    });
    if (binding2 !== void 0) {
      binding2._createAssociation(dom, this);
    }
    return dom;
  }
  /**
   * Transform the properties of this type to binary and write it to an
   * BinaryEncoder.
   *
   * This is called when this Item is sent to a remote peer.
   *
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder The encoder to write data to.
   */
  _write(encoder) {
    encoder.writeTypeRef(YXmlElementRefID);
    encoder.writeKey(this.nodeName);
  }
};
var readYXmlElement = (decoder) => new YXmlElement(decoder.readKey());
var YXmlEvent = class extends YEvent {
  /**
   * @param {YXmlElement|YXmlText|YXmlFragment} target The target on which the event is created.
   * @param {Set<string|null>} subs The set of changed attributes. `null` is included if the
   *                   child list changed.
   * @param {Transaction} transaction The transaction instance with which the
   *                                  change was created.
   */
  constructor(target, subs, transaction) {
    super(target, transaction);
    this.childListChanged = false;
    this.attributesChanged = /* @__PURE__ */ new Set();
    subs.forEach((sub) => {
      if (sub === null) {
        this.childListChanged = true;
      } else {
        this.attributesChanged.add(sub);
      }
    });
  }
};
var YXmlHook = class _YXmlHook extends YMap {
  /**
   * @param {string} hookName nodeName of the Dom Node.
   */
  constructor(hookName) {
    super();
    this.hookName = hookName;
  }
  /**
   * Creates an Item with the same effect as this Item (without position effect)
   */
  _copy() {
    return new _YXmlHook(this.hookName);
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YXmlHook}
   */
  clone() {
    const el = new _YXmlHook(this.hookName);
    this.forEach((value, key) => {
      el.set(key, value);
    });
    return el;
  }
  /**
   * Creates a Dom Element that mirrors this YXmlElement.
   *
   * @param {Document} [_document=document] The document object (you must define
   *                                        this when calling this method in
   *                                        nodejs)
   * @param {Object.<string, any>} [hooks] Optional property to customize how hooks
   *                                             are presented in the DOM
   * @param {any} [binding] You should not set this property. This is
   *                               used if DomBinding wants to create a
   *                               association to the created DOM type
   * @return {Element} The {@link https://developer.mozilla.org/en-US/docs/Web/API/Element|Dom Element}
   *
   * @public
   */
  toDOM(_document = document, hooks = {}, binding2) {
    const hook = hooks[this.hookName];
    let dom;
    if (hook !== void 0) {
      dom = hook.createDom(this);
    } else {
      dom = document.createElement(this.hookName);
    }
    dom.setAttribute("data-yjs-hook", this.hookName);
    if (binding2 !== void 0) {
      binding2._createAssociation(dom, this);
    }
    return dom;
  }
  /**
   * Transform the properties of this type to binary and write it to an
   * BinaryEncoder.
   *
   * This is called when this Item is sent to a remote peer.
   *
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder The encoder to write data to.
   */
  _write(encoder) {
    encoder.writeTypeRef(YXmlHookRefID);
    encoder.writeKey(this.hookName);
  }
};
var readYXmlHook = (decoder) => new YXmlHook(decoder.readKey());
var YXmlText = class _YXmlText extends YText {
  /**
   * @type {YXmlElement|YXmlText|null}
   */
  get nextSibling() {
    const n = this._item ? this._item.next : null;
    return n ? (
      /** @type {YXmlElement|YXmlText} */
      /** @type {ContentType} */
      n.content.type
    ) : null;
  }
  /**
   * @type {YXmlElement|YXmlText|null}
   */
  get prevSibling() {
    const n = this._item ? this._item.prev : null;
    return n ? (
      /** @type {YXmlElement|YXmlText} */
      /** @type {ContentType} */
      n.content.type
    ) : null;
  }
  _copy() {
    return new _YXmlText();
  }
  /**
   * Makes a copy of this data type that can be included somewhere else.
   *
   * Note that the content is only readable _after_ it has been included somewhere in the Ydoc.
   *
   * @return {YXmlText}
   */
  clone() {
    const text2 = new _YXmlText();
    text2.applyDelta(this.toDelta());
    return text2;
  }
  /**
   * Creates a Dom Element that mirrors this YXmlText.
   *
   * @param {Document} [_document=document] The document object (you must define
   *                                        this when calling this method in
   *                                        nodejs)
   * @param {Object<string, any>} [hooks] Optional property to customize how hooks
   *                                             are presented in the DOM
   * @param {any} [binding] You should not set this property. This is
   *                               used if DomBinding wants to create a
   *                               association to the created DOM type.
   * @return {Text} The {@link https://developer.mozilla.org/en-US/docs/Web/API/Element|Dom Element}
   *
   * @public
   */
  toDOM(_document = document, hooks, binding2) {
    const dom = _document.createTextNode(this.toString());
    if (binding2 !== void 0) {
      binding2._createAssociation(dom, this);
    }
    return dom;
  }
  toString() {
    return this.toDelta().map((delta) => {
      const nestedNodes = [];
      for (const nodeName in delta.attributes) {
        const attrs = [];
        for (const key in delta.attributes[nodeName]) {
          attrs.push({ key, value: delta.attributes[nodeName][key] });
        }
        attrs.sort((a3, b) => a3.key < b.key ? -1 : 1);
        nestedNodes.push({ nodeName, attrs });
      }
      nestedNodes.sort((a3, b) => a3.nodeName < b.nodeName ? -1 : 1);
      let str = "";
      for (let i = 0; i < nestedNodes.length; i++) {
        const node = nestedNodes[i];
        str += `<${node.nodeName}`;
        for (let j2 = 0; j2 < node.attrs.length; j2++) {
          const attr = node.attrs[j2];
          str += ` ${attr.key}="${attr.value}"`;
        }
        str += ">";
      }
      str += delta.insert;
      for (let i = nestedNodes.length - 1; i >= 0; i--) {
        str += `</${nestedNodes[i].nodeName}>`;
      }
      return str;
    }).join("");
  }
  /**
   * @return {string}
   */
  toJSON() {
    return this.toString();
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   */
  _write(encoder) {
    encoder.writeTypeRef(YXmlTextRefID);
  }
};
var readYXmlText = (decoder) => new YXmlText();
var AbstractStruct = class {
  /**
   * @param {ID} id
   * @param {number} length
   */
  constructor(id2, length2) {
    this.id = id2;
    this.length = length2;
  }
  /**
   * @type {boolean}
   */
  get deleted() {
    throw methodUnimplemented();
  }
  /**
   * Merge this struct with the item to the right.
   * This method is already assuming that `this.id.clock + this.length === this.id.clock`.
   * Also this method does *not* remove right from StructStore!
   * @param {AbstractStruct} right
   * @return {boolean} whether this merged with right
   */
  mergeWith(right) {
    return false;
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder The encoder to write data to.
   * @param {number} offset
   * @param {number} encodingRef
   */
  write(encoder, offset, encodingRef) {
    throw methodUnimplemented();
  }
  /**
   * @param {Transaction} transaction
   * @param {number} offset
   */
  integrate(transaction, offset) {
    throw methodUnimplemented();
  }
};
var structGCRefNumber = 0;
var GC = class extends AbstractStruct {
  get deleted() {
    return true;
  }
  delete() {
  }
  /**
   * @param {GC} right
   * @return {boolean}
   */
  mergeWith(right) {
    if (this.constructor !== right.constructor) {
      return false;
    }
    this.length += right.length;
    return true;
  }
  /**
   * @param {Transaction} transaction
   * @param {number} offset
   */
  integrate(transaction, offset) {
    if (offset > 0) {
      this.id.clock += offset;
      this.length -= offset;
    }
    addStruct(transaction.doc.store, this);
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeInfo(structGCRefNumber);
    encoder.writeLen(this.length - offset);
  }
  /**
   * @param {Transaction} transaction
   * @param {StructStore} store
   * @return {null | number}
   */
  getMissing(transaction, store) {
    return null;
  }
};
var ContentBinary = class _ContentBinary {
  /**
   * @param {Uint8Array} content
   */
  constructor(content) {
    this.content = content;
  }
  /**
   * @return {number}
   */
  getLength() {
    return 1;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return [this.content];
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentBinary}
   */
  copy() {
    return new _ContentBinary(this.content);
  }
  /**
   * @param {number} offset
   * @return {ContentBinary}
   */
  splice(offset) {
    throw methodUnimplemented();
  }
  /**
   * @param {ContentBinary} right
   * @return {boolean}
   */
  mergeWith(right) {
    return false;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeBuf(this.content);
  }
  /**
   * @return {number}
   */
  getRef() {
    return 3;
  }
};
var readContentBinary = (decoder) => new ContentBinary(decoder.readBuf());
var ContentDeleted = class _ContentDeleted {
  /**
   * @param {number} len
   */
  constructor(len) {
    this.len = len;
  }
  /**
   * @return {number}
   */
  getLength() {
    return this.len;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return [];
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return false;
  }
  /**
   * @return {ContentDeleted}
   */
  copy() {
    return new _ContentDeleted(this.len);
  }
  /**
   * @param {number} offset
   * @return {ContentDeleted}
   */
  splice(offset) {
    const right = new _ContentDeleted(this.len - offset);
    this.len = offset;
    return right;
  }
  /**
   * @param {ContentDeleted} right
   * @return {boolean}
   */
  mergeWith(right) {
    this.len += right.len;
    return true;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
    addToDeleteSet(transaction.deleteSet, item.id.client, item.id.clock, this.len);
    item.markDeleted();
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeLen(this.len - offset);
  }
  /**
   * @return {number}
   */
  getRef() {
    return 1;
  }
};
var readContentDeleted = (decoder) => new ContentDeleted(decoder.readLen());
var createDocFromOpts = (guid, opts) => new Doc({ guid, ...opts, shouldLoad: opts.shouldLoad || opts.autoLoad || false });
var ContentDoc = class _ContentDoc {
  /**
   * @param {Doc} doc
   */
  constructor(doc2) {
    if (doc2._item) {
      console.error("This document was already integrated as a sub-document. You should create a second instance instead with the same guid.");
    }
    this.doc = doc2;
    const opts = {};
    this.opts = opts;
    if (!doc2.gc) {
      opts.gc = false;
    }
    if (doc2.autoLoad) {
      opts.autoLoad = true;
    }
    if (doc2.meta !== null) {
      opts.meta = doc2.meta;
    }
  }
  /**
   * @return {number}
   */
  getLength() {
    return 1;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return [this.doc];
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentDoc}
   */
  copy() {
    return new _ContentDoc(createDocFromOpts(this.doc.guid, this.opts));
  }
  /**
   * @param {number} offset
   * @return {ContentDoc}
   */
  splice(offset) {
    throw methodUnimplemented();
  }
  /**
   * @param {ContentDoc} right
   * @return {boolean}
   */
  mergeWith(right) {
    return false;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
    this.doc._item = item;
    transaction.subdocsAdded.add(this.doc);
    if (this.doc.shouldLoad) {
      transaction.subdocsLoaded.add(this.doc);
    }
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
    if (transaction.subdocsAdded.has(this.doc)) {
      transaction.subdocsAdded.delete(this.doc);
    } else {
      transaction.subdocsRemoved.add(this.doc);
    }
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeString(this.doc.guid);
    encoder.writeAny(this.opts);
  }
  /**
   * @return {number}
   */
  getRef() {
    return 9;
  }
};
var readContentDoc = (decoder) => new ContentDoc(createDocFromOpts(decoder.readString(), decoder.readAny()));
var ContentEmbed = class _ContentEmbed {
  /**
   * @param {Object} embed
   */
  constructor(embed) {
    this.embed = embed;
  }
  /**
   * @return {number}
   */
  getLength() {
    return 1;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return [this.embed];
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentEmbed}
   */
  copy() {
    return new _ContentEmbed(this.embed);
  }
  /**
   * @param {number} offset
   * @return {ContentEmbed}
   */
  splice(offset) {
    throw methodUnimplemented();
  }
  /**
   * @param {ContentEmbed} right
   * @return {boolean}
   */
  mergeWith(right) {
    return false;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeJSON(this.embed);
  }
  /**
   * @return {number}
   */
  getRef() {
    return 5;
  }
};
var readContentEmbed = (decoder) => new ContentEmbed(decoder.readJSON());
var ContentFormat = class _ContentFormat {
  /**
   * @param {string} key
   * @param {Object} value
   */
  constructor(key, value) {
    this.key = key;
    this.value = value;
  }
  /**
   * @return {number}
   */
  getLength() {
    return 1;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return [];
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return false;
  }
  /**
   * @return {ContentFormat}
   */
  copy() {
    return new _ContentFormat(this.key, this.value);
  }
  /**
   * @param {number} _offset
   * @return {ContentFormat}
   */
  splice(_offset) {
    throw methodUnimplemented();
  }
  /**
   * @param {ContentFormat} _right
   * @return {boolean}
   */
  mergeWith(_right) {
    return false;
  }
  /**
   * @param {Transaction} _transaction
   * @param {Item} item
   */
  integrate(_transaction, item) {
    const p = (
      /** @type {YText} */
      item.parent
    );
    p._searchMarker = null;
    p._hasFormatting = true;
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeKey(this.key);
    encoder.writeJSON(this.value);
  }
  /**
   * @return {number}
   */
  getRef() {
    return 6;
  }
};
var readContentFormat = (decoder) => new ContentFormat(decoder.readKey(), decoder.readJSON());
var ContentJSON = class _ContentJSON {
  /**
   * @param {Array<any>} arr
   */
  constructor(arr) {
    this.arr = arr;
  }
  /**
   * @return {number}
   */
  getLength() {
    return this.arr.length;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return this.arr;
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentJSON}
   */
  copy() {
    return new _ContentJSON(this.arr);
  }
  /**
   * @param {number} offset
   * @return {ContentJSON}
   */
  splice(offset) {
    const right = new _ContentJSON(this.arr.slice(offset));
    this.arr = this.arr.slice(0, offset);
    return right;
  }
  /**
   * @param {ContentJSON} right
   * @return {boolean}
   */
  mergeWith(right) {
    this.arr = this.arr.concat(right.arr);
    return true;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    const len = this.arr.length;
    encoder.writeLen(len - offset);
    for (let i = offset; i < len; i++) {
      const c = this.arr[i];
      encoder.writeString(c === void 0 ? "undefined" : JSON.stringify(c));
    }
  }
  /**
   * @return {number}
   */
  getRef() {
    return 2;
  }
};
var readContentJSON = (decoder) => {
  const len = decoder.readLen();
  const cs = [];
  for (let i = 0; i < len; i++) {
    const c = decoder.readString();
    if (c === "undefined") {
      cs.push(void 0);
    } else {
      cs.push(JSON.parse(c));
    }
  }
  return new ContentJSON(cs);
};
var isDevMode = getVariable("node_env") === "development";
var ContentAny = class _ContentAny {
  /**
   * @param {Array<any>} arr
   */
  constructor(arr) {
    this.arr = arr;
    isDevMode && deepFreeze(arr);
  }
  /**
   * @return {number}
   */
  getLength() {
    return this.arr.length;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return this.arr;
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentAny}
   */
  copy() {
    return new _ContentAny(this.arr);
  }
  /**
   * @param {number} offset
   * @return {ContentAny}
   */
  splice(offset) {
    const right = new _ContentAny(this.arr.slice(offset));
    this.arr = this.arr.slice(0, offset);
    return right;
  }
  /**
   * @param {ContentAny} right
   * @return {boolean}
   */
  mergeWith(right) {
    this.arr = this.arr.concat(right.arr);
    return true;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    const len = this.arr.length;
    encoder.writeLen(len - offset);
    for (let i = offset; i < len; i++) {
      const c = this.arr[i];
      encoder.writeAny(c);
    }
  }
  /**
   * @return {number}
   */
  getRef() {
    return 8;
  }
};
var readContentAny = (decoder) => {
  const len = decoder.readLen();
  const cs = [];
  for (let i = 0; i < len; i++) {
    cs.push(decoder.readAny());
  }
  return new ContentAny(cs);
};
var ContentString = class _ContentString {
  /**
   * @param {string} str
   */
  constructor(str) {
    this.str = str;
  }
  /**
   * @return {number}
   */
  getLength() {
    return this.str.length;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return this.str.split("");
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentString}
   */
  copy() {
    return new _ContentString(this.str);
  }
  /**
   * @param {number} offset
   * @return {ContentString}
   */
  splice(offset) {
    const right = new _ContentString(this.str.slice(offset));
    this.str = this.str.slice(0, offset);
    const firstCharCode = this.str.charCodeAt(offset - 1);
    if (firstCharCode >= 55296 && firstCharCode <= 56319) {
      this.str = this.str.slice(0, offset - 1) + "\uFFFD";
      right.str = "\uFFFD" + right.str.slice(1);
    }
    return right;
  }
  /**
   * @param {ContentString} right
   * @return {boolean}
   */
  mergeWith(right) {
    this.str += right.str;
    return true;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeString(offset === 0 ? this.str : this.str.slice(offset));
  }
  /**
   * @return {number}
   */
  getRef() {
    return 4;
  }
};
var readContentString = (decoder) => new ContentString(decoder.readString());
var typeRefs = [
  readYArray,
  readYMap,
  readYText,
  readYXmlElement,
  readYXmlFragment,
  readYXmlHook,
  readYXmlText
];
var YArrayRefID = 0;
var YMapRefID = 1;
var YTextRefID = 2;
var YXmlElementRefID = 3;
var YXmlFragmentRefID = 4;
var YXmlHookRefID = 5;
var YXmlTextRefID = 6;
var ContentType = class _ContentType {
  /**
   * @param {AbstractType<any>} type
   */
  constructor(type) {
    this.type = type;
  }
  /**
   * @return {number}
   */
  getLength() {
    return 1;
  }
  /**
   * @return {Array<any>}
   */
  getContent() {
    return [this.type];
  }
  /**
   * @return {boolean}
   */
  isCountable() {
    return true;
  }
  /**
   * @return {ContentType}
   */
  copy() {
    return new _ContentType(this.type._copy());
  }
  /**
   * @param {number} offset
   * @return {ContentType}
   */
  splice(offset) {
    throw methodUnimplemented();
  }
  /**
   * @param {ContentType} right
   * @return {boolean}
   */
  mergeWith(right) {
    return false;
  }
  /**
   * @param {Transaction} transaction
   * @param {Item} item
   */
  integrate(transaction, item) {
    this.type._integrate(transaction.doc, item);
  }
  /**
   * @param {Transaction} transaction
   */
  delete(transaction) {
    let item = this.type._start;
    while (item !== null) {
      if (!item.deleted) {
        item.delete(transaction);
      } else if (item.id.clock < (transaction.beforeState.get(item.id.client) || 0)) {
        transaction._mergeStructs.push(item);
      }
      item = item.right;
    }
    this.type._map.forEach((item2) => {
      if (!item2.deleted) {
        item2.delete(transaction);
      } else if (item2.id.clock < (transaction.beforeState.get(item2.id.client) || 0)) {
        transaction._mergeStructs.push(item2);
      }
    });
    transaction.changed.delete(this.type);
  }
  /**
   * @param {StructStore} store
   */
  gc(store) {
    let item = this.type._start;
    while (item !== null) {
      item.gc(store, true);
      item = item.right;
    }
    this.type._start = null;
    this.type._map.forEach(
      /** @param {Item | null} item */
      (item2) => {
        while (item2 !== null) {
          item2.gc(store, true);
          item2 = item2.left;
        }
      }
    );
    this.type._map = /* @__PURE__ */ new Map();
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    this.type._write(encoder);
  }
  /**
   * @return {number}
   */
  getRef() {
    return 7;
  }
};
var readContentType = (decoder) => new ContentType(typeRefs[decoder.readTypeRef()](decoder));
var followRedone = (store, id2) => {
  let nextID = id2;
  let diff = 0;
  let item;
  do {
    if (diff > 0) {
      nextID = createID(nextID.client, nextID.clock + diff);
    }
    item = getItem(store, nextID);
    diff = nextID.clock - item.id.clock;
    nextID = item.redone;
  } while (nextID !== null && item instanceof Item);
  return {
    item,
    diff
  };
};
var keepItem = (item, keep) => {
  while (item !== null && item.keep !== keep) {
    item.keep = keep;
    item = /** @type {AbstractType<any>} */
    item.parent._item;
  }
};
var splitItem = (transaction, leftItem, diff) => {
  const { client, clock } = leftItem.id;
  const rightItem = new Item(
    createID(client, clock + diff),
    leftItem,
    createID(client, clock + diff - 1),
    leftItem.right,
    leftItem.rightOrigin,
    leftItem.parent,
    leftItem.parentSub,
    leftItem.content.splice(diff)
  );
  if (leftItem.deleted) {
    rightItem.markDeleted();
  }
  if (leftItem.keep) {
    rightItem.keep = true;
  }
  if (leftItem.redone !== null) {
    rightItem.redone = createID(leftItem.redone.client, leftItem.redone.clock + diff);
  }
  leftItem.right = rightItem;
  if (rightItem.right !== null) {
    rightItem.right.left = rightItem;
  }
  transaction._mergeStructs.push(rightItem);
  if (rightItem.parentSub !== null && rightItem.right === null) {
    rightItem.parent._map.set(rightItem.parentSub, rightItem);
  }
  leftItem.length = diff;
  return rightItem;
};
var isDeletedByUndoStack = (stack, id2) => some(
  stack,
  /** @param {StackItem} s */
  (s) => isDeleted(s.deletions, id2)
);
var redoItem = (transaction, item, redoitems, itemsToDelete, ignoreRemoteMapChanges, um) => {
  const doc2 = transaction.doc;
  const store = doc2.store;
  const ownClientID = doc2.clientID;
  const redone = item.redone;
  if (redone !== null) {
    return getItemCleanStart(transaction, redone);
  }
  let parentItem = (
    /** @type {AbstractType<any>} */
    item.parent._item
  );
  let left = null;
  let right;
  if (parentItem !== null && parentItem.deleted === true) {
    if (parentItem.redone === null && (!redoitems.has(parentItem) || redoItem(transaction, parentItem, redoitems, itemsToDelete, ignoreRemoteMapChanges, um) === null)) {
      return null;
    }
    while (parentItem.redone !== null) {
      parentItem = getItemCleanStart(transaction, parentItem.redone);
    }
  }
  const parentType = parentItem === null ? (
    /** @type {AbstractType<any>} */
    item.parent
  ) : (
    /** @type {ContentType} */
    parentItem.content.type
  );
  if (item.parentSub === null) {
    left = item.left;
    right = item;
    while (left !== null) {
      let leftTrace = left;
      while (leftTrace !== null && /** @type {AbstractType<any>} */
      leftTrace.parent._item !== parentItem) {
        leftTrace = leftTrace.redone === null ? null : getItemCleanStart(transaction, leftTrace.redone);
      }
      if (leftTrace !== null && /** @type {AbstractType<any>} */
      leftTrace.parent._item === parentItem) {
        left = leftTrace;
        break;
      }
      left = left.left;
    }
    while (right !== null) {
      let rightTrace = right;
      while (rightTrace !== null && /** @type {AbstractType<any>} */
      rightTrace.parent._item !== parentItem) {
        rightTrace = rightTrace.redone === null ? null : getItemCleanStart(transaction, rightTrace.redone);
      }
      if (rightTrace !== null && /** @type {AbstractType<any>} */
      rightTrace.parent._item === parentItem) {
        right = rightTrace;
        break;
      }
      right = right.right;
    }
  } else {
    right = null;
    if (item.right && !ignoreRemoteMapChanges) {
      left = item;
      while (left !== null && left.right !== null && (left.right.redone || isDeleted(itemsToDelete, left.right.id) || isDeletedByUndoStack(um.undoStack, left.right.id) || isDeletedByUndoStack(um.redoStack, left.right.id))) {
        left = left.right;
        while (left.redone) left = getItemCleanStart(transaction, left.redone);
      }
      if (left && left.right !== null) {
        return null;
      }
    } else {
      left = parentType._map.get(item.parentSub) || null;
    }
    if (left !== null && /** @type {AbstractType<any>} */
    left.parent._item !== parentItem) {
      left = parentType._map.get(item.parentSub) || null;
    }
  }
  const nextClock = getState(store, ownClientID);
  const nextId = createID(ownClientID, nextClock);
  const redoneItem = new Item(
    nextId,
    left,
    left && left.lastId,
    right,
    right && right.id,
    parentType,
    item.parentSub,
    item.content.copy()
  );
  item.redone = nextId;
  keepItem(redoneItem, true);
  redoneItem.integrate(transaction, 0);
  return redoneItem;
};
var Item = class _Item extends AbstractStruct {
  /**
   * @param {ID} id
   * @param {Item | null} left
   * @param {ID | null} origin
   * @param {Item | null} right
   * @param {ID | null} rightOrigin
   * @param {AbstractType<any>|ID|null} parent Is a type if integrated, is null if it is possible to copy parent from left or right, is ID before integration to search for it.
   * @param {string | null} parentSub
   * @param {AbstractContent} content
   */
  constructor(id2, left, origin, right, rightOrigin, parent, parentSub, content) {
    super(id2, content.getLength());
    this.origin = origin;
    this.left = left;
    this.right = right;
    this.rightOrigin = rightOrigin;
    this.parent = parent;
    this.parentSub = parentSub;
    this.redone = null;
    this.content = content;
    this.info = this.content.isCountable() ? BIT2 : 0;
  }
  /**
   * This is used to mark the item as an indexed fast-search marker
   *
   * @type {boolean}
   */
  set marker(isMarked) {
    if ((this.info & BIT4) > 0 !== isMarked) {
      this.info ^= BIT4;
    }
  }
  get marker() {
    return (this.info & BIT4) > 0;
  }
  /**
   * If true, do not garbage collect this Item.
   */
  get keep() {
    return (this.info & BIT1) > 0;
  }
  set keep(doKeep) {
    if (this.keep !== doKeep) {
      this.info ^= BIT1;
    }
  }
  get countable() {
    return (this.info & BIT2) > 0;
  }
  /**
   * Whether this item was deleted or not.
   * @type {Boolean}
   */
  get deleted() {
    return (this.info & BIT3) > 0;
  }
  set deleted(doDelete) {
    if (this.deleted !== doDelete) {
      this.info ^= BIT3;
    }
  }
  markDeleted() {
    this.info |= BIT3;
  }
  /**
   * Return the creator clientID of the missing op or define missing items and return null.
   *
   * @param {Transaction} transaction
   * @param {StructStore} store
   * @return {null | number}
   */
  getMissing(transaction, store) {
    if (this.origin && this.origin.client !== this.id.client && this.origin.clock >= getState(store, this.origin.client)) {
      return this.origin.client;
    }
    if (this.rightOrigin && this.rightOrigin.client !== this.id.client && this.rightOrigin.clock >= getState(store, this.rightOrigin.client)) {
      return this.rightOrigin.client;
    }
    if (this.parent && this.parent.constructor === ID && this.id.client !== this.parent.client && this.parent.clock >= getState(store, this.parent.client)) {
      return this.parent.client;
    }
    if (this.origin) {
      this.left = getItemCleanEnd(transaction, store, this.origin);
      this.origin = this.left.lastId;
    }
    if (this.rightOrigin) {
      this.right = getItemCleanStart(transaction, this.rightOrigin);
      this.rightOrigin = this.right.id;
    }
    if (this.left && this.left.constructor === GC || this.right && this.right.constructor === GC) {
      this.parent = null;
    } else if (!this.parent) {
      if (this.left && this.left.constructor === _Item) {
        this.parent = this.left.parent;
        this.parentSub = this.left.parentSub;
      } else if (this.right && this.right.constructor === _Item) {
        this.parent = this.right.parent;
        this.parentSub = this.right.parentSub;
      }
    } else if (this.parent.constructor === ID) {
      const parentItem = getItem(store, this.parent);
      if (parentItem.constructor === GC) {
        this.parent = null;
      } else {
        this.parent = /** @type {ContentType} */
        parentItem.content.type;
      }
    }
    return null;
  }
  /**
   * @param {Transaction} transaction
   * @param {number} offset
   */
  integrate(transaction, offset) {
    if (offset > 0) {
      this.id.clock += offset;
      this.left = getItemCleanEnd(transaction, transaction.doc.store, createID(this.id.client, this.id.clock - 1));
      this.origin = this.left.lastId;
      this.content = this.content.splice(offset);
      this.length -= offset;
    }
    if (this.parent) {
      if (!this.left && (!this.right || this.right.left !== null) || this.left && this.left.right !== this.right) {
        let left = this.left;
        let o;
        if (left !== null) {
          o = left.right;
        } else if (this.parentSub !== null) {
          o = /** @type {AbstractType<any>} */
          this.parent._map.get(this.parentSub) || null;
          while (o !== null && o.left !== null) {
            o = o.left;
          }
        } else {
          o = /** @type {AbstractType<any>} */
          this.parent._start;
        }
        const conflictingItems = /* @__PURE__ */ new Set();
        const itemsBeforeOrigin = /* @__PURE__ */ new Set();
        while (o !== null && o !== this.right) {
          itemsBeforeOrigin.add(o);
          conflictingItems.add(o);
          if (compareIDs(this.origin, o.origin)) {
            if (o.id.client < this.id.client) {
              left = o;
              conflictingItems.clear();
            } else if (compareIDs(this.rightOrigin, o.rightOrigin)) {
              break;
            }
          } else if (o.origin !== null && itemsBeforeOrigin.has(getItem(transaction.doc.store, o.origin))) {
            if (!conflictingItems.has(getItem(transaction.doc.store, o.origin))) {
              left = o;
              conflictingItems.clear();
            }
          } else {
            break;
          }
          o = o.right;
        }
        this.left = left;
      }
      if (this.left !== null) {
        const right = this.left.right;
        this.right = right;
        this.left.right = this;
      } else {
        let r;
        if (this.parentSub !== null) {
          r = /** @type {AbstractType<any>} */
          this.parent._map.get(this.parentSub) || null;
          while (r !== null && r.left !== null) {
            r = r.left;
          }
        } else {
          r = /** @type {AbstractType<any>} */
          this.parent._start;
          this.parent._start = this;
        }
        this.right = r;
      }
      if (this.right !== null) {
        this.right.left = this;
      } else if (this.parentSub !== null) {
        this.parent._map.set(this.parentSub, this);
        if (this.left !== null) {
          this.left.delete(transaction);
        }
      }
      if (this.parentSub === null && this.countable && !this.deleted) {
        this.parent._length += this.length;
      }
      addStruct(transaction.doc.store, this);
      this.content.integrate(transaction, this);
      addChangedTypeToTransaction(
        transaction,
        /** @type {AbstractType<any>} */
        this.parent,
        this.parentSub
      );
      if (
        /** @type {AbstractType<any>} */
        this.parent._item !== null && /** @type {AbstractType<any>} */
        this.parent._item.deleted || this.parentSub !== null && this.right !== null
      ) {
        this.delete(transaction);
      }
    } else {
      new GC(this.id, this.length).integrate(transaction, 0);
    }
  }
  /**
   * Returns the next non-deleted item
   */
  get next() {
    let n = this.right;
    while (n !== null && n.deleted) {
      n = n.right;
    }
    return n;
  }
  /**
   * Returns the previous non-deleted item
   */
  get prev() {
    let n = this.left;
    while (n !== null && n.deleted) {
      n = n.left;
    }
    return n;
  }
  /**
   * Computes the last content address of this Item.
   */
  get lastId() {
    return this.length === 1 ? this.id : createID(this.id.client, this.id.clock + this.length - 1);
  }
  /**
   * Try to merge two items
   *
   * @param {Item} right
   * @return {boolean}
   */
  mergeWith(right) {
    if (this.constructor === right.constructor && compareIDs(right.origin, this.lastId) && this.right === right && compareIDs(this.rightOrigin, right.rightOrigin) && this.id.client === right.id.client && this.id.clock + this.length === right.id.clock && this.deleted === right.deleted && this.redone === null && right.redone === null && this.content.constructor === right.content.constructor && this.content.mergeWith(right.content)) {
      const searchMarker = (
        /** @type {AbstractType<any>} */
        this.parent._searchMarker
      );
      if (searchMarker) {
        searchMarker.forEach((marker) => {
          if (marker.p === right) {
            marker.p = this;
            if (!this.deleted && this.countable) {
              marker.index -= this.length;
            }
          }
        });
      }
      if (right.keep) {
        this.keep = true;
      }
      this.right = right.right;
      if (this.right !== null) {
        this.right.left = this;
      }
      this.length += right.length;
      return true;
    }
    return false;
  }
  /**
   * Mark this Item as deleted.
   *
   * @param {Transaction} transaction
   */
  delete(transaction) {
    if (!this.deleted) {
      const parent = (
        /** @type {AbstractType<any>} */
        this.parent
      );
      if (this.countable && this.parentSub === null) {
        parent._length -= this.length;
      }
      this.markDeleted();
      addToDeleteSet(transaction.deleteSet, this.id.client, this.id.clock, this.length);
      addChangedTypeToTransaction(transaction, parent, this.parentSub);
      this.content.delete(transaction);
    }
  }
  /**
   * @param {StructStore} store
   * @param {boolean} parentGCd
   */
  gc(store, parentGCd) {
    if (!this.deleted) {
      throw unexpectedCase();
    }
    this.content.gc(store);
    if (parentGCd) {
      replaceStruct(store, this, new GC(this.id, this.length));
    } else {
      this.content = new ContentDeleted(this.length);
    }
  }
  /**
   * Transform the properties of this type to binary and write it to an
   * BinaryEncoder.
   *
   * This is called when this Item is sent to a remote peer.
   *
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder The encoder to write data to.
   * @param {number} offset
   */
  write(encoder, offset) {
    const origin = offset > 0 ? createID(this.id.client, this.id.clock + offset - 1) : this.origin;
    const rightOrigin = this.rightOrigin;
    const parentSub = this.parentSub;
    const info = this.content.getRef() & BITS5 | (origin === null ? 0 : BIT8) | // origin is defined
    (rightOrigin === null ? 0 : BIT7) | // right origin is defined
    (parentSub === null ? 0 : BIT6);
    encoder.writeInfo(info);
    if (origin !== null) {
      encoder.writeLeftID(origin);
    }
    if (rightOrigin !== null) {
      encoder.writeRightID(rightOrigin);
    }
    if (origin === null && rightOrigin === null) {
      const parent = (
        /** @type {AbstractType<any>} */
        this.parent
      );
      if (parent._item !== void 0) {
        const parentItem = parent._item;
        if (parentItem === null) {
          const ykey = findRootTypeKey(parent);
          encoder.writeParentInfo(true);
          encoder.writeString(ykey);
        } else {
          encoder.writeParentInfo(false);
          encoder.writeLeftID(parentItem.id);
        }
      } else if (parent.constructor === String) {
        encoder.writeParentInfo(true);
        encoder.writeString(parent);
      } else if (parent.constructor === ID) {
        encoder.writeParentInfo(false);
        encoder.writeLeftID(parent);
      } else {
        unexpectedCase();
      }
      if (parentSub !== null) {
        encoder.writeString(parentSub);
      }
    }
    this.content.write(encoder, offset);
  }
};
var readItemContent = (decoder, info) => contentRefs[info & BITS5](decoder);
var contentRefs = [
  () => {
    unexpectedCase();
  },
  // GC is not ItemContent
  readContentDeleted,
  // 1
  readContentJSON,
  // 2
  readContentBinary,
  // 3
  readContentString,
  // 4
  readContentEmbed,
  // 5
  readContentFormat,
  // 6
  readContentType,
  // 7
  readContentAny,
  // 8
  readContentDoc,
  // 9
  () => {
    unexpectedCase();
  }
  // 10 - Skip is not ItemContent
];
var structSkipRefNumber = 10;
var Skip = class extends AbstractStruct {
  get deleted() {
    return true;
  }
  delete() {
  }
  /**
   * @param {Skip} right
   * @return {boolean}
   */
  mergeWith(right) {
    if (this.constructor !== right.constructor) {
      return false;
    }
    this.length += right.length;
    return true;
  }
  /**
   * @param {Transaction} transaction
   * @param {number} offset
   */
  integrate(transaction, offset) {
    unexpectedCase();
  }
  /**
   * @param {UpdateEncoderV1 | UpdateEncoderV2} encoder
   * @param {number} offset
   */
  write(encoder, offset) {
    encoder.writeInfo(structSkipRefNumber);
    writeVarUint(encoder.restEncoder, this.length - offset);
  }
  /**
   * @param {Transaction} transaction
   * @param {StructStore} store
   * @return {null | number}
   */
  getMissing(transaction, store) {
    return null;
  }
};
var glo = (
  /** @type {any} */
  typeof globalThis !== "undefined" ? globalThis : typeof window !== "undefined" ? window : typeof global !== "undefined" ? global : {}
);
var importIdentifier = "__ $YJS$ __";
if (glo[importIdentifier] === true) {
  console.error("Yjs was already imported. This breaks constructor checks and will lead to issues! - https://github.com/yjs/yjs/issues/438");
}
glo[importIdentifier] = true;

// node_modules/lib0/indexeddb.js
var rtop = (request) => create4((resolve, reject) => {
  request.onerror = (event) => reject(new Error(event.target.error));
  request.onsuccess = (event) => resolve(event.target.result);
});
var openDB = (name, initDB) => create4((resolve, reject) => {
  const request = indexedDB.open(name);
  request.onupgradeneeded = (event) => initDB(event.target.result);
  request.onerror = (event) => reject(create3(event.target.error));
  request.onsuccess = (event) => {
    const db = event.target.result;
    db.onversionchange = () => {
      db.close();
    };
    resolve(db);
  };
});
var deleteDB = (name) => rtop(indexedDB.deleteDatabase(name));
var createStores = (db, definitions) => definitions.forEach(
  (d) => (
    // @ts-ignore
    db.createObjectStore.apply(db, d)
  )
);
var transact2 = (db, stores, access = "readwrite") => {
  const transaction = db.transaction(stores, access);
  return stores.map((store) => getStore(transaction, store));
};
var count = (store, range) => rtop(store.count(range));
var get = (store, key) => rtop(store.get(key));
var del = (store, key) => rtop(store.delete(key));
var put = (store, item, key) => rtop(store.put(item, key));
var addAutoKey = (store, item) => rtop(store.add(item));
var getAll = (store, range, limit) => rtop(store.getAll(range, limit));
var queryFirst = (store, query2, direction) => {
  let first = null;
  return iterateKeys(store, query2, (key) => {
    first = key;
    return false;
  }, direction).then(() => first);
};
var getLastKey = (store, range = null) => queryFirst(store, range, "prev");
var iterateOnRequest = (request, f2) => create4((resolve, reject) => {
  request.onerror = reject;
  request.onsuccess = async (event) => {
    const cursor = event.target.result;
    if (cursor === null || await f2(cursor) === false) {
      return resolve();
    }
    cursor.continue();
  };
});
var iterateKeys = (store, keyrange, f2, direction = "next") => iterateOnRequest(store.openKeyCursor(keyrange, direction), (cursor) => f2(cursor.key));
var getStore = (t, store) => t.objectStore(store);
var createIDBKeyRangeUpperBound = (upper, upperOpen) => IDBKeyRange.upperBound(upper, upperOpen);
var createIDBKeyRangeLowerBound = (lower, lowerOpen) => IDBKeyRange.lowerBound(lower, lowerOpen);

// node_modules/y-indexeddb/src/y-indexeddb.js
var customStoreName = "custom";
var updatesStoreName = "updates";
var PREFERRED_TRIM_SIZE = 500;
var fetchUpdates = (idbPersistence, beforeApplyUpdatesCallback = () => {
}, afterApplyUpdatesCallback = () => {
}) => {
  const [updatesStore] = transact2(
    /** @type {IDBDatabase} */
    idbPersistence.db,
    [updatesStoreName]
  );
  return getAll(updatesStore, createIDBKeyRangeLowerBound(idbPersistence._dbref, false)).then((updates) => {
    if (!idbPersistence._destroyed) {
      beforeApplyUpdatesCallback(updatesStore);
      transact(idbPersistence.doc, () => {
        updates.forEach((val) => applyUpdate(idbPersistence.doc, val));
      }, idbPersistence, false);
      afterApplyUpdatesCallback(updatesStore);
    }
  }).then(() => getLastKey(updatesStore).then((lastKey) => {
    idbPersistence._dbref = lastKey + 1;
  })).then(() => count(updatesStore).then((cnt) => {
    idbPersistence._dbsize = cnt;
  })).then(() => updatesStore);
};
var storeState = (idbPersistence, forceStore = true) => fetchUpdates(idbPersistence).then((updatesStore) => {
  if (forceStore || idbPersistence._dbsize >= PREFERRED_TRIM_SIZE) {
    addAutoKey(updatesStore, encodeStateAsUpdate(idbPersistence.doc)).then(() => del(updatesStore, createIDBKeyRangeUpperBound(idbPersistence._dbref, true))).then(() => count(updatesStore).then((cnt) => {
      idbPersistence._dbsize = cnt;
    }));
  }
});
var IndexeddbPersistence = class extends Observable {
  /**
   * @param {string} name
   * @param {Y.Doc} doc
   */
  constructor(name, doc2) {
    super();
    this.doc = doc2;
    this.name = name;
    this._dbref = 0;
    this._dbsize = 0;
    this._destroyed = false;
    this.db = null;
    this.synced = false;
    this._db = openDB(
      name,
      (db) => createStores(db, [
        ["updates", { autoIncrement: true }],
        ["custom"]
      ])
    );
    this.whenSynced = create4((resolve) => this.on("synced", () => resolve(this)));
    this._db.then((db) => {
      this.db = db;
      const beforeApplyUpdatesCallback = (updatesStore) => addAutoKey(updatesStore, encodeStateAsUpdate(doc2));
      const afterApplyUpdatesCallback = () => {
        if (this._destroyed) return this;
        this.synced = true;
        this.emit("synced", [this]);
      };
      fetchUpdates(this, beforeApplyUpdatesCallback, afterApplyUpdatesCallback);
    });
    this._storeTimeout = 1e3;
    this._storeTimeoutId = null;
    this._storeUpdate = (update, origin) => {
      if (this.db && origin !== this) {
        const [updatesStore] = transact2(
          /** @type {IDBDatabase} */
          this.db,
          [updatesStoreName]
        );
        addAutoKey(updatesStore, update);
        if (++this._dbsize >= PREFERRED_TRIM_SIZE) {
          if (this._storeTimeoutId !== null) {
            clearTimeout(this._storeTimeoutId);
          }
          this._storeTimeoutId = setTimeout(() => {
            storeState(this, false);
            this._storeTimeoutId = null;
          }, this._storeTimeout);
        }
      }
    };
    doc2.on("update", this._storeUpdate);
    this.destroy = this.destroy.bind(this);
    doc2.on("destroy", this.destroy);
  }
  destroy() {
    if (this._storeTimeoutId) {
      clearTimeout(this._storeTimeoutId);
    }
    this.doc.off("update", this._storeUpdate);
    this.doc.off("destroy", this.destroy);
    this._destroyed = true;
    return this._db.then((db) => {
      db.close();
    });
  }
  /**
   * Destroys this instance and removes all data from indexeddb.
   *
   * @return {Promise<void>}
   */
  clearData() {
    return this.destroy().then(() => {
      deleteDB(this.name);
    });
  }
  /**
   * @param {String | number | ArrayBuffer | Date} key
   * @return {Promise<String | number | ArrayBuffer | Date | any>}
   */
  get(key) {
    return this._db.then((db) => {
      const [custom] = transact2(db, [customStoreName], "readonly");
      return get(custom, key);
    });
  }
  /**
   * @param {String | number | ArrayBuffer | Date} key
   * @param {String | number | ArrayBuffer | Date} value
   * @return {Promise<String | number | ArrayBuffer | Date>}
   */
  set(key, value) {
    return this._db.then((db) => {
      const [custom] = transact2(db, [customStoreName]);
      return put(custom, value, key);
    });
  }
  /**
   * @param {String | number | ArrayBuffer | Date} key
   * @return {Promise<undefined>}
   */
  del(key) {
    return this._db.then((db) => {
      const [custom] = transact2(db, [customStoreName]);
      return del(custom, key);
    });
  }
};

// src/recovery.js
var HEADER = "rayde:identity";
var LEGACY = "rayde:binding";
var MAX_GRAPH = 4 * 1024 * 1024;
var MAX_INPUT = 64 * 1024 * 1024;
var validDocumentId = (value) => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
var legacyName = (workspace, path) => `rayde:v2:${JSON.stringify([workspace, path])}`;
var recoveryName = (workspace, id2) => {
  if (!validDocumentId(id2)) throw failure("The workspace returned an invalid document identity.");
  return `rayde:v3:${JSON.stringify([workspace, id2])}`;
};
function failure(message) {
  return Object.assign(new Error(message), { code: "recovery-failed" });
}
function pathKey(path) {
  if (typeof path !== "string" || !path || path.length > 4096 || path.includes("\0") || path.includes("\\") || path.split("/").includes("..")) throw failure("The recovery path is invalid.");
  return path;
}
function openDatabase(name, create7) {
  return new Promise((resolve, reject) => {
    let missing = false;
    const request = indexedDB.open(name);
    request.onupgradeneeded = () => {
      if (!create7) {
        missing = true;
        request.transaction.abort();
      } else request.result.createObjectStore("bindings");
    };
    request.onerror = () => missing ? resolve(null) : reject(request.error ?? failure("Could not open browser recovery."));
    request.onsuccess = () => resolve(request.result);
  });
}
var RecoveryDirectory = class {
  async database() {
    return this.opening ??= openDatabase("rayde-document-bindings-v1", true);
  }
  async get(workspace, path) {
    const db = await this.database();
    return new Promise((resolve, reject) => {
      const tx = db.transaction("bindings", "readonly"), request = tx.objectStore("bindings").get([workspace, pathKey(path)]);
      tx.oncomplete = () => {
        const value = request.result;
        if (value !== void 0 && (value.version !== 1 || !validDocumentId(value.id))) reject(failure("The browser recovery binding is invalid."));
        else resolve(value?.id ?? null);
      };
      tx.onerror = tx.onabort = () => reject(tx.error ?? failure("Could not read the browser recovery binding."));
    });
  }
  async put(workspace, path, id2) {
    recoveryName(workspace, id2);
    pathKey(path);
    const db = await this.database();
    return new Promise((resolve, reject) => {
      const tx = db.transaction("bindings", "readwrite"), store = tx.objectStore("bindings"), key = [workspace, path];
      let error;
      const previous = store.get(key);
      previous.onsuccess = () => {
        if (previous.result !== void 0) {
          if (previous.result.version !== 1 || !validDocumentId(previous.result.id)) {
            error = failure("The browser recovery binding is invalid.");
            tx.abort();
            return;
          }
          store.put({ version: 1, id: id2 }, key);
          return;
        }
        const count2 = store.count(IDBKeyRange.bound([workspace], [workspace, []], false, true));
        count2.onsuccess = () => {
          if (count2.result >= 16384) {
            error = failure("The workspace browser recovery binding limit was reached.");
            tx.abort();
          } else store.put({ version: 1, id: id2 }, key);
        };
      };
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not preserve the browser recovery binding."));
    });
  }
  close() {
    const opening = this.opening;
    this.opening = null;
    void opening?.then((db) => db.close(), () => {
    });
  }
};
function sourceName(name, workspace) {
  try {
    const value = JSON.parse(name.slice("rayde:v2:".length));
    return name.startsWith("rayde:v2:") && Array.isArray(value) && value.length === 2 && value[0] === workspace && !!pathKey(value[1]);
  } catch {
    return false;
  }
}
function sources(names, workspace) {
  if (!Array.isArray(names) || names.some((name) => typeof name !== "string" || !sourceName(name, workspace))) throw failure("The legacy recovery links are invalid.");
  const result = [...new Set(names)];
  if (result.length > 16) throw failure("The legacy recovery link limit was reached.");
  return result;
}
function binding(value) {
  if (value !== void 0 && (value.version !== 1 || !validDocumentId(value.id) || !Number.isSafeInteger(value.copied) || value.copied < 0)) throw failure("The legacy recovery binding is invalid.");
  return value ?? null;
}
async function readLegacy(name, load = false) {
  const db = await openDatabase(name, false);
  if (!db) return null;
  const doc2 = load ? new Doc() : null;
  try {
    if (!db.objectStoreNames.contains("updates") || !db.objectStoreNames.contains("custom")) throw failure("The legacy recovery store is invalid.");
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(["updates", "custom"], "readonly"), meta = tx.objectStore("custom").get(LEGACY);
      let last2 = 0, bytes = 0, count2 = 0, error;
      const cursor = load ? tx.objectStore("updates").openCursor() : tx.objectStore("updates").openKeyCursor(null, "prev");
      cursor.onsuccess = () => {
        const entry2 = cursor.result;
        if (!entry2) return;
        try {
          if (!Number.isSafeInteger(entry2.key) || entry2.key < 1) throw failure("The legacy recovery sequence is invalid.");
          last2 = Math.max(last2, entry2.key);
          if (load) {
            const update = entry2.value instanceof ArrayBuffer ? new Uint8Array(entry2.value) : entry2.value;
            if (!(update instanceof Uint8Array) || (bytes += update.byteLength) > MAX_INPUT || ++count2 > 2e4) throw failure("The legacy recovery exceeds its migration limit.");
            applyUpdate(doc2, update);
            entry2.continue();
          }
        } catch (caught) {
          error = caught;
          tx.abort();
        }
      };
      tx.oncomplete = () => {
        try {
          const result = { name, last: last2, binding: binding(meta.result) };
          if (doc2) {
            if (doc2.store.pendingStructs || doc2.store.pendingDs) throw failure("The legacy recovery is incomplete.");
            result.update = encodeStateAsUpdate(doc2);
            result.vector = encodeStateVector(doc2);
            if (result.update.length > MAX_GRAPH) throw failure("The legacy graph exceeds its migration limit.");
          }
          resolve(result);
        } catch (error2) {
          reject(error2);
        }
      };
      tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not read legacy browser recovery."));
    });
  } finally {
    doc2?.destroy();
    db.close();
  }
}
async function recoveryHeader(workspace, id2) {
  const db = await openDatabase(recoveryName(workspace, id2), false);
  if (!db) return null;
  let header;
  try {
    header = await new Promise((resolve, reject) => {
      const tx = db.transaction("custom", "readonly"), request = tx.objectStore("custom").get(HEADER);
      tx.oncomplete = () => resolve(request.result);
      tx.onerror = tx.onabort = () => reject(tx.error ?? failure("Could not read browser recovery."));
    });
  } finally {
    db.close();
  }
  if (header === void 0) return null;
  if (header.version !== 1 || header.workspace !== workspace || header.id !== id2) throw failure("The document recovery identity does not match.");
  sources(header.sources, workspace);
  return header;
}
function checkpointRecovery(persistence, doc2, workspace, id2, names = [], snapshot = false) {
  names = sources(names, workspace);
  return new Promise((resolve, reject) => {
    const tx = persistence.db.transaction(["updates", "custom"], "readwrite"), store = tx.objectStore("custom"), previous = store.get(HEADER);
    let error;
    previous.onsuccess = () => {
      try {
        const old = previous.result;
        if (old && (old.version !== 1 || old.workspace !== workspace || old.id !== id2)) throw failure("The document recovery identity does not match.");
        const linked = sources([...old?.sources ?? [], ...names], workspace);
        if (snapshot || !old) {
          const update = encodeStateAsUpdate(doc2);
          if (update.length > MAX_GRAPH) throw failure("The document exceeds the browser recovery limit.");
          tx.objectStore("updates").add(update);
        }
        store.put({ version: 1, workspace, id: id2, sources: linked }, HEADER);
      } catch (caught) {
        error = caught;
        tx.abort();
      }
    };
    tx.oncomplete = () => resolve();
    tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not preserve identity-bound browser recovery."));
  });
}
async function markLegacy(source, id2) {
  const db = await openDatabase(source.name, false);
  if (!db) return;
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction("custom", "readwrite"), store = tx.objectStore("custom"), request = store.get(LEGACY);
      let error;
      request.onsuccess = () => {
        try {
          const old = binding(request.result);
          if (old?.id !== source.binding?.id && old?.id !== id2) return;
          store.put({ version: 1, id: id2, copied: Math.max(old?.copied ?? 0, source.last) }, LEGACY);
        } catch (caught) {
          error = caught;
          tx.abort();
        }
      };
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not finish the browser recovery migration."));
    });
  } finally {
    db.close();
  }
}

// src/client.js
function cacheNamespace(address, identity) {
  if (identity?.version !== 1 || ![identity.authority, identity.workspace, identity.principal].every((value) => typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\u0000-\u001f]/.test(value))) return null;
  const endpoint2 = new URL(address);
  return JSON.stringify([2, endpoint2.origin, endpoint2.pathname, identity.authority, identity.workspace, identity.principal]);
}
var b64 = {
  encode(bytes) {
    let text2 = "";
    for (let i = 0; i < bytes.length; i += 32768) text2 += String.fromCharCode(...bytes.subarray(i, i + 32768));
    return btoa(text2);
  },
  decode(text2) {
    const raw = atob(text2);
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }
};
var SessionError = class extends Error {
  constructor(reply) {
    super(reply.message ?? reply.code);
    this.code = reply.code;
    this.login = reply.login ?? null;
  }
};
var Doc2 = class {
  constructor(client, path) {
    this.client = client;
    this.path = path;
    this.workspace = client.workspace;
    this.ydoc = new Doc();
    this.text = this.ydoc.getText("text");
    this.closed = false;
    this.unsent = false;
    this.inflight = 0;
    this.failed = false;
    this.listeners = /* @__PURE__ */ new Set();
    this.persistence = null;
    this.persistences = /* @__PURE__ */ new Set();
    this.documentId = null;
    this.suspended = false;
    this.abort = new AbortController();
    this.pending = /* @__PURE__ */ new Set();
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
  start() {
    return this.sync();
  }
  get persistent() {
    return this.client.options?.persist !== false && this.client.cacheable && typeof indexedDB !== "undefined";
  }
  guard() {
    if (this.closed) throw new Error("The shared document is closed.");
    if (this.blocked) throw this.blocked;
    if (this.client.invalidated) throw this.client.invalidated;
  }
  identify(id2) {
    this.guard();
    if (!validDocumentId(id2)) throw Object.assign(new Error("The workspace returned an invalid document identity."), { code: "recovery-failed" });
    if (this.documentId && this.documentId !== id2) throw Object.assign(new Error("The path belongs to a different document. Reopen it to continue; its previous edits are kept in this browser."), { code: "document-changed" });
    const owner = this.client.documentIds?.get(id2);
    if (owner && owner !== this) throw Object.assign(new Error("This document already has an editor binding through another path."), { code: "document-open" });
    this.documentId = id2;
    this.client.documentIds?.set(id2, this);
  }
  async recover(name) {
    if (!this.persistent || this.persistence?.name === name) return;
    this.guard();
    const persistence = new IndexeddbPersistence(name, this.ydoc);
    this.persistences.add(persistence);
    await new Promise((resolve, reject) => {
      const finish = (error) => {
        clearTimeout(timer);
        this.abort.signal.removeEventListener("abort", cancel);
        error ? reject(error) : resolve();
      };
      const cancel = () => finish(new Error("The shared document is closed."));
      const timer = setTimeout(() => finish(Object.assign(new Error("Browser document recovery did not open in time."), { code: "recovery-failed" })), 3e4);
      this.abort.signal.addEventListener("abort", cancel, { once: true });
      persistence.whenSynced.then(() => finish(), finish);
      persistence._db.catch(finish);
    });
    this.guard();
    this.persistence = persistence;
  }
  async releaseOtherRecovery() {
    for (const persistence of this.persistences) if (persistence !== this.persistence) {
      await persistence.destroy();
      this.persistences.delete(persistence);
    }
  }
  async moveRecovery() {
    this.suspended = true;
    if (this.closed) return;
    await this.checkpointGraph();
    await Promise.all([...this.persistences].map((store) => store.destroy()));
    this.persistences.clear();
    this.persistence = null;
    this.workspace = this.client.workspace;
    if (this.documentId) {
      await this.recover(recoveryName(this.workspace, this.documentId));
      if (this.persistence) {
        await checkpointRecovery(this.persistence, this.ydoc, this.workspace, this.documentId, [], true);
        await this.client.recoveryDirectory.put(this.workspace, this.path, this.documentId);
      }
    } else {
      await this.recover(legacyName(this.workspace, this.path));
      await this.checkpointGraph();
    }
    await this.releaseOtherRecovery();
  }
  async checkpointGraph() {
    const persistence = this.persistence;
    if (!persistence || this.closed) return;
    await new Promise((resolve, reject) => {
      const tx = persistence.db.transaction("updates", "readwrite");
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(tx.error ?? new Error("Could not preserve document recovery."));
      tx.objectStore("updates").add(encodeStateAsUpdate(this.ydoc));
    });
  }
  async checkpoint() {
    await this.started?.catch(() => {
    });
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
    const clear = () => {
      if (this.syncing === work) this.syncing = null;
    };
    work.then(clear, clear);
    return work;
  }
  async synchronize() {
    if (this.closed) return;
    this.guard();
    this.suspended = true;
    try {
      if (this.documentId && this.client.hello?.documentIdentities !== 1) throw Object.assign(new Error("The workspace no longer verifies document identities. Reopen it before continuing."), { code: "document-changed" });
      if (!this.client.ready) {
        if (!this.persistence && this.persistent) {
          const id2 = await this.client.recoveryDirectory.get(this.workspace, this.path);
          this.guard();
          if (id2) {
            if (!await recoveryHeader(this.workspace, id2)) throw Object.assign(new Error("The document's verified recovery is unavailable. Reconnect before opening it."), { code: "recovery-failed" });
            this.identify(id2);
            await this.recover(recoveryName(this.workspace, id2));
          } else if (await readLegacy(legacyName(this.workspace, this.path))) await this.recover(legacyName(this.workspace, this.path));
        }
        if (!this.persistence && encodeStateVector(this.ydoc).length <= 1) throw new Error("Reconnect before opening a document without browser recovery.");
        return;
      }
      let reply;
      if (this.client.hello?.documentIdentities === 1) reply = await this.synchronizeIdentity();
      else {
        await this.recover(legacyName(this.workspace, this.path));
        this.guard();
        reply = await this.open();
        this.identityHint = validDocumentId(reply.documentId) ? reply.documentId : null;
        this.applyReply(reply);
        await this.releaseOtherRecovery();
      }
      this.guard();
      const missing = encodeStateAsUpdate(this.ydoc, b64.decode(reply.vector));
      this.failed = false;
      this.suspended = false;
      if (missing.length > 2 || this.client.hello?.durableUpdates) await this.send(missing);
      else if (this.inflight === 0) this.unsent = false;
      this.listeners.forEach((listener) => listener("synced"));
    } catch (error) {
      this.fence(error);
      throw error;
    }
  }
  open(vector = encodeStateVector(this.ydoc), expected = this.documentId) {
    this.guard();
    return this.client.request("doc.open", { path: this.path, vector: b64.encode(vector), ...expected ? { documentId: expected } : {} });
  }
  applyReply(reply) {
    this.guard();
    if (this.documentId) this.identify(reply.documentId);
    this.restoredDirty = reply.buffered === true && reply.dirty === true;
    applyUpdate(this.ydoc, b64.decode(reply.update), "session");
  }
  async synchronizeIdentity() {
    const name = legacyName(this.workspace, this.path);
    const legacy = this.persistent ? await readLegacy(name) : null;
    let reply, proven = null;
    if (!this.documentId) {
      if (legacy?.last && !legacy.binding || encodeStateVector(this.ydoc).length > 1) {
        if (legacy?.last && !legacy.binding) proven = await readLegacy(name, true);
        reply = await this.open(proven?.vector ?? encodeStateVector(this.ydoc), proven?.binding?.id ?? this.identityHint);
      } else {
        this.guard();
        const lookup = this.client.hello.documentLookup === 1 ? await this.client.request("doc.lookup", { path: this.path }) : null;
        if (lookup?.documentId) this.identify(lookup.documentId);
        else reply = await this.open(new Uint8Array([0]));
      }
      this.guard();
      if (reply) this.identify(reply.documentId);
    }
    const id2 = this.documentId;
    const header = this.persistent ? await recoveryHeader(this.workspace, id2) : null;
    await this.recover(recoveryName(this.workspace, id2));
    const migrated = [];
    if (proven) {
      applyUpdate(this.ydoc, proven.update, "recovery");
      migrated.push(proven);
    }
    const names = /* @__PURE__ */ new Set([name, ...header?.sources ?? []]);
    for (const sourceName2 of names) {
      if (proven?.name === sourceName2) continue;
      const source = sourceName2 === name ? legacy : await readLegacy(sourceName2);
      if (source?.binding?.id !== id2 || header && source.last <= source.binding.copied) continue;
      const loaded = await readLegacy(sourceName2, true);
      if (!loaded || loaded.binding?.id !== id2) continue;
      this.guard();
      applyUpdate(this.ydoc, loaded.update, "recovery");
      migrated.push(loaded);
    }
    this.guard();
    reply ??= await this.open();
    this.applyReply(reply);
    if (this.persistence) {
      await checkpointRecovery(this.persistence, this.ydoc, this.workspace, id2, migrated.map((source) => source.name), migrated.length > 0);
      await this.client.recoveryDirectory.put(this.workspace, this.path, id2);
      for (const source of migrated) await markLegacy(source, id2);
    }
    await this.releaseOtherRecovery();
    return reply;
  }
  fence(error) {
    this.failed = true;
    if (!["document-changed", "identity-required", "recovery-failed"].includes(error.code) || this.closed) return;
    this.blocked = error;
    this.suspended = true;
    this.client.emit?.("document-error", { path: this.path, documentId: this.documentId, code: error.code, message: error.message });
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
      await this.client.request("doc.update", { path: this.path, update: b64.encode(update), ...this.documentId ? { documentId: this.documentId } : {} });
      this.acknowledgedVersion = Math.max(this.acknowledgedVersion, version);
    } catch (error) {
      this.fence(error);
      if (error.code === "auth-required") this.client.needSignIn(error.login);
    } finally {
      if (--this.inflight === 0 && !this.failed && this.acknowledgedVersion === this.localVersion) this.unsent = false;
    }
  }
  async save() {
    this.guard();
    if (this.started) await this.started;
    await Promise.all([...this.pending]);
    if (this.syncing) await this.syncing;
    if (this.closed) throw new Error("The shared document is closed.");
    if (this.unsent) await this.sync();
    if (this.unsent) throw new Error("Reconnect before saving this document. Its edits are kept in this browser.");
    this.guard();
    try {
      return await this.client.request("doc.save", { path: this.path, ...this.documentId ? { documentId: this.documentId } : {} });
    } catch (error) {
      this.fence(error);
      throw error;
    }
  }
  close() {
    if (this.closing) return this.closing;
    this.closed = true;
    this.abort.abort();
    this.closing = (async () => {
      await Promise.all([...this.persistences].map((store) => {
        const closing = store.destroy();
        if (store.db) return closing;
        void closing.catch(() => {
        });
      }));
      this.persistences.clear();
      this.ydoc.destroy();
      this.listeners.clear();
      if (this.client.ready) await this.client.request("doc.close", { path: this.path }).catch(() => {
      });
      if (this.client.documentIds?.get(this.documentId) === this) this.client.documentIds.delete(this.documentId);
      if (this.client.docs.get(this.path) === this) this.client.docs.delete(this.path);
    })();
    return this.closing;
  }
};
var SessionClient = class {
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
    this.waiting = /* @__PURE__ */ new Map();
    this.docs = /* @__PURE__ */ new Map();
    this.documentIds = /* @__PURE__ */ new Map();
    this.recoveryDirectory = new RecoveryDirectory();
    this.handlers = /* @__PURE__ */ new Map();
    this.pendingAuth = false;
    this.identity = null;
    this.credential = options.credential ?? null;
    this.stopped = false;
    this.attempt = 0;
    this.generation = 0;
  }
  on(event, handler) {
    if (!this.handlers.has(event)) this.handlers.set(event, /* @__PURE__ */ new Set());
    this.handlers.get(event).add(handler);
    return () => this.handlers.get(event).delete(handler);
  }
  emit(event, detail) {
    this.handlers.get(event)?.forEach((handler) => handler(detail));
  }
  invalidate() {
    if (this.invalidated) return this.invalidated;
    const error = this.invalidated = new SessionError({ code: "workspace-changed", message: "The workspace or account changed. Reopen it to continue; your previous recovery data is kept in this browser." });
    this.stopped = true;
    this.ready = false;
    this.generation++;
    for (const reply of this.waiting.values()) reply.reject(error);
    this.waiting.clear();
    this.emit("context-changed", { message: error.message });
    this.socket?.close();
    return error;
  }
  context(identity) {
    const stable = cacheNamespace(this.options.url, identity);
    return { key: stable ?? JSON.stringify(["volatile", this.volatile]), cacheable: stable !== null };
  }
  /** Connects, and keeps reconnecting until `close()`. Resolves when the first connection is ready. */
  connect() {
    return new Promise((resolve, reject) => {
      let first = true;
      const initial = setTimeout(() => {
        if (first) {
          first = false;
          this.close();
          reject(new Error("The workspace session did not connect in time."));
        }
      }, this.options.timeout ?? 3e4);
      const open = () => {
        if (this.stopped) return;
        const socket = new WebSocket(this.options.url);
        this.socket = socket;
        socket.onmessage = (message) => {
          if (this.socket === socket && !this.invalidated) this.receive(JSON.parse(message.data));
        };
        socket.onopen = async () => {
          try {
            if (this.socket !== socket || this.stopped) return;
            this.hello = await this.rawRequest("hello", { token: this.options.token });
            this.identity = null;
            if (this.credential) {
              try {
                const reply = await this.rawRequest("auth.login", { credential: this.credential });
                this.identity = { login: reply.login, id: reply.id };
                this.hello.cacheIdentity = reply.cacheIdentity;
              } catch {
                this.pendingAuth = true;
              }
            }
            if (this.socket !== socket || socket.readyState !== WebSocket.OPEN || this.stopped) throw new Error("The connection closed during sign-in.");
            const context = this.context(this.hello.cacheIdentity);
            if (this.workspace !== null && (context.key !== this.workspace || !context.cacheable && this.docs.size > 0)) throw this.invalidate();
            this.workspace = context.key;
            this.cacheable = context.cacheable;
            this.cacheIdentity = this.hello.cacheIdentity;
            this.ready = true;
            this.attempt = 0;
            this.pendingAuth = !!this.hello.signin && !this.identity;
            this.emit("connected", this.hello);
            await Promise.all([...this.docs.values()].map((doc2) => doc2.sync().catch(() => {
            })));
            if (first) {
              first = false;
              clearTimeout(initial);
              resolve(this.hello);
            }
          } catch (error) {
            if (first) {
              first = false;
              clearTimeout(initial);
              this.close();
              reject(error);
            } else if (this.socket === socket) socket.close();
          }
        };
        socket.onclose = () => {
          if (this.socket !== socket) return;
          const wasReady = this.ready;
          this.ready = false;
          if (wasReady) {
            this.generation++;
            this.emit("disconnected");
          }
          for (const [, reply] of this.waiting) reply.reject(new Error("The connection closed."));
          this.waiting.clear();
          if (first && !wasReady && this.options.reconnect === false) {
            first = false;
            clearTimeout(initial);
            reject(new Error("Could not connect."));
          }
          if (!this.stopped && this.options.reconnect !== false) setTimeout(open, Math.min(250 * 2 ** this.attempt++, 5e3));
        };
      };
      open();
    });
  }
  receive(message) {
    if (message.id !== void 0 && this.waiting.has(message.id)) {
      const reply = this.waiting.get(message.id);
      this.waiting.delete(message.id);
      message.ok ? reply.resolve(message) : reply.reject(new SessionError(message));
    } else if (message.ev === "doc.update") {
      const doc2 = this.docs.get(message.path);
      if (doc2 && !doc2.closed && !doc2.blocked) {
        applyUpdate(doc2.ydoc, b64.decode(message.update), "session");
        doc2.listeners.forEach((listener) => listener("remote"));
      }
    } else if (message.ev) {
      this.emit(message.ev, message);
    }
  }
  rawRequest(op, params2 = {}) {
    return new Promise((resolve, reject) => {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return reject(new Error("Not connected."));
      if (this.waiting.size >= 4096) return reject(new Error("Too many session requests are waiting."));
      const id2 = this.next++;
      const timer = setTimeout(() => {
        this.waiting.delete(id2);
        reject(new Error(`The session did not answer ${op}.`));
      }, this.options.timeout ?? 6e4);
      this.waiting.set(id2, {
        resolve(value) {
          clearTimeout(timer);
          resolve(value);
        },
        reject(error) {
          clearTimeout(timer);
          reject(error);
        }
      });
      try {
        this.socket.send(JSON.stringify({ ...params2, op, id: id2 }));
      } catch (error) {
        this.waiting.get(id2).reject(error);
        this.waiting.delete(id2);
      }
    });
  }
  request(op, params2) {
    if (this.invalidated) return Promise.reject(this.invalidated);
    if (!this.ready) return Promise.reject(new Error("Not connected."));
    return this.rawRequest(op, params2);
  }
  /** The local bridge fences process handles before forwarding onto a replacement connection. */
  forward(op, params2 = {}) {
    if ((op.startsWith("proc.") || op.startsWith("term.")) && params2.sessionGeneration !== void 0) {
      if (params2.sessionGeneration !== this.generation) return Promise.reject(new Error("The program belongs to a disconnected session."));
      params2 = { ...params2 };
      delete params2.sessionGeneration;
    }
    return this.request(op, params2);
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
    const clear = () => {
      if (this.authentication === work) this.authentication = null;
    };
    work.then(clear, clear);
    return work;
  }
  async authenticate(credential) {
    if (!this.ready || this.invalidated) throw this.invalidated ?? new Error("Not connected.");
    const socket = this.socket;
    this.authenticating = true;
    try {
      const reply = await this.rawRequest("auth.login", { credential });
      const context = this.context(reply.cacheIdentity), previous = this.cacheIdentity;
      if (this.identity && this.identity.id !== reply.id || this.workspace !== context.key && !(previous?.principal === "viewer" && previous.authority === reply.cacheIdentity?.authority && previous.workspace === reply.cacheIdentity?.workspace)) throw this.invalidate();
      const documents = [...this.docs.values()];
      await Promise.all(documents.map((doc2) => doc2.started?.catch(() => {
      })));
      if (this.socket !== socket || !this.ready || this.invalidated) throw this.invalidated ?? new Error("The connection closed during sign-in.");
      this.credential = credential;
      this.identity = { login: reply.login, id: reply.id };
      this.workspace = context.key;
      this.cacheable = context.cacheable;
      this.cacheIdentity = reply.cacheIdentity;
      this.hello.cacheIdentity = reply.cacheIdentity;
      try {
        await Promise.all(documents.filter((doc2) => doc2.workspace !== this.workspace).map((doc2) => doc2.moveRecovery()));
      } catch (error) {
        this.invalidate();
        throw error;
      }
      this.pendingAuth = false;
      this.emit("signed-in", this.identity);
    } finally {
      this.authenticating = false;
    }
    await Promise.all([...this.docs.values()].map((doc2) => doc2.sync().catch(() => {
    })));
    return this.identity;
  }
  async openDoc(path) {
    if (this.authentication) await this.authentication;
    if (this.invalidated) throw this.invalidated;
    let doc2 = this.docs.get(path);
    if (doc2?.closed) {
      await doc2.close();
      return this.openDoc(path);
    }
    if (!doc2) {
      doc2 = new Doc2(this, path);
      this.docs.set(path, doc2);
      doc2.started = doc2.start();
    }
    try {
      await doc2.started;
    } catch (error) {
      await doc2.close();
      throw error;
    }
    return doc2;
  }
  list(path = "") {
    return this.request("fs.list", { path }).then((r) => r.entries);
  }
  stat(path) {
    return this.request("fs.stat", { path }).then((r) => r.entry);
  }
  read(path) {
    return this.request("fs.read", { path }).then((r) => r.data);
  }
  write(path, data) {
    return this.request("fs.write", { path, data });
  }
  mkdir(path) {
    return this.request("fs.mkdir", { path });
  }
  remove(path, recursive = false) {
    return this.request("fs.remove", { path, recursive });
  }
  rename(from2, to) {
    return this.request("fs.rename", { from: from2, to });
  }
  /** Runs a program in the session; output arrives as `proc.out` and `proc.exit` events. */
  spawn(command, args2 = [], cwd = "") {
    return this.request("proc.spawn", { command, args: args2, cwd }).then((r) => r.pid);
  }
  close() {
    this.stopped = true;
    this.recoveryDirectory.close();
    this.socket?.close();
  }
};

// src/editor.js
var LOCAL = Symbol("editor");
var REMOTE = Symbol("projection");
function edit(text2, parts) {
  const before = text2.toString();
  let end = 0;
  for (const part of parts) {
    if (!Number.isSafeInteger(part.from) || part.from < end || typeof part.removed !== "string" || typeof part.inserted !== "string" || part.from + part.removed.length > before.length || before.slice(part.from, part.from + part.removed.length) !== part.removed)
      throw new Error("The editor transaction does not match its document.");
    end = part.from + part.removed.length;
  }
  for (const part of parts.toReversed()) {
    if (part.removed.length) text2.delete(part.from, part.removed.length);
    if (part.inserted.length) text2.insert(part.from, part.inserted);
  }
}
function changes(doc2, run) {
  const text2 = doc2.getText("text"), before = text2.toString(), parts = [];
  const observe = (event) => {
    let at2 = 0, part = null;
    for (const change of event.delta) {
      if (change.retain) {
        at2 += change.retain;
        part = null;
      } else {
        if (!part) {
          part = { from: at2, removed: "", inserted: "" };
          parts.push(part);
        }
        if (change.delete) {
          part.removed += before.slice(at2, at2 + change.delete);
          at2 += change.delete;
        }
        if (change.insert) part.inserted += change.insert;
      }
    }
  };
  text2.observe(observe);
  try {
    run();
  } finally {
    text2.unobserve(observe);
  }
  return parts;
}
var EditorDocument = class {
  constructor(doc2, handle, emit) {
    this.doc = doc2;
    this.handle = handle;
    this.emit = emit;
    this.shadow = new Doc();
    applyUpdate(this.shadow, encodeStateAsUpdate(doc2.ydoc), REMOTE);
    this.text = this.shadow.getText("text");
    this.undo = new UndoManager(this.text, { trackedOrigins: /* @__PURE__ */ new Set([LOCAL]), captureTimeout: 0 });
    this.serial = this.epoch = this.version = this.undoBytes = 0;
    this.ready = this.dirty = this.closed = false;
    this.offer = null;
    this.project = (update, origin) => {
      this.version++;
      if (origin !== this) {
        this.dirty = true;
        this.offerRemote();
      }
    };
    this.publish = (update, origin) => {
      if (origin === LOCAL || origin === this.undo) applyUpdate(doc2.ydoc, update, this);
    };
    doc2.ydoc.on("update", this.project);
    this.shadow.on("update", this.publish);
  }
  snapshot() {
    return { text: this.text.toString(), epoch: this.epoch, serial: this.serial, ...this.doc.restoredDirty ? { dirty: true } : {} };
  }
  local(request) {
    if (!this.ready || request.epoch !== this.epoch || request.serial !== this.serial + 1 || !Array.isArray(request.parts))
      throw new Error("The editor transaction is out of sequence.");
    this.shadow.transact(() => edit(this.text, request.parts), LOCAL);
    this.serial++;
    this.undoBytes += request.parts.reduce((size2, part) => size2 + 2 * (part.removed.length + part.inserted.length) + 64, 0);
    if (this.undoBytes > 1024 * 1024 || this.undo.undoStack.length > 100) {
      this.undo.clear();
      this.undoBytes = 0;
    }
  }
  reverse(request) {
    if (!this.ready || request.epoch !== this.epoch || request.serial !== this.serial + 1)
      throw new Error("The editor undo is out of sequence.");
    const parts = changes(this.shadow, () => request.redo ? this.undo.redo() : this.undo.undo());
    this.serial++;
    return { ...this.snapshot(), parts };
  }
  offerRemote() {
    if (this.closed || !this.ready || !this.dirty || this.offer) return;
    const update = encodeStateAsUpdate(this.doc.ydoc, encodeStateVector(this.shadow));
    const probe = new Doc();
    applyUpdate(probe, encodeStateAsUpdate(this.shadow), REMOTE);
    const parts = changes(probe, () => applyUpdate(probe, update, REMOTE));
    const text2 = probe.getText("text").toString();
    probe.destroy();
    this.offer = { update, version: this.version, epoch: this.epoch + 1, serial: this.serial };
    this.emit({ ev: "view.remote", handle: this.handle, text: text2, parts, epoch: this.offer.epoch, serial: this.serial });
  }
  acknowledge(request) {
    const offer = this.offer;
    if (!offer || request.epoch !== offer.epoch) throw new Error("The editor acknowledgement is out of sequence.");
    if (request.accept) {
      if (offer.serial !== this.serial) throw new Error("The editor acknowledged an obsolete projection.");
      applyUpdate(this.shadow, offer.update, REMOTE);
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
};
var EditorDocuments = class {
  constructor(client, emit) {
    this.client = client;
    this.emit = emit;
    this.documents = /* @__PURE__ */ new Map();
    this.queues = /* @__PURE__ */ new Map();
    this.opening = /* @__PURE__ */ new Set();
    this.closed = false;
    this.failure = null;
    this.unsubscribe = client.on?.("context-changed", ({ message }) => {
      this.failure = message;
      for (const view of this.documents.values()) {
        view.ready = false;
        this.emit({ ev: "view.error", handle: view.handle, code: "workspace-changed", message });
      }
    });
    this.unsubscribeDocument = client.on?.("document-error", ({ path, code, message }) => {
      for (const view of this.documents.values()) if (view.doc.path === path) {
        view.ready = false;
        this.emit({ ev: "view.error", handle: view.handle, code, message });
      }
    });
  }
  request(op, request) {
    const handle = request.handle;
    if (typeof handle !== "string" || handle.length > 1024) return Promise.reject(new Error("Invalid editor handle."));
    const work = (this.queues.get(handle) ?? Promise.resolve()).catch(() => {
    }).then(async () => {
      if (this.closed) throw new Error("The editor session is closed.");
      if (this.failure && op !== "view.close") throw new Error(this.failure);
      if (op === "view.open") {
        if (this.documents.has(handle) || this.documents.size + this.opening.size >= 256) throw new Error("Too many shared documents are open.");
        if (typeof request.path !== "string" || this.opening.has(request.path) || [...this.documents.values()].some((view3) => view3.doc.path === request.path)) throw new Error("This document already has an editor binding.");
        this.opening.add(request.path);
        let doc2;
        try {
          doc2 = await this.client.openDoc(request.path);
        } finally {
          this.opening.delete(request.path);
        }
        if (this.closed || this.failure) {
          await doc2.close();
          throw new Error(this.failure ?? "The editor session is closed.");
        }
        const view2 = new EditorDocument(doc2, handle, this.emit);
        this.documents.set(handle, view2);
        return view2.snapshot();
      }
      const view = this.documents.get(handle);
      if (!view) {
        if (op === "view.close") return {};
        throw new Error("The shared document is closed.");
      }
      if (view.doc.blocked && op !== "view.close") throw view.doc.blocked;
      if (op === "view.ready") {
        view.ready = true;
        view.offerRemote();
      } else if (op === "view.edit") view.local(request);
      else if (op === "view.ack") view.acknowledge(request);
      else if (op === "view.undo") return view.reverse(request);
      else if (op === "view.save") return { saved: view.doc.save() };
      else if (op === "view.close") {
        view.dispose();
        this.documents.delete(handle);
        await view.doc.close();
      } else throw new Error("Unknown editor operation.");
      return {};
    });
    this.queues.set(handle, work);
    const cleanup = () => {
      if (this.queues.get(handle) === work) this.queues.delete(handle);
    };
    work.then(cleanup, cleanup);
    return op === "view.save" ? work.then((reply) => reply.saved) : work;
  }
  close() {
    this.closed = true;
    this.unsubscribe?.();
    this.unsubscribeDocument?.();
    for (const view of this.documents.values()) {
      view.dispose();
      void view.doc.close();
    }
    this.documents.clear();
  }
};

// node_modules/marked/lib/marked.esm.js
function B() {
  return { async: false, breaks: false, extensions: null, gfm: true, hooks: null, pedantic: false, renderer: null, silent: false, tokenizer: null, walkTokens: null };
}
var y = B();
function V(a3) {
  y = a3;
}
var M = { exec: () => null };
function D(a3) {
  let e = [];
  return (t) => {
    let n = Math.max(0, Math.min(3, t - 1)), i = e[n];
    return i || (i = a3(n), e[n] = i), i;
  };
}
function h(a3, e = "") {
  let t = typeof a3 == "string" ? a3 : a3.source, n = { replace: (i, r) => {
    let o = typeof r == "string" ? r : r.source;
    return o = o.replace(x.caret, "$1"), t = t.replace(i, o), n;
  }, getRegex: () => new RegExp(t, e) };
  return n;
}
var ze = ((a3 = "") => {
  try {
    return !!new RegExp("(?<=1)(?<!1)" + a3);
  } catch {
    return false;
  }
})();
var x = { codeRemoveIndent: /^(?: {0,3}\t| {1,4})/gm, outputLinkReplace: /\\([\[\]])/g, indentCodeCompensation: /^(\s+)(?:```)/, beginningSpace: /^\s+/, endingHash: /#$/, startingSpaceChar: /^ /, endingSpaceChar: / $/, endingSpaceTabChar: /[ \t]$/, nonSpaceChar: /[^ ]/, newLineCharGlobal: /\n/g, tabCharGlobal: /\t/g, leadingSpaceTab: /^[ \t]+/, multipleSpaceGlobal: /\s+/g, blankLine: /^[ \t]*$/, doubleBlankLine: /\n[ \t]*\n[ \t]*$/, blockquoteStart: /^ {0,3}>/, blockquoteSetextReplace: /\n {0,3}((?:=+|-+) *)(?=\n|$)/g, blockquoteSetextReplace2: /^ {0,3}>[ \t]?/gm, listReplaceNesting: /^ {1,4}(?=( {4})*[^ ])/g, listIsTask: /^\[[ xX]\] +\S/, listReplaceTask: /^\[[ xX]\] +/, listTaskCheckbox: /\[[ xX]\]/, anyLine: /\n.*\n/, hrefBrackets: /^<(.*)>$/, tableDelimiter: /[:|]/, tableAlignChars: /^\||\| *$/g, tableRowBlankLine: /\n[ \t]*$/, tableAlignRight: /^ *-+: *$/, tableAlignCenter: /^ *:-+: *$/, tableAlignLeft: /^ *:-+ *$/, startATag: /^<a /i, endATag: /^<\/a>/i, startPreScriptTag: /^<(pre|code|kbd|script)(\s|>)/i, endPreScriptTag: /^<\/(pre|code|kbd|script)(\s|>)/i, startAngleBracket: /^</, endAngleBracket: />$/, pedanticHrefTitle: /^([^'"]*[^\s])\s+(['"])(.*)\2/, unicodeAlphaNumeric: /[\p{L}\p{N}]/u, numericCharacterReference: /&#(?:(\d{1,7})|[Xx]([A-Fa-f0-9]{1,6}));/, numericCharacterReferenceOrAmpersand: /&#(?:(\d{1,7})|[Xx]([A-Fa-f0-9]{1,6}));|&(?!(#\d{1,7}|#[Xx][a-fA-F0-9]{1,6}|\w+);)/g, escapeTest: /[&<>"']/, escapeReplace: /[&<>"']/g, escapeTestNoEncode: /[<>"']|&(?!(#\d{1,7}|#[Xx][a-fA-F0-9]{1,6}|\w+);)/, escapeReplaceNoEncode: /[<>"']|&(?!(#\d{1,7}|#[Xx][a-fA-F0-9]{1,6}|\w+);)/g, caret: /(^|[^\[])\^/g, percentDecode: /%25/g, findPipe: /\|/g, splitPipe: / \|/, slashPipe: /\\\|/g, carriageReturn: /\r\n|\r/g, spaceLine: /^ +$/gm, notSpaceStart: /^\S*/, endingNewline: /\n$/, listItemRegex: (a3) => new RegExp(`^( {0,3}${a3})((?:[	 ][^\\n]*)?(?:\\n|$))`), nextBulletRegex: D((a3) => new RegExp(`^ {0,${a3}}(?:[*+-]|\\d{1,9}[.)])((?:[ 	][^\\n]*)?(?:\\n|$))`)), hrRegex: D((a3) => new RegExp(`^ {0,${a3}}((?:-[ 	]*){3,}|(?:_[ 	]*){3,}|(?:\\*[ 	]*){3,})(?:\\n+|$)`)), fencesBeginRegex: D((a3) => new RegExp(`^ {0,${a3}}(?:\`\`\`|~~~)`)), headingBeginRegex: D((a3) => new RegExp(`^ {0,${a3}}#`)), htmlBeginRegex: D((a3) => new RegExp(`^ {0,${a3}}(?:</?(?:${Q})(?: +|$|/?>)|<(?:(?:script|pre|style|textarea)(?:[\\s>]|$)|!--)|<\\?|<![A-Za-z]|<!\\[CDATA\\[)`, "i")), blockquoteBeginRegex: D((a3) => new RegExp(`^ {0,${a3}}>`)) };
var Ee = /^(?:[ \t]*(?:\n|$))+/;
var Me = /^((?: {4}| {0,3}\t)[^\n]+(?:\n(?:[ \t]*(?:\n|$))*)?)+/;
var Ce = /^ {0,3}(`{3,}(?=[^`\n]*(?:\n|$))|~{3,})([^\n]*)(?:\n|$)(?:|([\s\S]*?)(?:\n|$))(?: {0,3}\1[~`]* *(?=\n|$)|$)/;
var N = /^ {0,3}((?:-[\t ]*){3,}|(?:_[ \t]*){3,}|(?:\*[ \t]*){3,})(?:\n+|$)/;
var Ie = /^ {0,3}(#{1,6})(?=\s|$)(.*)(?:\n+|$)/;
var Y = / {0,3}(?:[*+-]|\d{1,9}[.)])/;
var fe = /^(?!bull |blockCode|fences|blockquote|heading|html|table)((?:.|\n(?!\s*?\n|bull |fences|blockquote|heading|hr|html|table))+?)\n {0,3}(=+|-+) *(?:\n+|$)/;
var me = h(fe).replace(/bull/g, Y).replace(/blockCode/g, /(?: {4}| {0,3}\t)/).replace(/fences/g, / {0,3}(?:`{3,}|~{3,})/).replace(/blockquote/g, / {0,3}>/).replace(/heading/g, / {0,3}#{1,6}(?:\s|$)/).replace(/hr/g, / {0,3}(?:(?:-[\t ]*){3,}|(?:_[ \t]*){3,}|(?:\*[ \t]*){3,})(?:\n+|$)/).replace(/html/g, / {0,3}<[^\n>]+>\n/).replace(/\|table/g, "").getRegex();
var Be = h(fe).replace(/bull/g, Y).replace(/blockCode/g, /(?: {4}| {0,3}\t)/).replace(/fences/g, / {0,3}(?:`{3,}|~{3,})/).replace(/blockquote/g, / {0,3}>/).replace(/heading/g, / {0,3}#{1,6}(?:\s|$)/).replace(/hr/g, / {0,3}(?:(?:-[\t ]*){3,}|(?:_[ \t]*){3,}|(?:\*[ \t]*){3,})(?:\n+|$)/).replace(/html/g, / {0,3}<[^\n>]+>\n/).replace(/table/g, / {0,3}\|?(?:[:\- ]*\|)+[\:\- ]*\n/).getRegex();
var ee = /^([^\n]+(?:\n(?!hr|heading|lheading|blockquote|fences|list|html|table|[ \t]+\n)[^\n]+)*)/;
var De = /^[^\n]+/;
var te = /(?!\s*\])(?:\\[\s\S]|[^\[\]\\])+/;
var qe = h(/^ {0,3}\[(label)\]: *(?:\n[ \t]*)?([^<\s][^\s]*|<.*?>)(?:(?: +(?:\n[ \t]*)?| *\n[ \t]*)(title))? *(?:\n+|$)/).replace("label", te).replace("title", /(?:"(?:\\"?|[^"\\])*"|'[^'\n]*(?:\n[^'\n]+)*\n?'|\([^()]*\))/).getRegex();
var Ze = h(/^(bull)([ \t][^\n]*?)?(?:\n|$)/).replace(/bull/g, Y).getRegex();
var Q = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|meta|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul";
var ne = /<!--(?:-?>|[\s\S]*?(?:-->|$))/;
var ve = h("^ {0,3}(?:<(script|pre|style|textarea)[\\s>][\\s\\S]*?(?:</\\1>[^\\n]*\\n*|$)|comment[^\\n]*(\\n+|$)|<\\?[\\s\\S]*?(?:\\?>[^\\n]*\\n*|$)|<![A-Z][\\s\\S]*?(?:>[^\\n]*\\n*|$)|<!\\[CDATA\\[[\\s\\S]*?(?:\\]\\]>[^\\n]*\\n*|$)|</?(tag)(?: +|\\n|/?>)[\\s\\S]*?(?:(?:\\n[ 	]*)+\\n|$)|<(?!(?:script|pre|style|textarea)(?![a-z0-9-]))([a-z][a-z0-9-]*)(?:attribute)*? */?>(?=[ \\t]*(?:\\n|$))[\\s\\S]*?(?:(?:\\n[ 	]*)+\\n|$)|</[a-z][a-z0-9-]*\\s*>(?=[ \\t]*(?:\\n|$))[\\s\\S]*?(?:(?:\\n[ 	]*)+\\n|$))", "i").replace("comment", ne).replace("tag", Q).replace("attribute", / +[a-zA-Z:_][\w.:-]*(?: *= *"[^"\n]*"| *= *'[^'\n]*'| *= *[^\s"'=<>`]+)?/).getRegex();
var xe = (a3) => h(ee).replace("hr", N).replace("heading", " {0,3}#{1,6}(?:\\s|$)").replace("|lheading", "").replace("|table", "").replace("blockquote", " {0,3}>").replace("fences", " {0,3}(?:`{3,}(?=[^`\\n]*(?:\\n|$))|~~~)[^\\n]*(?:\\n|$)").replace("list", a3).replace("html", " {0,3}(?:</?(?:tag)(?: +|\\n|/?>)|<(?:(?:script|pre|style|textarea)(?:[\\s>]|$)|!--)|<\\?|<![A-Za-z]|<!\\[CDATA\\[)").replace("tag", Q).getRegex();
var He = xe(/ {0,3}(?:[*+-]|1[.)])[ \t]+[^ \t\n]/);
var Ge = xe(/ {0,3}(?:[*+-]|\d{1,9}[.)])(?:[ \t]|\n|$)/);
var Ne = h(/^( {0,3}> ?(paragraph|[^\n]*)(?:\n|$))+/).replace("paragraph", Ge).getRegex();
var re = { blockquote: Ne, code: Me, def: qe, fences: Ce, heading: Ie, hr: N, html: ve, lheading: me, list: Ze, newline: Ee, paragraph: He, table: M, text: De };
var de = h("^ *([^\\n ].*)\\n {0,3}((?:\\| *)?:?-+:? *(?:\\| *:?-+:? *)*(?:\\| *)?)(?:\\n((?:(?! *\\n|hr|heading|blockquote|code|fences|list|html).*(?:\\n|$))*)\\n*|$)").replace("hr", N).replace("heading", " {0,3}#{1,6}(?:\\s|$)").replace("blockquote", " {0,3}>").replace("code", "(?: {4}| {0,3}	)[^\\n]").replace("fences", " {0,3}(?:`{3,}(?=[^`\\n]*(?:\\n|$))|~~~)[^\\n]*(?:\\n|$)").replace("list", " {0,3}(?:[*+-]|1[.)])[ \\t]").replace("html", " {0,3}(?:</?(?:tag)(?: +|\\n|/?>)|<(?:(?:script|pre|style|textarea)(?:[\\s>]|$)|!--)|<\\?|<![A-Za-z]|<!\\[CDATA\\[)").replace("tag", Q).getRegex();
var Qe = { ...re, lheading: Be, table: de, paragraph: h(ee).replace("hr", N).replace("heading", " {0,3}#{1,6}(?:\\s|$)").replace("|lheading", "").replace("table", de).replace("blockquote", " {0,3}>").replace("fences", " {0,3}(?:`{3,}(?=[^`\\n]*(?:\\n|$))|~~~)[^\\n]*(?:\\n|$)").replace("list", " {0,3}(?:[*+-]|1[.)])[ \\t]+[^ \\t\\n]").replace("html", " {0,3}(?:</?(?:tag)(?: +|\\n|/?>)|<(?:(?:script|pre|style|textarea)(?:[\\s>]|$)|!--)|<\\?|<![A-Za-z]|<!\\[CDATA\\[)").replace("tag", Q).getRegex() };
var je = { ...re, html: h(`^ *(?:comment *(?:\\n|\\s*$)|<(tag)[\\s\\S]+?</\\1> *(?:\\n{2,}|\\s*$)|<tag(?:"[^"]*"|'[^']*'|\\s[^'"/>\\s]*)*?/?> *(?:\\n{2,}|\\s*$))`).replace("comment", ne).replace(/tag/g, "(?!(?:a|em|strong|small|s|cite|q|dfn|abbr|data|time|code|var|samp|kbd|sub|sup|i|b|u|mark|ruby|rt|rp|bdi|bdo|span|br|wbr|ins|del|img)\\b)\\w+(?!:|[^\\w\\s@]*@)\\b").getRegex(), def: /^ *\[([^\]]+)\]: *<?([^\s>]+)>?(?: +(["(][^\n]+[")]))? *(?:\n+|$)/, heading: /^(#{1,6})(.*)(?:\n+|$)/, fences: M, lheading: /^(.+?)\n {0,3}(=+|-+) *(?:\n+|$)/, paragraph: h(ee).replace("hr", N).replace("heading", ` *#{1,6} *[^
]`).replace("lheading", me).replace("|table", "").replace("blockquote", " {0,3}>").replace("|fences", "").replace("|list", "").replace("|html", "").replace("|tag", "").getRegex() };
var Fe = /^\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])/;
var Ue = /^(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/;
var be = /^( {2,}|\\)\n(?!\s*$)[ \t]*/;
var Ke = /^(`+|[^`])(?:(?= {2,}\n)|[\s\S]*?(?:(?=[\\<!\[`*_]|\b_|$)|[^ ](?= {2,}\n)))/;
var S = /[\p{P}\p{S}]/u;
var q = /[\s\p{P}\p{S}]/u;
var j = /[^\s\p{P}\p{S}]/u;
var Xe = h(/^((?![*_])punctSpace)/, "u").replace(/punctSpace/g, q).getRegex();
var We = /[\p{Pi}\p{Ps}"']/u;
var Re = /(?!~)[\p{P}\p{S}]/u;
var Ve = /(?!~)[\s\p{P}\p{S}]/u;
var Je = /(?:[^\s\p{P}\p{S}]|~)/u;
var Ye = h(/link|precode-code|html/, "g").replace("link", /\[(?:[^\[\]`]|(?<a>`+)[^`]+\k<a>(?!`))*?\]\((?:\\[\s\S]|[^\\\(\)]|\((?:\\[\s\S]|[^\\\(\)])*\))*\)/).replace("precode-", ze ? "(?<!`)()" : "(^^|[^`])").replace("code", /(?<b>`+)[^`]+\k<b>(?!`)/).replace("html", /<(?! )[^<>]*?>/).getRegex();
var Te = /^(?:\*+(?:((?!\*)punct)|([^\s*]))?)|^_+(?:((?!_)punct)|([^\s_]))?/;
var et = h(Te, "u").replace(/punct/g, S).getRegex();
var tt = h(Te, "u").replace(/punct/g, Re).getRegex();
var nt = /^(?:\*+(?:((?!\*)(?!openQuote)punct)|([^\s*]))?)|^_+(?:((?!_)(?!openQuote)punct)|([^\s_]))?/;
var rt = h(nt, "u").replace(/openQuote/g, We).replace(/punct/g, S).getRegex();
var Oe = "^[^_*]*?__[^_*]*?\\*[^_*]*?(?=__)|[^*]+(?=[^*])|(?!\\*)punct(\\*+)(?=[\\s]|$)|notPunctSpace(\\*+)(?!\\*)(?=punctSpace|$)|(?!\\*)punctSpace(\\*+)(?=notPunctSpace)|[\\s](\\*+)(?!\\*)(?=punct)|(?!\\*)punct(\\*+)(?!\\*)(?=punct)|notPunctSpace(\\*+)(?=notPunctSpace)";
var st = h(Oe, "gu").replace(/notPunctSpace/g, j).replace(/punctSpace/g, q).replace(/punct/g, S).getRegex();
var it = h(Oe, "gu").replace(/notPunctSpace/g, Je).replace(/punctSpace/g, Ve).replace(/punct/g, Re).getRegex();
var ot = "^[^_*]*?__[^_*]*?\\*[^_*]*?(?=__)|[^*]+(?=[^*])|(?!\\*)punct(\\*+)(?=[\\s]|$)|notPunctSpace(\\*+)(?!\\*)(?=punctSpace|$)|(?!\\*)[\\s](\\*+)(?=notPunctSpace)|[\\s](\\*+)(?!\\*)(?=punct)|(?!\\*)punct(\\*+)(?!\\*)(?=punct)|(?:(?!\\*)punct|notPunctSpace)(\\*+)(?!\\*)(?=notPunctSpace)";
var at = h(ot, "gu").replace(/notPunctSpace/g, j).replace(/punctSpace/g, q).replace(/punct/g, S).getRegex();
var lt = h("^[^_*]*?\\*\\*[^_*]*?_[^_*]*?(?=\\*\\*)|[^_]+(?=[^_])|(?!_)punct(_+)(?=[\\s]|$)|notPunctSpace(_+)(?!_)(?=punctSpace|$)|(?!_)punctSpace(_+)(?=notPunctSpace)|[\\s](_+)(?!_)(?=punct)|(?!_)punct(_+)(?!_)(?=punct)", "gu").replace(/notPunctSpace/g, j).replace(/punctSpace/g, q).replace(/punct/g, S).getRegex();
var ut = "^[^_*]*?\\*\\*[^_*]*?_[^_*]*?(?=\\*\\*)|[^_]+(?=[^_])|(?!_)punct(_+)(?=[\\s]|$)|notPunctSpace(_+)(?!_)(?=punctSpace|$)|(?!_)[\\s](_+)(?=notPunctSpace)|[\\s](_+)(?!_)(?=punct)|(?!_)punct(_+)(?!_)(?=punct)|(?:(?!_)punct|notPunctSpace)(_+)(?!_)(?=notPunctSpace)";
var pt = h(ut, "gu").replace(/notPunctSpace/g, j).replace(/punctSpace/g, q).replace(/punct/g, S).getRegex();
var ct = h(/^~~?(?:((?!~)punct)|[^\s~])/, "u").replace(/punct/g, S).getRegex();
var ht = "^[^~]+(?=[^~])|(?!~)punct(~~?)(?=[\\s]|$)|notPunctSpace(~~?)(?!~)(?=punctSpace|$)|(?!~)punctSpace(~~?)(?=notPunctSpace)|[\\s](~~?)(?!~)(?=punct)|(?!~)punct(~~?)(?!~)(?=punct)|notPunctSpace(~~?)(?=notPunctSpace)";
var dt = h(ht, "gu").replace(/notPunctSpace/g, j).replace(/punctSpace/g, q).replace(/punct/g, S).getRegex();
var kt = h(/\\(punct)/, "gu").replace(/punct/g, S).getRegex();
var gt = h(/(`+)(?:[^`]|[^`][\s\S]*?[^`])\1(?!`)|`+|\\(punct)/, "gu").replace(/punct/g, S).getRegex();
var ft = h(/^<(scheme:[^\s\x00-\x1f<>]*|email)>/).replace("scheme", /[a-zA-Z][a-zA-Z0-9+.-]{1,31}/).replace("email", /[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+(@)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?![-_])/).getRegex();
var mt = h(ne).replace("(?:-->|$)", "-->").getRegex();
var xt = h("^comment|^</[a-zA-Z][a-zA-Z0-9-]*\\s*>|^<[a-zA-Z][a-zA-Z0-9-]*(?:attribute)*?\\s*/?>|^<\\?[\\s\\S]*?\\?>|^<![a-zA-Z]+\\s[\\s\\S]*?>|^<!\\[CDATA\\[[\\s\\S]*?\\]\\]>").replace("comment", mt).replace("attribute", /\s+[a-zA-Z:_][\w.:-]*(?:\s*=\s*"[^"]*"|\s*=\s*'[^']*'|\s*=\s*[^\s"'=<>`]+)?/).getRegex();
var we = /\[(?:\\[\s\S]|[^\[\]\\])*\]/;
var K = h(/(?:\[(?:brackets|\\[\s\S]|[^\[\]\\])*\]|\\[\s\S]|`+(?!`)[^`]*?`+(?!`)|``+(?=\])|[^\[\]\\`])*?/).replace("brackets", we).getRegex();
var bt = h(/^!?\[(label)\]\([ \t\n]*(href)(?:(?:[ \t]+(?:\n[ \t]*)?|\n[ \t]*)(title))?[ \t\n]*\)/).replace("label", K).replace("href", /<(?:\\.|[^\n<>\\])+>|[^ \t\n\x00-\x1f]+|(?=\))/).replace("title", /"(?:\\"?|[^"\\])*"|'(?:\\'?|[^'\\])*'|\((?:\\\)?|[^)\\])*\)/).getRegex();
var Rt = h(/^!?\[(label)\]\[(ref)\]/).replace("label", K).replace("ref", te).getRegex();
var Tt = h(/^!?\[(ref)\](?:\[\])?/).replace("ref", te).getRegex();
var ke = /(?!\s*\])(?:\\[\s\S]|[^\[\]\\]){1,999}/;
var Ot = h(/(?:[^\[\]\\`]*(?:\[(?:brackets|\\[\s\S]|[^\[\]\\])*\]|\\[\s\S]|`+(?!`)[^`]*?`+(?!`)|``+(?=\]))){0,999}?[^\[\]\\`]*?/).replace("brackets", we).getRegex();
var wt = h("reflink|nolink(?!\\()", "g").replace("reflink", h(/^!?\[(label)\]\[(ref)\]/).replace("label", Ot).replace("ref", ke).getRegex()).replace("nolink", h(/^!?\[(ref)\](?:\[\])?/).replace("ref", ke).getRegex()).getRegex();
var ge = /[hH][tT][tT][pP][sS]?|[fF][tT][pP]/;
var Pt = /[A-Za-z0-9._+-]+@[a-zA-Z0-9-_]+(?:\.[a-zA-Z0-9-_]*[a-zA-Z0-9])+(?![\w-])/;
var yt = h(/(?:mailto:email|xmpp:email(?:\/[A-Za-z0-9@.]+)?)/).replace(/email/g, Pt).getRegex();
var se = { _backpedal: M, anyPunctuation: kt, anyPunctuationOutsideCode: gt, autolink: ft, blockSkip: Ye, br: be, code: Ue, del: M, delLDelim: M, delRDelim: M, emStrongLDelim: et, emStrongRDelimAst: st, emStrongRDelimUnd: lt, escape: Fe, link: bt, nolink: Tt, punctuation: Xe, reflink: Rt, reflinkSearch: wt, tag: xt, text: Ke, url: M };
var St = { ...se, emStrongLDelim: rt, emStrongRDelimAst: at, emStrongRDelimUnd: pt, link: h(/^!?\[(label)\]\((.*?)\)/).replace("label", K).getRegex(), reflink: h(/^!?\[(label)\]\s*\[([^\]]*)\]/).replace("label", K).getRegex() };
var J = { ...se, emStrongRDelimAst: it, emStrongLDelim: tt, delLDelim: ct, delRDelim: dt, url: h(/^emailProtocol|^((?:protocol):\/\/|www\.)(?:[a-zA-Z0-9\-]+\.?)+[^\s<]*|^email/).replace("emailProtocol", yt).replace("protocol", ge).replace("email", /[A-Za-z0-9._+-]+(@)[a-zA-Z0-9-_]+(?:\.[a-zA-Z0-9-_]*[a-zA-Z0-9])+(?![\w-])/).getRegex(), _backpedal: /(?:[^?!.,:;*_'"~()&]+|\([^)]*\)|&(?![a-zA-Z0-9]+;$)|[?!.,:;*_'"~)]+(?!$))+/, del: /^(~~?)(?=[^\s~])((?:\\[\s\S]|[^\\])*?(?:\\[\s\S]|[^\s~\\]))\1(?=[^~]|$)/, text: h(/^(?:[^a-zA-Z0-9](?=emailProtocol)|(`+|~+|[^`~])(?:(?=[`~])|(?= {2,}\n)|(?=[a-zA-Z0-9.!#$%&'*+\/=?_`{\|}~-]+@)|[\s\S]*?(?:(?=[\\<!\[`*~_]|\b_|protocol:\/\/|www\.|$)|[^ ](?= {2,}\n)|[^a-zA-Z0-9](?=emailProtocol)|[^a-zA-Z0-9.!#$%&'*+\/=?_`{\|}~-](?=[a-zA-Z0-9.!#$%&'*+\/=?_`{\|}~-]+@))))/).replace("protocol", ge).replace(/emailProtocol/g, /(?:mailto|xmpp):/).getRegex() };
var _t2 = { ...J, br: h(be).replace("{2,}", "*").getRegex(), text: h(J.text).replace("\\b_", "\\b_| {2,}\\n").replace(/\{2,\}/g, "*").getRegex() };
var F = { normal: re, gfm: Qe, pedantic: je };
var Z = { normal: se, gfm: J, breaks: _t2, pedantic: St };
var $t = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
var Pe = (a3) => $t[a3];
function w(a3, e) {
  if (e) {
    if (x.escapeTest.test(a3)) return a3.replace(x.escapeReplace, Pe);
  } else if (x.escapeTestNoEncode.test(a3)) return a3.replace(x.escapeReplaceNoEncode, Pe);
  return a3;
}
function ye(a3) {
  return x.numericCharacterReference.test(a3) ? a3.replace(x.numericCharacterReferenceOrAmpersand, (e, t, n) => {
    if (t === void 0 && n === void 0) return "&amp;";
    let i = t === void 0 ? Number.parseInt(n, 16) : Number.parseInt(t, 10);
    return i === 0 || i > 1114111 || i >= 55296 && i <= 57343 ? "\uFFFD" : i === 38 ? "&amp;" : String.fromCodePoint(i);
  }) : a3;
}
function ie(a3) {
  try {
    a3 = encodeURI(a3).replace(x.percentDecode, "%");
  } catch {
    return null;
  }
  return a3;
}
function oe(a3, e) {
  let t = a3.replace(x.findPipe, (r, o, s) => {
    let l = false, u = o;
    for (; --u >= 0 && s[u] === "\\"; ) l = !l;
    return l ? "|" : " |";
  }), n = t.split(x.splitPipe), i = 0;
  if (n[0].trim() || n.shift(), n.length > 0 && !n.at(-1)?.trim() && n.pop(), e) if (n.length > e) n.splice(e);
  else for (; n.length < e; ) n.push("");
  for (; i < n.length; i++) n[i] = n[i].trim().replace(x.slashPipe, "|");
  return n;
}
function A(a3, e, t) {
  let n = a3.length;
  if (n === 0) return "";
  let i = 0;
  for (; i < n; ) {
    let r = a3.charAt(n - i - 1);
    if (r === e && !t) i++;
    else if (r !== e && t) i++;
    else break;
  }
  return a3.slice(0, n - i);
}
function ae(a3) {
  let e = a3.split(`
`), t = e.length - 1;
  for (; t >= 0 && x.blankLine.test(e[t]); ) t--;
  return e.length - t <= 2 ? a3 : e.slice(0, t + 1).join(`
`);
}
function v(a3) {
  return a3.trim().toLowerCase().toUpperCase().toLowerCase();
}
function le(a3, e) {
  if (a3.indexOf(e[0]) === -1 && a3.indexOf(e[1]) === -1) return -1;
  let t = 0;
  for (let n = 0; n < a3.length; n++) if (a3[n] === "\\") n++;
  else if (a3[n] === e[0]) t++;
  else if (a3[n] === e[1] && (t--, t < 0)) return n;
  return t > 0 ? -2 : -1;
}
function X(a3, e = 0) {
  let t = e, n = "";
  for (let i of a3) if (i === "	") {
    let r = 4 - t % 4;
    n += " ".repeat(r), t += r;
  } else n += i, t++;
  return n;
}
function Se(a3, e, t, n, i) {
  let r = e.href, o = e.title || null, s = a3[1].replace(i.other.outputLinkReplace, "$1"), l = a3[0].charAt(0) === "!", u = n.state.inLink, c = n.state.linkEmitted, p = n.state.inRawBlock;
  n.state.inLink = true, n.state.linkEmitted = false;
  let d = n.inlineTokens(s), g = n.state.linkEmitted;
  if (n.state.linkEmitted = c, n.state.inLink = u, !l) {
    if (g) {
      n.state.inRawBlock = p;
      return;
    }
    n.state.linkEmitted = true;
  }
  return { type: l ? "image" : "link", raw: t, href: r, title: o, text: s, tokens: d };
}
function Lt(a3, e, t) {
  let n = a3.match(t.other.indentCodeCompensation);
  if (n === null) return e;
  let i = n[1];
  return e.split(`
`).map((r) => {
    let o = r.match(t.other.beginningSpace);
    if (o === null) return r;
    let [s] = o;
    return r.slice(Math.min(s.length, i.length));
  }).join(`
`);
}
function _e(a3, e, t, n) {
  if (!e.includes("<")) return false;
  for (let i = 0; i < e.length; i++) {
    if (e[i] === "\\") {
      i++;
      continue;
    }
    if (e[i] === "`") {
      let s = n.inline.code.exec(e.slice(i));
      if (s) {
        i += s[0].length - 1;
        continue;
      }
    }
    if (e[i] !== "<") continue;
    let r = a3.slice(t + i), o = n.inline.tag.exec(r) || n.inline.autolink.exec(r);
    if (o) {
      if (o[0].length > e.length - i) return true;
      i += o[0].length - 1;
    }
  }
  return false;
}
var _ = class {
  options;
  rules;
  lexer;
  constructor(e) {
    this.options = e || y;
  }
  space(e) {
    let t = this.rules.block.newline.exec(e);
    if (t && t[0].length > 0) return { type: "space", raw: t[0] };
  }
  code(e) {
    let t = this.rules.block.code.exec(e);
    if (t) {
      let n = this.options.pedantic ? t[0] : ae(t[0]), i = n.replace(this.rules.other.codeRemoveIndent, "");
      return { type: "code", raw: n, codeBlockStyle: "indented", text: i };
    }
  }
  fences(e) {
    let t = this.rules.block.fences.exec(e);
    if (t) {
      let n = t[0], i = Lt(n, t[3] || "", this.rules);
      return { type: "code", raw: n, lang: t[2] ? t[2].trim().replace(this.rules.inline.anyPunctuation, "$1") : t[2], text: i };
    }
  }
  heading(e) {
    let t = this.rules.block.heading.exec(e);
    if (t) {
      let n = t[2].trim();
      if (this.rules.other.endingHash.test(n)) {
        let i = A(n, "#");
        (this.options.pedantic || !i || this.rules.other.endingSpaceTabChar.test(i)) && (n = i.trim());
      }
      return { type: "heading", raw: A(t[0], `
`), depth: t[1].length, text: n, tokens: this.lexer.inline(n) };
    }
  }
  hr(e) {
    let t = this.rules.block.hr.exec(e);
    if (t) return { type: "hr", raw: A(t[0], `
`) };
  }
  blockquote(e) {
    let t = this.rules.block.blockquote.exec(e);
    if (t) {
      let n = A(t[0], `
`).split(`
`), i = "", r = "", o = [];
      for (; n.length > 0; ) {
        let s = false, l = [], u;
        for (u = 0; u < n.length; u++) if (this.rules.other.blockquoteStart.test(n[u])) l.push(n[u]), s = true;
        else if (!s) l.push(n[u]);
        else break;
        n = n.slice(u);
        let c = l.join(`
`), p = c.replace(this.rules.other.blockquoteSetextReplace, `
    $1`).replace(this.rules.other.blockquoteSetextReplace2, "");
        i = i ? `${i}
${c}` : c, r = r ? `${r}
${p}` : p;
        let d = this.lexer.state.top;
        if (this.lexer.state.top = true, this.lexer.blockTokens(p, o, true), this.lexer.state.top = d, n.length === 0) break;
        let g = o.at(-1);
        if (g?.type === "code" || g?.type === "heading" || g?.type === "hr" || g?.type === "html") break;
        if (g?.type === "blockquote") {
          let k = g, P = n.join(`
`), R = k.raw + `
` + P.replace(this.rules.other.blockquoteSetextReplace2, ""), m = this.blockquote(R);
          o[o.length - 1] = m;
          let E = R.substring(m.raw.length).replace(/^\n/, ""), b = E ? E.split(`
`).length : 0, H = b ? n.slice(0, -b) : n;
          H.length > 0 && (i = `${i}
${H.join(`
`)}`), r = r.substring(0, r.length - k.text.length) + m.text;
          break;
        } else if (g?.type === "list") {
          let k = g, P = k.raw + `
` + n.join(`
`), R = this.list(P);
          o[o.length - 1] = R, i = i.substring(0, i.length - g.raw.length) + R.raw, r = r.substring(0, r.length - k.raw.length) + R.raw, n = P.substring(o.at(-1).raw.length).split(`
`);
          continue;
        }
      }
      return { type: "blockquote", raw: i, tokens: o, text: r };
    }
  }
  list(e) {
    let t = this.rules.block.list.exec(e);
    if (t) {
      let n = e, i = () => n.length - e.length, r = t[1].trim(), o = r.length > 1, s = { type: "list", raw: "", ordered: o, start: o ? +r.slice(0, -1) : "", loose: false, items: [] };
      r = o ? `\\d{1,9}\\${r.slice(-1)}` : `\\${r}`, this.options.pedantic && (r = o ? r : "[*+-]");
      let l = this.rules.other.listItemRegex(r), u = false;
      for (; e; ) {
        let p = false, d = "";
        if (!(t = l.exec(e)) || this.rules.block.hr.test(e)) break;
        let g = i();
        e = e.substring(t[0].length);
        let k = t[2].split(`
`, 1)[0], P = t[1].length, R = this.options.pedantic ? X(k, P) : k.replace(this.rules.other.leadingSpaceTab, (W) => X(W, P)), m = e.split(`
`, 1)[0], E = !R.trim(), b = 0;
        if (this.options.pedantic ? (b = 2, d = R.trimStart()) : E ? b = P + 1 : (b = R.search(this.rules.other.nonSpaceChar), b = b > 4 ? 1 : b, d = R.slice(b), b += P), E && this.rules.other.blankLine.test(m) && (e = e.substring(m.length + 1), p = true), !p) {
          let W = this.rules.other.nextBulletRegex(b), ue = this.rules.other.hrRegex(b), pe = this.rules.other.fencesBeginRegex(b), ce = this.rules.other.headingBeginRegex(b), $e = this.rules.other.htmlBeginRegex(b), Le = this.rules.other.blockquoteBeginRegex(b);
          for (; e; ) {
            let he = e.split(`
`, 1)[0], G;
            if (m = he, this.options.pedantic ? (m = m.replace(this.rules.other.listReplaceNesting, "  "), G = m) : G = m.replace(this.rules.other.leadingSpaceTab, (Ae) => X(Ae)), pe.test(m) || ce.test(m) || $e.test(m) || Le.test(m) || W.test(m) || ue.test(m)) break;
            if (G.search(this.rules.other.nonSpaceChar) >= b || !m.trim()) d += `
` + G.slice(b);
            else {
              if (E || R.replace(this.rules.other.tabCharGlobal, "    ").search(this.rules.other.nonSpaceChar) >= 4 || pe.test(R) || ce.test(R) || ue.test(R)) break;
              d += `
` + m;
            }
            E = !m.trim(), e = e.substring(he.length + 1), R = G.slice(b);
          }
        }
        let H = n.slice(g, i());
        s.loose || (u ? s.loose = true : this.rules.other.doubleBlankLine.test(H) && (u = true)), s.items.push({ type: "list_item", raw: H, task: !!this.options.gfm && this.rules.other.listIsTask.test(d), loose: false, text: d, tokens: [] });
      }
      let c = s.items.at(-1);
      if (c) c.raw = c.raw.trimEnd(), c.text = c.text.trimEnd();
      else return;
      s.raw = n.slice(0, i()).trimEnd();
      for (let p of s.items) if (this.lexer.state.top = false, p.tokens = this.lexer.blockTokens(p.text, []), !s.loose) {
        let d = p.tokens.filter((k) => k.type === "space"), g = d.length > 0 && d.some((k) => this.rules.other.anyLine.test(k.raw));
        s.loose = g;
      }
      for (let p of s.items) {
        let d = p.tokens[0];
        if (p.task && (d?.type === "text" || d?.type === "paragraph")) {
          p.text = p.text.replace(this.rules.other.listReplaceTask, ""), d.raw = d.raw.replace(this.rules.other.listReplaceTask, ""), d.text = d.text.replace(this.rules.other.listReplaceTask, "");
          for (let k = this.lexer.inlineQueue.length - 1; k >= 0; k--) if (this.rules.other.listIsTask.test(this.lexer.inlineQueue[k].src)) {
            this.lexer.inlineQueue[k].src = this.lexer.inlineQueue[k].src.replace(this.rules.other.listReplaceTask, "");
            break;
          }
          let g = this.rules.other.listTaskCheckbox.exec(p.raw);
          if (g) {
            let k = { type: "checkbox", raw: g[0] + " ", checked: g[0] !== "[ ]" };
            p.checked = k.checked, s.loose ? p.tokens[0] && ["paragraph", "text"].includes(p.tokens[0].type) && "tokens" in p.tokens[0] && p.tokens[0].tokens ? (p.tokens[0].raw = k.raw + p.tokens[0].raw, p.tokens[0].text = k.raw + p.tokens[0].text, p.tokens[0].tokens.unshift(k)) : p.tokens.unshift({ type: "paragraph", raw: k.raw, text: k.raw, tokens: [k] }) : p.tokens.unshift(k);
          }
        } else p.task && (p.task = false);
      }
      if (s.loose) for (let p of s.items) {
        p.loose = true;
        for (let d of p.tokens) d.type === "text" && (d.type = "paragraph");
      }
      return s;
    }
  }
  html(e) {
    let t = this.rules.block.html.exec(e);
    if (t) {
      let n = ae(t[0]);
      return { type: "html", block: true, raw: n, pre: t[1] === "pre" || t[1] === "script" || t[1] === "style", text: n };
    }
  }
  def(e) {
    let t = this.rules.block.def.exec(e);
    if (t) {
      if (!this.rules.other.startAngleBracket.test(t[2]) && le(t[2], "()") !== -1) return;
      let n = v(t[1]).replace(this.rules.other.multipleSpaceGlobal, " "), i = t[2] ? t[2].replace(this.rules.other.hrefBrackets, "$1").replace(this.rules.inline.anyPunctuation, "$1") : "", r = t[3] ? t[3].substring(1, t[3].length - 1).replace(this.rules.inline.anyPunctuation, "$1") : t[3];
      return { type: "def", tag: n, raw: A(t[0], `
`), href: i, title: r };
    }
  }
  table(e) {
    let t = this.rules.block.table.exec(e);
    if (!t || !this.rules.other.tableDelimiter.test(t[2])) return;
    let n = oe(t[1]), i = t[2].replace(this.rules.other.tableAlignChars, "").split("|"), r = t[3]?.trim() ? t[3].replace(this.rules.other.tableRowBlankLine, "").split(`
`) : [], o = { type: "table", raw: A(t[0], `
`), header: [], align: [], rows: [] };
    if (n.length === i.length) {
      for (let s of i) this.rules.other.tableAlignRight.test(s) ? o.align.push("right") : this.rules.other.tableAlignCenter.test(s) ? o.align.push("center") : this.rules.other.tableAlignLeft.test(s) ? o.align.push("left") : o.align.push(null);
      for (let s = 0; s < n.length; s++) o.header.push({ text: n[s], tokens: this.lexer.inline(n[s]), header: true, align: o.align[s] });
      for (let s of r) o.rows.push(oe(s, o.header.length).map((l, u) => ({ text: l, tokens: this.lexer.inline(l), header: false, align: o.align[u] })));
      return o;
    }
  }
  lheading(e) {
    let t = this.rules.block.lheading.exec(e);
    if (t) {
      let n = t[1].trim();
      return { type: "heading", raw: A(t[0], `
`), depth: t[2].charAt(0) === "=" ? 1 : 2, text: n, tokens: this.lexer.inline(n) };
    }
  }
  paragraph(e) {
    let t = this.rules.block.paragraph.exec(e);
    if (t) {
      let n = t[1].charAt(t[1].length - 1) === `
` ? t[1].slice(0, -1) : t[1];
      return { type: "paragraph", raw: t[0], text: n, tokens: this.lexer.inline(n) };
    }
  }
  text(e) {
    let t = this.rules.block.text.exec(e);
    if (t) return { type: "text", raw: t[0], text: t[0], tokens: this.lexer.inline(t[0]) };
  }
  escape(e) {
    let t = this.rules.inline.escape.exec(e);
    if (t) return { type: "escape", raw: t[0], text: t[1] };
  }
  tag(e) {
    let t = this.rules.inline.tag.exec(e);
    if (t) return !this.lexer.state.inLink && this.rules.other.startATag.test(t[0]) ? this.lexer.state.inLink = true : this.lexer.state.inLink && this.rules.other.endATag.test(t[0]) && (this.lexer.state.inLink = false), !this.lexer.state.inRawBlock && this.rules.other.startPreScriptTag.test(t[0]) ? this.lexer.state.inRawBlock = true : this.lexer.state.inRawBlock && this.rules.other.endPreScriptTag.test(t[0]) && (this.lexer.state.inRawBlock = false), { type: "html", raw: t[0], inLink: this.lexer.state.inLink, inRawBlock: this.lexer.state.inRawBlock, block: false, text: t[0] };
  }
  link(e) {
    if (this.lexer.state.linkParenPossible === false) return;
    let t = this.rules.inline.link.exec(e);
    if (t) {
      let n = t[0].charAt(0) === "!" ? 2 : 1;
      if (!this.options.pedantic && _e(e, t[1], n, this.rules)) return;
      let i = t[2].trim();
      if (!this.options.pedantic && this.rules.other.startAngleBracket.test(i)) {
        if (!this.rules.other.endAngleBracket.test(i)) return;
        let s = A(i.slice(0, -1), "\\");
        if ((i.length - s.length) % 2 === 0) return;
      } else {
        let s = le(t[2], "()");
        if (s === -2) return;
        if (s > -1) {
          let u = (t[0].indexOf("!") === 0 ? 5 : 4) + t[1].length + s;
          t[2] = t[2].substring(0, s), t[0] = t[0].substring(0, u).trim(), t[3] = "";
        }
      }
      let r = t[2], o = "";
      if (this.options.pedantic) {
        let s = this.rules.other.pedanticHrefTitle.exec(r);
        s && (r = s[1], o = s[3]);
      } else o = t[3] ? t[3].slice(1, -1) : "";
      return r = r.trim(), this.rules.other.startAngleBracket.test(r) && (this.options.pedantic && !this.rules.other.endAngleBracket.test(i) ? r = r.slice(1) : r = r.slice(1, -1)), Se(t, { href: r && r.replace(this.rules.inline.anyPunctuation, "$1"), title: o && o.replace(this.rules.inline.anyPunctuation, "$1") }, t[0], this.lexer, this.rules);
    }
  }
  reflink(e, t) {
    let n;
    if ((n = this.rules.inline.reflink.exec(e)) || (n = this.rules.inline.nolink.exec(e))) {
      let i = n[0].charAt(0) === "!" ? 2 : 1;
      if (!this.options.pedantic && _e(e, n[1], i, this.rules)) return;
      let r = (n[2] || n[1]).replace(this.rules.other.multipleSpaceGlobal, " "), o = t[v(r)];
      if (!o) {
        let s = n[0].charAt(0);
        return { type: "text", raw: s, text: s };
      }
      return Se(n, o, n[0], this.lexer, this.rules);
    }
  }
  emStrong(e, t, n = "") {
    let i = this.rules.inline.emStrongLDelim.exec(e);
    if (!i || !i[1] && !i[2] && !i[3] && !i[4] || i[4] && n.match(this.rules.other.unicodeAlphaNumeric)) return;
    if (!(i[1] || i[3] || "") || !n || this.rules.inline.punctuation.exec(n)) {
      let o = [...i[0]].length - 1, s, l, u = o, c = 0, p = i[0][0], d = n === p, g = p === "*" ? this.rules.inline.emStrongRDelimAst : this.rules.inline.emStrongRDelimUnd;
      for (g.lastIndex = 0, t = t.slice(-1 * e.length + o); (i = g.exec(t)) !== null; ) {
        if (s = i[1] || i[2] || i[3] || i[4] || i[5] || i[6], !s) continue;
        if (l = [...s].length, i[3] || i[4]) {
          u += l;
          continue;
        } else if (i[5] || i[6]) {
          if (o % 3 && !((o + l) % 3)) {
            c += l;
            continue;
          }
          if (d) break;
        }
        if (u -= l, u > 0) continue;
        l = Math.min(l, l + u + c);
        let k = [...i[0]][0].length, P = e.slice(0, o + i.index + k + l);
        if (Math.min(o, l) % 2) {
          let m = P.slice(1, -1);
          return { type: "em", raw: P, text: m, tokens: this.lexer.inlineTokens(m) };
        }
        let R = P.slice(2, -2);
        return { type: "strong", raw: P, text: R, tokens: this.lexer.inlineTokens(R) };
      }
    }
  }
  codespan(e) {
    let t = this.rules.inline.code.exec(e);
    if (t) {
      let n = t[2].replace(this.rules.other.newLineCharGlobal, " "), i = this.rules.other.nonSpaceChar.test(n), r = this.rules.other.startingSpaceChar.test(n) && this.rules.other.endingSpaceChar.test(n);
      return i && r && (n = n.substring(1, n.length - 1)), { type: "codespan", raw: t[0], text: n };
    }
  }
  br(e) {
    let t = this.rules.inline.br.exec(e);
    if (t) return { type: "br", raw: t[0] };
  }
  del(e, t, n = "") {
    let i = this.rules.inline.delLDelim.exec(e);
    if (!i) return;
    if (!(i[1] || "") || !n || this.rules.inline.punctuation.exec(n)) {
      let o = [...i[0]].length - 1, s, l, u = o, c = this.rules.inline.delRDelim;
      for (c.lastIndex = 0, t = t.slice(-1 * e.length + o); (i = c.exec(t)) !== null; ) {
        if (s = i[1] || i[2] || i[3] || i[4] || i[5] || i[6], !s || (l = [...s].length, l !== o)) continue;
        if (i[3] || i[4]) {
          u += l;
          continue;
        }
        if (u -= l, u > 0) continue;
        l = Math.min(l, l + u);
        let p = [...i[0]][0].length, d = e.slice(0, o + i.index + p + l), g = d.slice(o, -o);
        return { type: "del", raw: d, text: g, tokens: this.lexer.inlineTokens(g) };
      }
    }
  }
  autolink(e) {
    let t = this.rules.inline.autolink.exec(e);
    if (t) {
      let n, i;
      return t[2] === "@" ? (n = t[1], i = "mailto:" + n) : (n = t[1], i = n), { type: "link", raw: t[0], text: n, href: i, autolink: true, tokens: [{ type: "text", raw: n, text: n }] };
    }
  }
  url(e) {
    let t;
    if (t = this.rules.inline.url.exec(e)) {
      let n, i;
      if (t[2] === "@") n = t[0], i = "mailto:" + n;
      else {
        let r;
        do
          r = t[0], t[0] = this.rules.inline._backpedal.exec(t[0])?.[0] ?? "";
        while (r !== t[0]);
        n = t[0], t[1] === "www." ? i = "http://" + t[0] : i = t[0];
      }
      return { type: "link", raw: t[0], text: n, href: i, autolink: true, tokens: [{ type: "text", raw: n, text: n }] };
    }
  }
  inlineText(e) {
    let t = this.rules.inline.text.exec(e);
    if (t) {
      let n = this.lexer.state.inRawBlock;
      return { type: "text", raw: t[0], text: n ? t[0] : ye(t[0]), escaped: n };
    }
  }
};
var T = class a {
  tokens;
  options;
  state;
  inlineQueue;
  tokenizer;
  constructor(e) {
    this.tokens = [], this.tokens.links = /* @__PURE__ */ Object.create(null), this.options = e || y, this.options.tokenizer = this.options.tokenizer || new _(), this.tokenizer = this.options.tokenizer, this.tokenizer.options = this.options, this.tokenizer.lexer = this, this.inlineQueue = [], this.state = { inLink: false, inRawBlock: false, linkEmitted: false, linkParenPossible: true, top: true };
    let t = { other: x, block: F.normal, inline: Z.normal };
    this.options.pedantic ? (t.block = F.pedantic, t.inline = Z.pedantic) : this.options.gfm && (t.block = F.gfm, this.options.breaks ? t.inline = Z.breaks : t.inline = Z.gfm), this.tokenizer.rules = t;
  }
  static get rules() {
    return { block: F, inline: Z };
  }
  static lex(e, t) {
    return new a(t).lex(e);
  }
  static lexInline(e, t) {
    return new a(t).inlineTokens(e);
  }
  lex(e) {
    e = e.replace(x.carriageReturn, `
`), this.blockTokens(e, this.tokens);
    for (let t = 0; t < this.inlineQueue.length; t++) {
      let n = this.inlineQueue[t];
      this.inlineTokens(n.src, n.tokens);
    }
    return this.inlineQueue = [], this.tokens;
  }
  blockTokens(e, t = [], n = false) {
    this.tokenizer.lexer = this, this.options.pedantic && (e = e.replace(x.tabCharGlobal, "    ").replace(x.spaceLine, ""));
    let i = 1 / 0;
    for (; e; ) {
      if (e.length < i) i = e.length;
      else {
        this.infiniteLoopError(e.charCodeAt(0));
        break;
      }
      let r;
      if (this.options.extensions?.block?.some((s) => (r = s.call({ lexer: this }, e, t)) ? (e = e.substring(r.raw.length), t.push(r), true) : false)) continue;
      if (r = this.tokenizer.space(e)) {
        e = e.substring(r.raw.length);
        let s = t.at(-1);
        r.raw.length === 1 && s !== void 0 ? s.raw += `
` : t.push(r);
        continue;
      }
      if (r = this.tokenizer.code(e)) {
        e = e.substring(r.raw.length);
        let s = t.at(-1);
        s?.type === "paragraph" || s?.type === "text" ? (s.raw += (s.raw.endsWith(`
`) ? "" : `
`) + r.raw, s.text += `
` + r.text, this.inlineQueue.at(-1).src = s.text) : t.push(r);
        continue;
      }
      if (r = this.tokenizer.fences(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.heading(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.hr(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.blockquote(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.list(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.html(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.def(e)) {
        e = e.substring(r.raw.length);
        let s = t.at(-1);
        s?.type === "paragraph" || s?.type === "text" ? (s.raw += (s.raw.endsWith(`
`) ? "" : `
`) + r.raw, s.text += `
` + r.raw, this.inlineQueue.at(-1).src = s.text) : this.tokens.links[r.tag] || (this.tokens.links[r.tag] = { href: r.href, title: r.title }, t.push(r));
        continue;
      }
      if (r = this.tokenizer.table(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      if (r = this.tokenizer.lheading(e)) {
        e = e.substring(r.raw.length), t.push(r);
        continue;
      }
      let o = e;
      if (this.options.extensions?.startBlock) {
        let s = 1 / 0, l = e.slice(1), u;
        this.options.extensions.startBlock.forEach((c) => {
          u = c.call({ lexer: this }, l), typeof u == "number" && u >= 0 && (s = Math.min(s, u));
        }), s < 1 / 0 && s >= 0 && (o = e.substring(0, s + 1));
      }
      if (this.state.top && (r = this.tokenizer.paragraph(o))) {
        let s = t.at(-1);
        n && s?.type === "paragraph" ? (s.raw += (s.raw.endsWith(`
`) ? "" : `
`) + r.raw, s.text += `
` + r.text, this.inlineQueue.pop(), this.inlineQueue.at(-1).src = s.text) : t.push(r), n = o.length !== e.length, e = e.substring(r.raw.length);
        continue;
      }
      if (r = this.tokenizer.text(e)) {
        e = e.substring(r.raw.length);
        let s = t.at(-1);
        s?.type === "text" ? (s.raw += (s.raw.endsWith(`
`) ? "" : `
`) + r.raw, s.text += `
` + r.text, this.inlineQueue.pop(), this.inlineQueue.at(-1).src = s.text) : t.push(r);
        continue;
      }
      if (e) {
        this.infiniteLoopError(e.charCodeAt(0));
        break;
      }
    }
    return this.state.top = true, t;
  }
  inline(e, t = []) {
    return this.inlineQueue.push({ src: e, tokens: t }), t;
  }
  linkInText(e) {
    if (!e.includes("[")) return false;
    let t = this.tokenizer.rules.inline.link;
    for (let n of e.matchAll(this.tokenizer.rules.inline.blockSkip)) if (t.test(n[0]) && e.charAt(n.index - 1) !== "!") return true;
    for (let n of e.matchAll(this.tokenizer.rules.inline.reflinkSearch)) {
      let i = n[0], r = i.lastIndexOf("[");
      if (!(i.charAt(0) === "!" || !Object.hasOwn(this.tokens.links, v(i.slice(r + 1, -1)))) && !(r > 1 && this.linkInText(i.slice(1, r - 1)))) return true;
    }
    return false;
  }
  inlineTokens(e, t = []) {
    this.tokenizer.lexer = this;
    let n = this.state.linkParenPossible;
    this.state.linkParenPossible = n && e.includes(")");
    try {
      return this.#e(e, t);
    } finally {
      this.state.linkParenPossible = n;
    }
  }
  #e(e, t) {
    let n = e;
    if (this.tokens.links && e.includes("[")) {
      let s = this.tokenizer.rules.inline.reflinkSearch, l = (u) => {
        let c = u.lastIndexOf("[");
        if (!Object.hasOwn(this.tokens.links, v(u.slice(c + 1, -1)))) return u;
        if (c > 1 && u.charAt(0) !== "!") {
          let p = u.slice(1, c - 1);
          if (this.linkInText(p)) return "[" + p.replace(s, l) + "][" + "a".repeat(u.length - c - 2) + "]";
        }
        return "[" + "a".repeat(u.length - 2) + "]";
      };
      n = n.replace(s, l);
    }
    n = n.replace(this.tokenizer.rules.inline.anyPunctuationOutsideCode, (s, l, u) => u ? "+".repeat(s.length) : l ? l + s.slice(l.length, -l.length).replace(/`/g, "+") + l : s), n = n.replace(this.tokenizer.rules.inline.blockSkip, (s, l, u) => {
      let c = u ? u.length : 0;
      return s.slice(0, c) + "[" + "a".repeat(s.length - c - 2) + "]";
    }), n = this.options.hooks?.emStrongMask?.call({ lexer: this }, n) ?? n;
    let i = false, r = "", o = 1 / 0;
    for (; e; ) {
      if (e.length < o) o = e.length;
      else {
        this.infiniteLoopError(e.charCodeAt(0));
        break;
      }
      i || (r = ""), i = false;
      let s;
      if (this.options.extensions?.inline?.some((u) => (s = u.call({ lexer: this }, e, t)) ? (e = e.substring(s.raw.length), t.push(s), true) : false)) continue;
      if (s = this.tokenizer.escape(e)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.tag(e)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.link(e)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.reflink(e, this.tokens.links)) {
        e = e.substring(s.raw.length);
        let u = t.at(-1);
        s.type === "text" && u?.type === "text" ? (u.raw += s.raw, u.text += s.text) : t.push(s);
        continue;
      }
      if (s = this.tokenizer.emStrong(e, n, r)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.codespan(e)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.br(e)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.del(e, n, r)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (s = this.tokenizer.autolink(e)) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      if (!this.state.inLink && (s = this.tokenizer.url(e))) {
        e = e.substring(s.raw.length), t.push(s);
        continue;
      }
      let l = e;
      if (this.options.extensions?.startInline) {
        let u = 1 / 0, c = e.slice(1), p;
        this.options.extensions.startInline.forEach((d) => {
          p = d.call({ lexer: this }, c), typeof p == "number" && p >= 0 && (u = Math.min(u, p));
        }), u < 1 / 0 && u >= 0 && (l = e.substring(0, u + 1));
      }
      if (s = this.tokenizer.inlineText(l)) {
        e = e.substring(s.raw.length), s.raw.slice(-1) !== "_" && (r = s.raw.slice(-1)), i = true;
        let u = t.at(-1);
        u?.type === "text" ? (u.raw += s.raw, u.text += s.text) : t.push(s);
        continue;
      }
      if (e) {
        this.infiniteLoopError(e.charCodeAt(0));
        break;
      }
    }
    return t;
  }
  infiniteLoopError(e) {
    let t = "Infinite loop on byte: " + e;
    if (this.options.silent) console.error(t);
    else throw new Error(t);
  }
};
var $2 = class {
  options;
  parser;
  constructor(e) {
    this.options = e || y;
  }
  space(e) {
    return "";
  }
  code({ text: e, lang: t, escaped: n }) {
    let i = (t || "").match(x.notSpaceStart)?.[0], r = e ? e.replace(x.endingNewline, "") + `
` : "";
    return i ? '<pre><code class="language-' + w(i) + '">' + (n ? r : w(r, true)) + `</code></pre>
` : "<pre><code>" + (n ? r : w(r, true)) + `</code></pre>
`;
  }
  blockquote({ tokens: e }) {
    return `<blockquote>
${this.parser.parse(e)}</blockquote>
`;
  }
  html({ text: e }) {
    return e;
  }
  def(e) {
    return "";
  }
  heading({ tokens: e, depth: t }) {
    return `<h${t}>${this.parser.parseInline(e)}</h${t}>
`;
  }
  hr(e) {
    return `<hr>
`;
  }
  list(e) {
    let t = e.ordered, n = e.start, i = "";
    for (let s = 0; s < e.items.length; s++) {
      let l = e.items[s];
      i += this.listitem(l);
    }
    let r = t ? "ol" : "ul", o = t && n !== 1 ? ' start="' + n + '"' : "";
    return "<" + r + o + `>
` + i + "</" + r + `>
`;
  }
  listitem(e) {
    return `<li>${this.parser.parse(e.tokens)}</li>
`;
  }
  checkbox({ checked: e }) {
    return "<input " + (e ? 'checked="" ' : "") + 'disabled="" type="checkbox"> ';
  }
  paragraph({ tokens: e }) {
    return `<p>${this.parser.parseInline(e)}</p>
`;
  }
  table(e) {
    let t = "", n = "";
    for (let r = 0; r < e.header.length; r++) n += this.tablecell(e.header[r]);
    t += this.tablerow({ text: n });
    let i = "";
    for (let r = 0; r < e.rows.length; r++) {
      let o = e.rows[r];
      n = "";
      for (let s = 0; s < o.length; s++) n += this.tablecell(o[s]);
      i += this.tablerow({ text: n });
    }
    return i && (i = `<tbody>${i}</tbody>`), `<table>
<thead>
` + t + `</thead>
` + i + `</table>
`;
  }
  tablerow({ text: e }) {
    return `<tr>
${e}</tr>
`;
  }
  tablecell(e) {
    let t = this.parser.parseInline(e.tokens), n = e.header ? "th" : "td";
    return (e.align ? `<${n} align="${e.align}">` : `<${n}>`) + t + `</${n}>
`;
  }
  strong({ tokens: e }) {
    return `<strong>${this.parser.parseInline(e)}</strong>`;
  }
  em({ tokens: e }) {
    return `<em>${this.parser.parseInline(e)}</em>`;
  }
  codespan({ text: e }) {
    return `<code>${w(e, true)}</code>`;
  }
  br(e) {
    return "<br>";
  }
  del({ tokens: e }) {
    return `<del>${this.parser.parseInline(e)}</del>`;
  }
  link({ href: e, title: t, text: n, tokens: i, autolink: r }) {
    let o = r ? w(n, true) : this.parser.parseInline(i), s = ie(e);
    if (s === null) return o;
    e = w(s, r);
    let l = '<a href="' + e + '"';
    return t && (l += ' title="' + w(t) + '"'), l += ">" + o + "</a>", l;
  }
  image({ href: e, title: t, text: n, tokens: i }) {
    i && (n = this.parser.parseInline(i, this.parser.textRenderer));
    let r = ie(e);
    if (r === null) return w(n);
    e = r;
    let o = `<img src="${w(e)}" alt="${w(n)}"`;
    return t && (o += ` title="${w(t)}"`), o += ">", o;
  }
  text(e) {
    return "tokens" in e && e.tokens ? this.parser.parseInline(e.tokens) : "escaped" in e && e.escaped ? e.text : w(e.text);
  }
};
var z = class {
  strong({ text: e }) {
    return e;
  }
  em({ text: e }) {
    return e;
  }
  codespan({ text: e }) {
    return e;
  }
  del({ text: e }) {
    return e;
  }
  html({ text: e }) {
    return e;
  }
  text({ text: e }) {
    return e;
  }
  link({ text: e }) {
    return "" + e;
  }
  image({ text: e }) {
    return "" + e;
  }
  br() {
    return "";
  }
  checkbox({ raw: e }) {
    return e;
  }
};
var O = class a2 {
  options;
  renderer;
  textRenderer;
  constructor(e) {
    this.options = e || y, this.options.renderer = this.options.renderer || new $2(), this.renderer = this.options.renderer, this.renderer.options = this.options, this.renderer.parser = this, this.textRenderer = new z();
  }
  static parse(e, t) {
    return new a2(t).parse(e);
  }
  static parseInline(e, t) {
    return new a2(t).parseInline(e);
  }
  parse(e) {
    this.renderer.parser = this;
    let t = "";
    for (let n = 0; n < e.length; n++) {
      let i = e[n];
      if (this.options.extensions?.renderers?.[i.type]) {
        let o = i, s = this.options.extensions.renderers[o.type].call({ parser: this }, o);
        if (s !== false || !["space", "hr", "heading", "code", "table", "blockquote", "list", "checkbox", "html", "def", "paragraph", "text"].includes(o.type)) {
          t += s || "";
          continue;
        }
      }
      let r = i;
      switch (r.type) {
        case "space": {
          t += this.renderer.space(r);
          break;
        }
        case "hr": {
          t += this.renderer.hr(r);
          break;
        }
        case "heading": {
          t += this.renderer.heading(r);
          break;
        }
        case "code": {
          t += this.renderer.code(r);
          break;
        }
        case "table": {
          t += this.renderer.table(r);
          break;
        }
        case "blockquote": {
          t += this.renderer.blockquote(r);
          break;
        }
        case "list": {
          t += this.renderer.list(r);
          break;
        }
        case "checkbox": {
          t += this.renderer.checkbox(r);
          break;
        }
        case "html": {
          t += this.renderer.html(r);
          break;
        }
        case "def": {
          t += this.renderer.def(r);
          break;
        }
        case "paragraph": {
          t += this.renderer.paragraph(r);
          break;
        }
        case "text": {
          t += this.renderer.text(r);
          break;
        }
        default: {
          let o = 'Token with "' + r.type + '" type was not found.';
          if (this.options.silent) return console.error(o), "";
          throw new Error(o);
        }
      }
    }
    return t;
  }
  parseInline(e, t = this.renderer) {
    this.renderer.parser = this;
    let n = "";
    for (let i = 0; i < e.length; i++) {
      let r = e[i];
      if (this.options.extensions?.renderers?.[r.type]) {
        let s = this.options.extensions.renderers[r.type].call({ parser: this }, r);
        if (s !== false || !["escape", "html", "link", "image", "checkbox", "strong", "em", "codespan", "br", "del", "text"].includes(r.type)) {
          n += s || "";
          continue;
        }
      }
      let o = r;
      switch (o.type) {
        case "escape": {
          n += t.text(o);
          break;
        }
        case "html": {
          n += t.html(o);
          break;
        }
        case "link": {
          n += t.link(o);
          break;
        }
        case "image": {
          n += t.image(o);
          break;
        }
        case "checkbox": {
          n += t.checkbox(o);
          break;
        }
        case "strong": {
          n += t.strong(o);
          break;
        }
        case "em": {
          n += t.em(o);
          break;
        }
        case "codespan": {
          n += t.codespan(o);
          break;
        }
        case "br": {
          n += t.br(o);
          break;
        }
        case "del": {
          n += t.del(o);
          break;
        }
        case "text": {
          n += t.text(o);
          break;
        }
        default: {
          let s = 'Token with "' + o.type + '" type was not found.';
          if (this.options.silent) return console.error(s), "";
          throw new Error(s);
        }
      }
    }
    return n;
  }
};
var L = class {
  options;
  block;
  constructor(e) {
    this.options = e || y;
  }
  static passThroughHooks = /* @__PURE__ */ new Set(["preprocess", "postprocess", "processAllTokens", "emStrongMask"]);
  static passThroughHooksRespectAsync = /* @__PURE__ */ new Set(["preprocess", "postprocess", "processAllTokens"]);
  preprocess(e) {
    return e;
  }
  postprocess(e) {
    return e;
  }
  processAllTokens(e) {
    return e;
  }
  emStrongMask(e) {
    return e;
  }
  provideLexer(e = this.block) {
    return e ? T.lex : T.lexInline;
  }
  provideParser(e = this.block) {
    return e ? O.parse : O.parseInline;
  }
};
function C(a3, e) {
  if (Array.isArray(e)) for (let t = 0; t < e.length; t++) a3.push(e[t]);
  else a3.push(e);
}
var U = class {
  defaults = B();
  options = this.setOptions;
  parse = this.parseMarkdown(true);
  parseInline = this.parseMarkdown(false);
  Parser = O;
  Renderer = $2;
  TextRenderer = z;
  Lexer = T;
  Tokenizer = _;
  Hooks = L;
  constructor(...e) {
    this.use(...e);
  }
  walkTokens(e, t) {
    let n = [];
    for (let i of e) switch (C(n, t.call(this, i)), i.type) {
      case "table": {
        let r = i;
        for (let o of r.header) C(n, this.walkTokens(o.tokens, t));
        for (let o of r.rows) for (let s of o) C(n, this.walkTokens(s.tokens, t));
        break;
      }
      case "list": {
        let r = i;
        C(n, this.walkTokens(r.items, t));
        break;
      }
      default: {
        let r = i;
        this.defaults.extensions?.childTokens?.[r.type] ? this.defaults.extensions.childTokens[r.type].forEach((o) => {
          let s = r[o].flat(1 / 0);
          C(n, this.walkTokens(s, t));
        }) : r.tokens && C(n, this.walkTokens(r.tokens, t));
      }
    }
    return n;
  }
  use(...e) {
    let t = this.defaults.extensions || { renderers: {}, childTokens: {} };
    return e.forEach((n) => {
      let i = { ...n };
      if (i.async = this.defaults.async || i.async || false, n.extensions && (n.extensions.forEach((r) => {
        if (!r.name) throw new Error("extension name required");
        if ("renderer" in r) {
          let o = t.renderers[r.name];
          o ? t.renderers[r.name] = function(...s) {
            let l = r.renderer.apply(this, s);
            return l === false && (l = o.apply(this, s)), l;
          } : t.renderers[r.name] = r.renderer;
        }
        if ("tokenizer" in r) {
          if (!r.level || r.level !== "block" && r.level !== "inline") throw new Error("extension level must be 'block' or 'inline'");
          let o = t[r.level];
          o ? o.unshift(r.tokenizer) : t[r.level] = [r.tokenizer], r.start && (r.level === "block" ? t.startBlock ? t.startBlock.push(r.start) : t.startBlock = [r.start] : r.level === "inline" && (t.startInline ? t.startInline.push(r.start) : t.startInline = [r.start]));
        }
        "childTokens" in r && r.childTokens && (t.childTokens[r.name] = r.childTokens);
      }), i.extensions = t), n.renderer) {
        let r = this.defaults.renderer || new $2(this.defaults);
        for (let o in n.renderer) {
          if (!(o in r)) throw new Error(`renderer '${o}' does not exist`);
          if (["options", "parser"].includes(o)) continue;
          let s = o, l = n.renderer[s], u = r[s];
          r[s] = (...c) => {
            let p = l.apply(r, c);
            return p === false && (p = u.apply(r, c)), p || "";
          };
        }
        i.renderer = r;
      }
      if (n.tokenizer) {
        let r = this.defaults.tokenizer || new _(this.defaults);
        for (let o in n.tokenizer) {
          if (!(o in r)) throw new Error(`tokenizer '${o}' does not exist`);
          if (["options", "rules", "lexer"].includes(o)) continue;
          let s = o, l = n.tokenizer[s], u = r[s];
          r[s] = (...c) => {
            let p = l.apply(r, c);
            return p === false && (p = u.apply(r, c)), p;
          };
        }
        i.tokenizer = r;
      }
      if (n.hooks) {
        let r = this.defaults.hooks || new L();
        for (let o in n.hooks) {
          if (!(o in r)) throw new Error(`hook '${o}' does not exist`);
          if (["options", "block"].includes(o)) continue;
          let s = o, l = n.hooks[s], u = r[s];
          L.passThroughHooks.has(o) ? r[s] = (c) => {
            if (this.defaults.async && L.passThroughHooksRespectAsync.has(o)) return (async () => {
              let d = await l.call(r, c);
              return u.call(r, d);
            })();
            let p = l.call(r, c);
            return u.call(r, p);
          } : r[s] = (...c) => {
            if (this.defaults.async) return (async () => {
              let d = await l.apply(r, c);
              return d === false && (d = await u.apply(r, c)), d;
            })();
            let p = l.apply(r, c);
            return p === false && (p = u.apply(r, c)), p;
          };
        }
        i.hooks = r;
      }
      if (n.walkTokens) {
        let r = this.defaults.walkTokens, o = n.walkTokens;
        i.walkTokens = function(s) {
          let l = [];
          return l.push(o.call(this, s)), r && C(l, r.call(this, s)), l;
        };
      }
      this.defaults = { ...this.defaults, ...i };
    }), this;
  }
  setOptions(e) {
    return this.defaults = { ...this.defaults, ...e }, this;
  }
  lexer(e, t) {
    return T.lex(e, t ?? this.defaults);
  }
  parser(e, t) {
    return O.parse(e, t ?? this.defaults);
  }
  parseMarkdown(e) {
    return (n, i) => {
      let r = { ...i }, o = { ...this.defaults, ...r }, s = this.onError(!!o.silent, !!o.async);
      if (this.defaults.async === true && r.async === false) return s(new Error("marked(): The async option was set to true by an extension. Remove async: false from the parse options object to return a Promise."));
      if (typeof n > "u" || n === null) return s(new Error("marked(): input parameter is undefined or null"));
      if (typeof n != "string") return s(new Error("marked(): input parameter is of type " + Object.prototype.toString.call(n) + ", string expected"));
      if (o.hooks && (o.hooks.options = o, o.hooks.block = e), o.async) return (async () => {
        let l = o.hooks ? await o.hooks.preprocess(n) : n, c = await (o.hooks ? await o.hooks.provideLexer(e) : e ? T.lex : T.lexInline)(l, o), p = o.hooks ? await o.hooks.processAllTokens(c) : c;
        o.walkTokens && await Promise.all(this.walkTokens(p, o.walkTokens));
        let g = await (o.hooks ? await o.hooks.provideParser(e) : e ? O.parse : O.parseInline)(p, o);
        return o.hooks ? await o.hooks.postprocess(g) : g;
      })().catch(s);
      try {
        o.hooks && (n = o.hooks.preprocess(n));
        let u = (o.hooks ? o.hooks.provideLexer(e) : e ? T.lex : T.lexInline)(n, o);
        o.hooks && (u = o.hooks.processAllTokens(u)), o.walkTokens && this.walkTokens(u, o.walkTokens);
        let p = (o.hooks ? o.hooks.provideParser(e) : e ? O.parse : O.parseInline)(u, o);
        return o.hooks && (p = o.hooks.postprocess(p)), p;
      } catch (l) {
        return s(l);
      }
    };
  }
  onError(e, t) {
    return (n) => {
      if (n.message += `
Please report this to https://github.com/markedjs/marked.`, e) {
        let i = "<p>An error occurred:</p><pre>" + w(n.message + "", true) + "</pre>";
        return t ? Promise.resolve(i) : i;
      }
      if (t) return Promise.reject(n);
      throw n;
    };
  }
};
var I = new U();
function f(a3, e) {
  return I.parse(a3, e);
}
f.options = f.setOptions = function(a3) {
  return I.setOptions(a3), f.defaults = I.defaults, V(f.defaults), f;
};
f.getDefaults = B;
f.defaults = y;
function At(...a3) {
  return I.use(...a3), f.defaults = I.defaults, V(f.defaults), f;
}
f.use = At;
f.walkTokens = function(a3, e) {
  return I.walkTokens(a3, e);
};
f.parseInline = I.parseInline;
f.Parser = O;
f.parser = O.parse;
f.Renderer = $2;
f.TextRenderer = z;
f.Lexer = T;
f.lexer = T.lex;
f.Tokenizer = _;
f.Hooks = L;
f.parse = f;
var Rn = f.options;
var Tn = f.setOptions;
var On = f.walkTokens;
var wn = f.parseInline;
var yn = O.parse;
var Sn = T.lex;

// src/documentation.js
function documentation(source) {
  if (typeof source !== "string" || new TextEncoder().encode(source).length > 65536) throw new Error("Documentation exceeds 64 KiB.");
  const template = document.createElement("template");
  template.innerHTML = f.parse(source, { gfm: true, async: false });
  let count2 = 0;
  const blocked = /* @__PURE__ */ new Set(["script", "style", "iframe", "object", "embed", "template", "head", "link", "meta", "base", "svg", "math"]);
  const inline = /* @__PURE__ */ new Set(["p", "a", "strong", "b", "em", "i", "s", "del", "span", "u", "ins", "sub", "sup", "small", "mark", "summary", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6"]);
  const children = (node, depth, flow = false) => Array.from(node.childNodes).flatMap((child) => convert(child, depth + 1, flow));
  function convert(node, depth, flow) {
    if (++count2 > 2048 || depth > 64) throw new Error("Documentation is too deeply nested or has too many elements.");
    if (node.nodeType === 3) return !flow && !node.textContent.trim() ? [] : [{ kind: "text", text: node.textContent }];
    if (node.nodeType !== 1) return [];
    const tag = node.tagName.toLowerCase();
    if (blocked.has(tag) || node.hasAttribute("hidden") || node.style.display === "none") return [];
    if (tag === "pre") {
      const code = Array.from(node.children).find((child) => child.tagName === "CODE") ?? node;
      return [{ kind: "code", text: code.textContent.replace(/\n$/, ""), language: Array.from(code.classList).find((name) => name.startsWith("language-"))?.slice(9) ?? "", tokens: null }];
    }
    if (tag === "br") return [{ kind: "break" }];
    if (tag === "hr") return [{ kind: "rule" }];
    if (tag === "img") return [{ kind: "text", text: node.getAttribute("alt") ?? "" }];
    if (tag === "input") return node.getAttribute("type") === "checkbox" ? [{ kind: "task", checked: node.hasAttribute("checked") }] : [];
    if (tag === "code") return [{ kind: "inline-code", text: node.textContent }];
    if (tag === "table") {
      const rows = Array.from(node.children).flatMap((child) => child.tagName === "TR" ? [child] : Array.from(child.children).filter((row) => row.tagName === "TR"));
      const align = rows.length ? Array.from(rows[0].children).map((cell) => cell.getAttribute("align") ?? cell.style.textAlign ?? "") : [];
      return [{ kind: "table", align, children: rows.flatMap((row) => convert(row, depth + 1, false)) }];
    }
    const data = { kind: { p: "paragraph", blockquote: "quote", ul: "list", ol: "list", li: "item", strong: "strong", b: "strong", em: "em", i: "em", s: "strike", del: "strike", a: "link", details: "details", summary: "summary", tr: node.parentElement?.tagName === "THEAD" ? "table-head" : "table-row", td: "table-cell", th: "table-cell" }[tag] ?? "group", children: children(node, depth, inline.has(tag)) };
    if (/^h[1-6]$/.test(tag)) {
      data.kind = "heading";
      data.level = Number(tag[1]);
    }
    if (tag === "ol") data.start = Number(node.getAttribute("start") ?? 1);
    if (tag === "details") data.open = node.hasAttribute("open");
    if (tag === "a") {
      const href = node.getAttribute("href") ?? "";
      if (/^(https?:\/\/|mailto:)/i.test(href)) data.href = href;
      else data.kind = "inline";
    }
    if (["u", "ins", "sub", "sup", "small", "mark"].includes(tag)) {
      data.kind = "inline";
      data.variant = tag;
    }
    return [data];
  }
  return { kind: "document", children: children(template.content, 0) };
}

// src/reopen.js
async function reopenWorkspace(client, flushStorage, { reload = () => location.reload(), later = (fn) => setTimeout(fn, 60), timeout = 15e3 } = {}) {
  if (client?.invalidated?.code !== "workspace-changed") throw new Error("This workspace does not need to be reopened.");
  let timer;
  try {
    await Promise.race([
      (async () => {
        await Promise.all([...client.docs.values()].map((doc2) => doc2.checkpoint()));
        await flushStorage();
      })(),
      new Promise((_2, reject) => {
        timer = setTimeout(() => reject(new Error("Browser storage is taking too long. Try reopening again.")), timeout);
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
  later(reload);
  return {};
}

// src/frames.js
var MAX_FRAME = 16 * 1024 * 1024;
var encode = new TextEncoder();
var decode = new TextDecoder("utf-8", { fatal: true });
function frame(text2) {
  const bytes = encode.encode(text2);
  if (bytes.length > MAX_FRAME) throw new Error("The session message is too large.");
  const out = new Uint8Array(4 + bytes.length);
  new DataView(out.buffer).setUint32(0, bytes.length);
  out.set(bytes, 4);
  return out;
}
var Frames = class {
  constructor(receive) {
    this.receive = receive;
    this.header = new Uint8Array(4);
    this.headerUsed = 0;
    this.payload = null;
    this.used = 0;
  }
  push(chunk) {
    let at2 = 0;
    while (at2 < chunk.length) {
      if (this.headerUsed < 4) {
        const count3 = Math.min(4 - this.headerUsed, chunk.length - at2);
        this.header.set(chunk.subarray(at2, at2 + count3), this.headerUsed);
        at2 += count3;
        this.headerUsed += count3;
        if (this.headerUsed < 4) return;
        const length2 = new DataView(this.header.buffer).getUint32(0);
        if (length2 > MAX_FRAME) throw new Error("The session message is too large.");
        this.payload = new Uint8Array(length2);
        this.used = 0;
      }
      const count2 = Math.min(this.payload.length - this.used, chunk.length - at2);
      this.payload.set(chunk.subarray(at2, at2 + count2), this.used);
      at2 += count2;
      this.used += count2;
      if (this.used === this.payload.length) {
        const text2 = decode.decode(this.payload);
        this.payload = null;
        this.headerUsed = 0;
        this.receive(text2);
      }
    }
  }
};

// src/agent.js
import { serve } from "./channel-agent.mjs";

// src/previews.js
var AppPreviews = class {
  constructor(client, screen = document.querySelector("#screen"), emit = () => {
  }) {
    this.client = client;
    this.screen = screen;
    this.emit = emit;
    this.descriptors = /* @__PURE__ */ new Map();
    this.surfaces = /* @__PURE__ */ new Map();
    this.pending = /* @__PURE__ */ new Set();
    this.pendingBytes = 0;
    this.receive = (event) => void this.files(event);
    addEventListener("message", this.receive);
    this.resize = () => this.layout();
    addEventListener("resize", this.resize);
    addEventListener("scroll", this.resize, true);
  }
  register(value) {
    const url = new URL(value.url);
    if (!/^[a-f0-9]{64}$/.test(value.preview) || url.origin === location.origin || !["https:", "http:"].includes(url.protocol)) throw Error("The app preview needs an isolated origin.");
    if (url.protocol === "http:" && !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) throw Error("The app preview requires HTTPS.");
    if (this.descriptors.size >= 8 && !this.descriptors.has(value.preview)) throw Error("Too many app previews.");
    this.descriptors.set(value.preview, { preview: value.preview, url: url.href, origin: url.origin });
  }
  update(request) {
    if (typeof request.surface !== "string" || request.surface.length > 128) throw Error("Invalid preview surface.");
    if (request.remove) {
      this.remove(request.surface);
      return {};
    }
    const descriptor = this.descriptors.get(request.preview);
    if (!descriptor) throw Error("This app preview is unavailable.");
    const args2 = request.arguments ?? [];
    if (!Array.isArray(args2) || args2.length > 256 || args2.some((arg) => typeof arg !== "string") || args2.join("").length > 4096) throw Error("The preview program arguments are too large.");
    for (const field of ["x", "y", "width", "height", "viewportWidth", "viewportHeight"]) if (!Number.isFinite(request[field]) || Math.abs(request[field]) > 1e5) throw Error("Invalid preview bounds.");
    const exclusions = request.exclusions ?? [];
    if (!Array.isArray(exclusions) || exclusions.length > 32 || exclusions.some((rect) => !rect || ["x", "y", "width", "height"].some((field) => !Number.isFinite(rect[field]) || Math.abs(rect[field]) > 1e5) || rect.width < 0 || rect.height < 0)) throw Error("Invalid preview overlays.");
    let surface = this.surfaces.get(request.surface);
    if (surface && surface.preview !== request.preview) {
      this.remove(request.surface);
      surface = null;
    }
    if (!surface) {
      if (this.surfaces.size >= 4) throw Error("Too many preview surfaces.");
      const iframe = document.createElement("iframe");
      iframe.title = "Application preview";
      iframe.dataset.raydeAppPreview = request.surface;
      iframe.sandbox = "allow-scripts allow-same-origin";
      iframe.allow = "cross-origin-isolated";
      iframe.referrerPolicy = "strict-origin";
      const url = new URL(descriptor.url);
      for (const arg of args2) url.searchParams.append("arg", arg);
      iframe.style.cssText = "position:fixed;border:0;z-index:20;background:transparent;";
      iframe.src = url.href;
      surface = { iframe, preview: request.preview, origin: descriptor.origin, bounds: request };
      this.surfaces.set(request.surface, surface);
      document.body.append(iframe);
    }
    surface.bounds = request;
    this.layout();
    return {};
  }
  layout() {
    const box = this.screen?.getBoundingClientRect();
    if (!box) return;
    for (const surface of this.surfaces.values()) {
      const b = surface.bounds, sx = box.width / Math.max(1, b.viewportWidth), sy = box.height / Math.max(1, b.viewportHeight);
      const style = surface.iframe.style;
      style.visibility = b.visible === false ? "hidden" : "visible";
      style.left = box.left + b.x * sx + "px";
      style.top = box.top + b.y * sy + "px";
      style.width = Math.max(0, b.width * sx) + "px";
      style.height = Math.max(0, b.height * sy) + "px";
      style.clipPath = this.clip(b, sx, sy);
    }
  }
  clip(bounds, sx, sy) {
    if (!bounds.exclusions?.length) return "";
    let regions = [{ left: 0, top: 0, right: Math.max(0, bounds.width * sx), bottom: Math.max(0, bounds.height * sy) }], changed = false;
    for (const exclusion of bounds.exclusions) {
      const hole = { left: (exclusion.x - bounds.x) * sx, top: (exclusion.y - bounds.y) * sy, right: (exclusion.x + exclusion.width - bounds.x) * sx, bottom: (exclusion.y + exclusion.height - bounds.y) * sy }, next = [];
      for (const region of regions) {
        const left = Math.max(region.left, hole.left), top = Math.max(region.top, hole.top), right = Math.min(region.right, hole.right), bottom = Math.min(region.bottom, hole.bottom);
        if (left >= right || top >= bottom) {
          next.push(region);
          continue;
        }
        changed = true;
        if (region.top < top) next.push({ ...region, bottom: top });
        if (bottom < region.bottom) next.push({ ...region, top: bottom });
        if (region.left < left) next.push({ left: region.left, top, right: left, bottom });
        if (right < region.right) next.push({ left: right, top, right: region.right, bottom });
      }
      regions = next;
    }
    return changed ? `path("${regions.map((r) => `M${r.left} ${r.top}H${r.right}V${r.bottom}H${r.left}Z`).join(" ") || "M0 0Z"}")` : "";
  }
  remove(id2) {
    const surface = this.surfaces.get(id2);
    surface?.iframe.remove();
    this.surfaces.delete(id2);
  }
  unregister(preview) {
    for (const [id2, surface] of this.surfaces) if (surface.preview === preview) this.remove(id2);
    this.descriptors.delete(preview);
  }
  reset() {
    for (const id2 of [...this.surfaces.keys()]) this.remove(id2);
    this.descriptors.clear();
  }
  async files(event) {
    if (!["rayde-preview-files", "rayde-preview-title"].includes(event.data?.type)) return;
    const surface = [...this.surfaces.values()].find((value) => event.source === value.iframe.contentWindow && event.origin === value.origin);
    if (!surface) return;
    if (event.data.type === "rayde-preview-title") {
      if (typeof event.data.title !== "string" || event.data.title.length > 512) return;
      const title = event.data.title.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 256);
      if (title && title !== surface.title) {
        surface.title = title;
        surface.iframe.title = title;
        this.emit({ ev: "preview.title", preview: surface.preview, title });
      }
      return;
    }
    const request = event.data.request;
    if (!request || !Number.isSafeInteger(request.id) || typeof request.op !== "string") return;
    let reply;
    const ticket = { bytes: typeof request.data === "string" ? request.data.length : 0 };
    try {
      if (this.pending.size >= 32 || this.pendingBytes + ticket.bytes > 16 * 1024 * 1024) throw Error("The preview filesystem queue is full.");
      this.pending.add(ticket);
      this.pendingBytes += ticket.bytes;
      if (request.op === "preview.fs.hello") reply = { root: this.client.hello.root };
      else {
        if (!["fs.stat", "fs.list", "fs.read", "fs.write", "fs.mkdir", "fs.remove", "fs.rename"].includes(request.op)) throw Error("This preview may only access workspace files.");
        const params2 = {};
        if (request.op === "fs.rename") {
          params2.from = this.path(request.from, true);
          params2.to = this.path(request.to, true);
        } else params2.path = this.path(request.path, !["fs.stat", "fs.list", "fs.read"].includes(request.op));
        if (request.op === "fs.write") {
          if (typeof request.data !== "string" || request.data.length > 12 * 1024 * 1024) throw Error("The preview write is too large.");
          params2.data = request.data;
          params2.encoding = request.encoding === "base64" ? "base64" : "utf8";
        }
        if (request.op === "fs.read") {
          params2.encoding = request.encoding === "base64" ? "base64" : "utf8";
        }
        reply = await this.client.request(request.op, params2);
      }
      reply = { ...reply, id: request.id, ok: true };
    } catch (error) {
      reply = { id: request.id, ok: false, message: error.message };
    } finally {
      if (this.pending.delete(ticket)) this.pendingBytes -= ticket.bytes;
    }
    if (this.surfaces.get(surface.bounds.surface) === surface) event.source.postMessage({ type: "rayde-preview-files-reply", reply }, surface.origin);
  }
  path(value, write2) {
    if (typeof value !== "string" || value.includes("\0") || value.includes("\\") || value.split("/").includes("..")) throw Error("Invalid preview file path.");
    const root = this.client.hello.root.replace(/\/$/, ""), full = value.startsWith("/") ? value : root + "/" + value;
    if (full !== root && !full.startsWith(root + "/")) throw Error("The path leaves the preview workspace.");
    const relative = full === root ? "" : full.slice(root.length + 1);
    if (relative.split("/").some((part) => [".git", ".rayde", ".rayde-session", ".haxelib"].includes(part))) throw Error("This path is private to the workspace host.");
    if (write2 && !relative) throw Error("The preview cannot replace its workspace.");
    return relative;
  }
  dispose() {
    this.reset();
    removeEventListener("message", this.receive);
    removeEventListener("resize", this.resize);
    removeEventListener("scroll", this.resize, true);
  }
};

// src/agent.js
var query = new URLSearchParams(location.search);
var entry = pageEntry(location, readConnection());
var endpoint = entry.endpoint;
var demo = entry.demo;
var accounts = new Accounts();
var token = entry.token;
async function storage() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("rayde-page", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("files", { keyPath: "path" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
var start = (ask) => serve(ask, {
  async open({ deliver, closed }) {
    let project = entry.project;
    if (entry.workspace) {
      const workspace = await accounts.request("account.workspace", { workspace: entry.workspace });
      if (workspace.status !== "ready") throw new Error(workspace.message ?? "The workspace is still starting.");
      project ??= workspace.project;
    }
    const database = await storage();
    let preset = null;
    const sample = document.querySelector('meta[name="rayde-demo"]')?.content;
    if (demo && !endpoint && sample) {
      const url = new URL(sample, import.meta.url);
      if (url.origin !== location.origin) throw new Error("The sample must come from this site.");
      const response = await fetch(url);
      if (!response.ok) throw new Error("The sample workspace could not be loaded.");
      const text2 = await response.text();
      if (text2.length > 3 * 1024 * 1024) throw new Error("The sample workspace is too large.");
      preset = samplePreset(JSON.parse(text2));
      await seedSample(database, preset);
      project ??= preset.project;
    }
    let storageFailure = null;
    let client = null;
    if (endpoint) {
      const url = new URL(endpoint, location.href);
      if (!["ws:", "wss:"].includes(url.protocol)) throw new Error("The session address must use ws:// or wss://.");
      client = new SessionClient({ url: url.href, token });
      await client.connect();
    }
    const answer = (message) => {
      const bytes = frame(JSON.stringify(message));
      for (let at2 = 0; at2 < bytes.length; at2 += 16384) deliver(bytes.subarray(at2, at2 + 16384));
    };
    const documents = client ? new EditorDocuments(client, answer) : null;
    const previews = client ? new AppPreviews(client, void 0, answer) : null;
    for (const event of ["proc.out", "proc.exit", "term.ready", "term.update", "term.failed", "fs.changed", "doc.update"]) client?.on(event, answer);
    client?.on("disconnected", () => {
      previews?.reset();
      answer({ ev: "session.disconnected", generation: client.generation });
    });
    client?.on("context-changed", ({ message }) => {
      previews?.reset();
      answer({ ev: "session.disconnected", generation: client.generation, code: "workspace-changed", message });
    });
    client?.on("connected", () => answer({ ev: "session.connected", generation: client.generation }));
    const localPath = (path) => typeof path === "string" && (path === "/home/web" || path.startsWith("/home/web/") || !client && demo && (path === "/work" || path.startsWith("/work/"))) && !path.split("/").includes("..");
    const files = (mode, body) => new Promise((resolve, reject) => {
      const transaction = database.transaction("files", mode);
      const request = body(transaction.objectStore("files"));
      transaction.oncomplete = () => resolve(request?.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
    const requests = new Frames((text2) => {
      const request = JSON.parse(text2);
      void (async () => {
        try {
          let reply;
          if (request.op === "hello") reply = { ...client?.hello ?? { root: "/work", name: preset?.name ?? "work", exec: false }, generation: client?.generation ?? 0, remote: !!client, embedded: window.parent !== window, documentBridge: !!documents, storageKey: client?.workspace, demo, repositories: query.get("repositories") === "1", project };
          else if (request.op.startsWith("view.") && documents) {
            reply = { result: await documents.request(request.op, request) };
            if (request.id === void 0) return;
          } else if (request.op.startsWith("account.")) reply = { result: await accounts.request(request.op, request) };
          else if (request.op === "page.markdown") reply = { result: documentation(request.source) };
          else if (request.op === "page.preview") {
            if (!previews) throw new Error("Connect an app preview session first.");
            reply = previews.update(request);
            if (request.id === void 0) return;
          } else if (request.op === "page.reopen") reply = await reopenWorkspace(client, async () => {
            await files("readonly", (store) => store.count());
            if (storageFailure) throw storageFailure;
          });
          else if (request.op === "page.external") {
            if (typeof request.url !== "string" || !/^(https?:\/\/|mailto:)/i.test(request.url)) throw new Error("Unsupported link.");
            globalThis.open(request.url, "_blank", "noopener,noreferrer");
            return;
          } else if (request.op === "page.load") reply = { entries: (await files("readonly", (store) => store.getAll())).filter((entry2) => localPath(entry2.path)) };
          else if (request.op === "page.project") {
            if (typeof request.path !== "string" || request.path.split("/").includes("..")) throw new Error("Choose a project in this workspace.");
            const url = new URL(location.href);
            url.searchParams.set("project", request.path);
            history.replaceState(null, "", url);
            query.set("project", request.path);
            project = request.path;
            return;
          } else if (request.op === "page.seed") {
            const entries = request.entries;
            if (client || !demo || !Array.isArray(entries) || entries.some((entry2) => !localPath(entry2?.path) || !(entry2.path === "/work" || entry2.path.startsWith("/work/")))) throw new Error("The sample must use page storage.");
            await files("readwrite", (store) => {
              const root = store.get("/work");
              root.onsuccess = () => {
                if (root.result?.directory) return;
                for (const entry2 of entries) {
                  const existing = store.get(entry2.path);
                  existing.onsuccess = () => {
                    if (existing.result === void 0) store.put(entry2);
                  };
                }
              };
            });
            reply = {};
          } else if (request.op === "page.store") {
            if (!localPath(request.entry?.path)) throw new Error("The path is not page storage.");
            await files("readwrite", (store) => request.entry.remove ? store.delete(request.entry.path) : store.put(request.entry));
            return;
          } else if (client) {
            const { id: id2, op, ...params2 } = request;
            reply = await client.forward(op, params2);
            if (op === "preview.open") previews.register(reply);
            if (op === "preview.close") previews.unregister(params2.preview);
          } else throw new Error("No workspace session is connected.");
          answer({ ...reply, id: request.id, ok: true });
        } catch (error) {
          if (request.op === "page.store") storageFailure = error;
          if (request.op.startsWith("view.") && request.id === void 0) {
            answer({ ev: "view.error", handle: request.handle, message: error.message });
            return;
          }
          answer({ id: request.id, ok: false, code: error.code ?? "session-error", message: error.message, login: error.login });
        }
      })();
    });
    return {
      send(bytes) {
        try {
          requests.push(bytes);
        } catch (error) {
          closed(error.message);
          client?.close();
        }
      },
      close() {
        previews?.dispose();
        documents?.close();
        client?.close();
        database.close();
        closed("The page closed the session.");
      }
    };
  }
});
export {
  start
};
//# sourceMappingURL=rayde_session.js.map
