import { pageEntry } from "./entry.js";
import { readConnection } from "./connection.js";
import { samplePreset, seedSample } from "./preset.js";
import { Accounts } from "./accounts.js";
import { SessionClient } from "./client.js";
import { EditorDocuments } from "./editor.js";
import { documentation } from "./documentation.js";
import { reopenWorkspace } from "./reopen.js";
import { Frames, frame } from "./frames.js";
import { serve } from "./channel-agent.mjs";
import { AppPreviews } from "./previews.js";

const query = new URLSearchParams(location.search);
const entry = pageEntry(location, readConnection());
const endpoint = entry.endpoint;
const demo = entry.demo;
const accounts = new Accounts();
const token = entry.token;
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
      const text = await response.text();
      if (text.length > 3*1024*1024) throw new Error("The sample workspace is too large.");
      preset = samplePreset(JSON.parse(text));
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
    const answer = message => {
      const bytes = frame(JSON.stringify(message));
      for (let at = 0; at < bytes.length; at += 16384) deliver(bytes.subarray(at, at + 16384));
    };
    const documents = client ? new EditorDocuments(client, answer) : null;
    const previews = client ? new AppPreviews(client) : null;
    for (const event of ["proc.out", "proc.exit", "term.ready", "term.update", "term.failed", "fs.changed", "doc.update"]) client?.on(event, answer);
    client?.on("disconnected", () => {previews?.reset();answer({ ev: "session.disconnected", generation:client.generation });});
    client?.on("context-changed", ({message}) => {previews?.reset();answer({ev:"session.disconnected",generation:client.generation,code:"workspace-changed",message});});
    client?.on("connected", () => answer({ ev: "session.connected", generation:client.generation }));
    const localPath = path => typeof path === "string" && (path === "/home/web" || path.startsWith("/home/web/") || !client && demo && (path === "/work" || path.startsWith("/work/"))) && !path.split("/").includes("..");
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
          if (request.op === "hello") reply = { ...(client?.hello ?? { root: "/work", name: preset?.name ?? "work", exec: false }), generation:client?.generation ?? 0, remote: !!client, embedded:window.parent !== window, documentBridge:!!documents, storageKey:client?.workspace, demo, repositories: query.get("repositories") === "1", project: project };
          else if (request.op.startsWith("view.") && documents) {
            reply = {result:await documents.request(request.op, request)};
            if (request.id === undefined) return;
          }
          else if (request.op.startsWith("account.")) reply = { result: await accounts.request(request.op, request) };
          else if (request.op === "page.markdown") reply = {result:documentation(request.source)};
          else if (request.op === "page.preview") {
            if (!previews) throw new Error("Connect an app preview session first.");
            reply = previews.update(request);
            if (request.id === undefined) return;
          }
          else if (request.op === "page.reopen") reply = await reopenWorkspace(client, async () => {
            await files("readonly", store => store.count());
            if (storageFailure) throw storageFailure;
          });
          else if (request.op === "page.external") {
            if (typeof request.url !== "string" || !/^(https?:\/\/|mailto:)/i.test(request.url)) throw new Error("Unsupported link.");
            globalThis.open(request.url,"_blank","noopener,noreferrer"); return;
          }
          else if (request.op === "page.load") reply = { entries: (await files("readonly", store => store.getAll())).filter(entry => localPath(entry.path)) };
          else if (request.op === "page.project") {
            if (typeof request.path !== "string" || request.path.split("/").includes("..")) throw new Error("Choose a project in this workspace.");
            const url = new URL(location.href); url.searchParams.set("project",request.path);
            history.replaceState(null,"",url); query.set("project",request.path); project = request.path;
            return;
          }
          else if (request.op === "page.seed") {
            const entries = request.entries;
            if (client || !demo || !Array.isArray(entries) || entries.some(entry => !localPath(entry?.path) || !(entry.path === "/work" || entry.path.startsWith("/work/")))) throw new Error("The sample must use page storage.");
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
            reply = await client.forward(op, params);
            if (op === "preview.open") previews.register(reply);
            if (op === "preview.close") previews.unregister(params.preview);
          } else throw new Error("No workspace session is connected.");
          answer({ ...reply, id: request.id, ok: true });
        } catch (error) {
          if (request.op === "page.store") storageFailure = error;
          if (request.op.startsWith("view.") && request.id === undefined) {
            answer({ev:"view.error", handle:request.handle, message:error.message}); return;
          }
          answer({ id: request.id, ok: false, code: error.code ?? "session-error", message: error.message, login: error.login });
        }
      })();
    });
    return {
      send(bytes) { try { requests.push(bytes); } catch (error) { closed(error.message); client?.close(); } },
      close() { previews?.dispose(); documents?.close(); client?.close(); database.close(); closed("The page closed the session."); },
    };
  },
});
