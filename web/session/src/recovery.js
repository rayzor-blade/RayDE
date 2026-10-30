import * as Y from "yjs";

const HEADER = "rayde:identity", LEGACY = "rayde:binding";
const MAX_GRAPH = 4 * 1024 * 1024, MAX_INPUT = 64 * 1024 * 1024;
export const validDocumentId = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
export const legacyName = (workspace, path) => `rayde:v2:${JSON.stringify([workspace,path])}`;
export const recoveryName = (workspace, id) => {
  if (!validDocumentId(id)) throw failure("The workspace returned an invalid document identity.");
  return `rayde:v3:${JSON.stringify([workspace,id])}`;
};
function failure(message) { return Object.assign(new Error(message), {code:"recovery-failed"}); }
function pathKey(path) {
  if (typeof path !== "string" || !path || path.length > 4096 || path.includes("\0") || path.includes("\\") || path.split("/").includes("..")) throw failure("The recovery path is invalid.");
  return path;
}
function openDatabase(name, create) {
  return new Promise((resolve,reject) => {
    let missing = false;
    const request = indexedDB.open(name);
    request.onupgradeneeded = () => {
      if (!create) { missing = true; request.transaction.abort(); }
      else request.result.createObjectStore("bindings");
    };
    request.onerror = () => missing ? resolve(null) : reject(request.error ?? failure("Could not open browser recovery."));
    request.onsuccess = () => resolve(request.result);
  });
}

/** Only verified path hints live here; document graphs have separate identity keys. */
export class RecoveryDirectory {
  async database() { return this.opening ??= openDatabase("rayde-document-bindings-v1",true); }
  async get(workspace,path) {
    const db = await this.database();
    return new Promise((resolve,reject) => {
      const tx = db.transaction("bindings","readonly"), request = tx.objectStore("bindings").get([workspace,pathKey(path)]);
      tx.oncomplete = () => {
        const value = request.result;
        if (value !== undefined && (value.version !== 1 || !validDocumentId(value.id))) reject(failure("The browser recovery binding is invalid."));
        else resolve(value?.id ?? null);
      };
      tx.onerror = tx.onabort = () => reject(tx.error ?? failure("Could not read the browser recovery binding."));
    });
  }
  async put(workspace,path,id) {
    recoveryName(workspace,id); pathKey(path);
    const db = await this.database();
    return new Promise((resolve,reject) => {
      const tx = db.transaction("bindings","readwrite"), store = tx.objectStore("bindings"), key = [workspace,path]; let error;
      const previous = store.get(key);
      previous.onsuccess = () => {
        if (previous.result !== undefined) {
          if (previous.result.version !== 1 || !validDocumentId(previous.result.id)) { error = failure("The browser recovery binding is invalid."); tx.abort(); return; }
          store.put({version:1,id},key); return;
        }
        const count = store.count(IDBKeyRange.bound([workspace],[workspace,[]],false,true));
        count.onsuccess = () => {
          if (count.result >= 16384) { error = failure("The workspace browser recovery binding limit was reached."); tx.abort(); }
          else store.put({version:1,id},key);
        };
      };
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not preserve the browser recovery binding."));
    });
  }
  close() { const opening = this.opening; this.opening = null; void opening?.then(db => db.close(),() => {}); }
}

function sourceName(name,workspace) {
  try {
    const value = JSON.parse(name.slice("rayde:v2:".length));
    return name.startsWith("rayde:v2:") && Array.isArray(value) && value.length === 2 && value[0] === workspace && !!pathKey(value[1]);
  } catch { return false; }
}
function sources(names,workspace) {
  if (!Array.isArray(names) || names.some(name => typeof name !== "string" || !sourceName(name,workspace))) throw failure("The legacy recovery links are invalid.");
  const result = [...new Set(names)];
  if (result.length > 16) throw failure("The legacy recovery link limit was reached.");
  return result;
}
function binding(value) {
  if (value !== undefined && (value.version !== 1 || !validDocumentId(value.id) || !Number.isSafeInteger(value.copied) || value.copied < 0)) throw failure("The legacy recovery binding is invalid.");
  return value ?? null;
}

/** Reads legacy state without adding an update or creating an absent database. */
export async function readLegacy(name,load = false) {
  const db = await openDatabase(name,false);
  if (!db) return null;
  const doc = load ? new Y.Doc() : null;
  try {
    if (!db.objectStoreNames.contains("updates") || !db.objectStoreNames.contains("custom")) throw failure("The legacy recovery store is invalid.");
    return await new Promise((resolve,reject) => {
      const tx = db.transaction(["updates","custom"],"readonly"), meta = tx.objectStore("custom").get(LEGACY); let last = 0, bytes = 0, count = 0, error;
      const cursor = load ? tx.objectStore("updates").openCursor() : tx.objectStore("updates").openKeyCursor(null,"prev");
      cursor.onsuccess = () => {
        const entry = cursor.result; if (!entry) return;
        try {
          if (!Number.isSafeInteger(entry.key) || entry.key < 1) throw failure("The legacy recovery sequence is invalid.");
          last = Math.max(last,entry.key);
          if (load) {
            const update = entry.value instanceof ArrayBuffer ? new Uint8Array(entry.value) : entry.value;
            if (!(update instanceof Uint8Array) || (bytes += update.byteLength) > MAX_INPUT || ++count > 20000) throw failure("The legacy recovery exceeds its migration limit.");
            Y.applyUpdate(doc,update); entry.continue();
          }
        } catch (caught) { error = caught; tx.abort(); }
      };
      tx.oncomplete = () => {
        try {
          const result = {name,last,binding:binding(meta.result)};
          if (doc) {
            if (doc.store.pendingStructs || doc.store.pendingDs) throw failure("The legacy recovery is incomplete.");
            result.update = Y.encodeStateAsUpdate(doc); result.vector = Y.encodeStateVector(doc);
            if (result.update.length > MAX_GRAPH) throw failure("The legacy graph exceeds its migration limit.");
          }
          resolve(result);
        } catch (error) { reject(error); }
      };
      tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not read legacy browser recovery."));
    });
  } finally { doc?.destroy(); db.close(); }
}

export async function recoveryHeader(workspace,id) {
  const db = await openDatabase(recoveryName(workspace,id),false);
  if (!db) return null;
  let header;
  try {
    header = await new Promise((resolve,reject) => {
      const tx = db.transaction("custom","readonly"), request = tx.objectStore("custom").get(HEADER);
      tx.oncomplete = () => resolve(request.result);
      tx.onerror = tx.onabort = () => reject(tx.error ?? failure("Could not read browser recovery."));
    });
  } finally { db.close(); }
  if (header === undefined) return null;
  if (header.version !== 1 || header.workspace !== workspace || header.id !== id) throw failure("The document recovery identity does not match.");
  sources(header.sources,workspace); return header;
}

/** The graph and its migration receipts commit before an old path cache is marked copied. */
export function checkpointRecovery(persistence,doc,workspace,id,names = [],snapshot = false) {
  names = sources(names,workspace);
  return new Promise((resolve,reject) => {
    const tx = persistence.db.transaction(["updates","custom"],"readwrite"), store = tx.objectStore("custom"), previous = store.get(HEADER); let error;
    previous.onsuccess = () => {
      try {
        const old = previous.result;
        if (old && (old.version !== 1 || old.workspace !== workspace || old.id !== id)) throw failure("The document recovery identity does not match.");
        const linked = sources([...(old?.sources ?? []),...names],workspace);
        if (snapshot || !old) {
          const update = Y.encodeStateAsUpdate(doc);
          if (update.length > MAX_GRAPH) throw failure("The document exceeds the browser recovery limit.");
          tx.objectStore("updates").add(update);
        }
        store.put({version:1,workspace,id,sources:linked},HEADER);
      } catch (caught) { error = caught; tx.abort(); }
    };
    tx.oncomplete = () => resolve();
    tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not preserve identity-bound browser recovery."));
  });
}

export async function markLegacy(source,id) {
  const db = await openDatabase(source.name,false); if (!db) return;
  try {
    await new Promise((resolve,reject) => {
      const tx = db.transaction("custom","readwrite"), store = tx.objectStore("custom"), request = store.get(LEGACY); let error;
      request.onsuccess = () => {
        try {
          const old = binding(request.result);
          if (old?.id !== source.binding?.id && old?.id !== id) return;
          store.put({version:1,id,copied:Math.max(old?.copied ?? 0,source.last)},LEGACY);
        } catch (caught) { error = caught; tx.abort(); }
      };
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(error ?? tx.error ?? failure("Could not finish the browser recovery migration."));
    });
  } finally { db.close(); }
}
