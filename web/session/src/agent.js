import { SessionClient } from "./client.js";
import { Frames, frame } from "./frames.js";
import { serve } from "./channel-agent.mjs";

const query = new URLSearchParams(location.search);
const endpoint = query.get("session");
const token = new URLSearchParams(location.hash.slice(1)).get("token");
async function storage() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("rayde-page", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("files", { keyPath: "path" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export const start = ask => serve(ask, {
  async open({ deliver, closed }) {
    const database = await storage();
    let client = null;
    if (endpoint) {
      const url = new URL(endpoint, location.href);
      if (!["ws:", "wss:"].includes(url.protocol)) throw new Error("The session address must use ws:// or wss://.");
      client = new SessionClient({ url: url.href, token });
      await client.connect();
    }
    const answer = message => {
      const bytes = frame(JSON.stringify(message));
      for (let at = 0; at < bytes.length; at += 16384) deliver(bytes.subarray(at, at + 16384));
    };
    for (const event of ["proc.out", "proc.exit", "fs.changed", "doc.update"]) client?.on(event, answer);
    client?.on("disconnected", () => answer({ ev: "session.disconnected" }));
    client?.on("connected", () => answer({ ev: "session.connected" }));
    const localPath = path => typeof path === "string" && (path === "/home/web" || path.startsWith("/home/web/") || !client && (path === "/work" || path.startsWith("/work/"))) && !path.split("/").includes("..");
    const files = (mode, body) => new Promise((resolve, reject) => {
      const transaction = database.transaction("files", mode);
      const request = body(transaction.objectStore("files"));
      transaction.oncomplete = () => resolve(request?.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
    const requests = new Frames(text => {
      const request = JSON.parse(text);
      void (async () => {
        try {
          let reply;
          if (request.op === "hello") reply = { ...(client?.hello ?? { root: "/work", name: "work", exec: false }), remote: !!client, project: query.get("project") };
          else if (request.op === "page.load") reply = { entries: (await files("readonly", store => store.getAll())).filter(entry => localPath(entry.path)) };
          else if (request.op === "page.seed") {
            const entries = request.entries;
            if (client || !Array.isArray(entries) || entries.some(entry => !localPath(entry?.path) || !(entry.path === "/work" || entry.path.startsWith("/work/")))) throw new Error("The sample must use page storage.");
            // The root record and its initial files become durable together.
            await files("readwrite", store => {
              const root = store.get("/work");
              root.onsuccess = () => {
                if (root.result?.directory) return;
                for (const entry of entries) {
                  const existing = store.get(entry.path);
                  existing.onsuccess = () => { if (existing.result === undefined) store.put(entry); };
                }
              };
            });
            reply = {};
          }
          else if (request.op === "page.store") {
            if (!localPath(request.entry?.path)) throw new Error("The path is not page storage.");
            await files("readwrite", store => request.entry.remove ? store.delete(request.entry.path) : store.put(request.entry));
            return;
          } else if (client) {
            const { id, op, ...params } = request;
            reply = await client.request(op, params);
          } else throw new Error("No workspace session is connected.");
          answer({ ...reply, id: request.id, ok: true });
        } catch (error) {
          answer({ id: request.id, ok: false, code: error.code ?? "session-error", message: error.message, login: error.login });
        }
      })();
    });
    return {
      send(bytes) { try { requests.push(bytes); } catch (error) { closed(error.message); client?.close(); } },
      close() { client?.close(); database.close(); closed("The page closed the session."); },
    };
  },
});
