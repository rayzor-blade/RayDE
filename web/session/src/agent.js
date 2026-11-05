import { pageEntry } from "./entry.js";
import { readConnection } from "./connection.js";
import { samplePreset, seedSample } from "./preset.js";
import { Accounts } from "./accounts.js";
import { followAccount } from "./account-session.js";
import { SessionClient } from "./client.js";
import { EditorDocuments } from "./editor.js";
import { documentation } from "./documentation.js";
import { reopenWorkspace } from "./reopen.js";
import { Frames, frame } from "./frames.js";
import { serve } from "./channel-agent.mjs";
import { AppPreviews } from "./previews.js";
import { CachedDemo, remoteDemoEntries } from "./cached-demo.js";
import { TreeCache } from "./tree-cache.js";
import {DemoSource} from './demo-seed.js';
import {DemoStore} from './demo-store.js';
import {DemoSession} from './demo-session.js';
import {DemoAdmission,afterEditorReady} from './demo-admission.js';

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
    let demoSource = null;
    const sample = document.querySelector('meta[name="rayde-demo"]')?.content;
    if ((demo || query.get('demo-preview') === '1') && sample) {
      const url = new URL(sample, import.meta.url);
      if (url.origin !== location.origin) throw new Error("The sample must come from this site.");
      const response = await fetch(url);
      if (!response.ok) throw new Error("The sample workspace could not be loaded.");
      const bytes=new Uint8Array(await response.arrayBuffer());
      if (bytes.length > 3*1024*1024) throw new Error("The sample workspace is too large.");
      if(entry.admission){demoSource=await DemoSource.read(bytes);preset=demoSource.preset;}
      else preset = samplePreset(JSON.parse(new TextDecoder().decode(bytes)));
      if (!endpoint&&!entry.admission) { await seedSample(database, preset); project ??= preset.project; }
    }
    let storageFailure = null;
    let client = null;
    if(entry.admission){
      if(!demoSource)throw Error('The demo source bundle is unavailable.');
      const url=new URL('/api/demo/socket',location.href);url.protocol=location.protocol==='https:'?'wss:':'ws:';
      const store=new DemoStore(location.origin,demoSource.release);
      client=new DemoSession({source:demoSource,store,binding:await store.open(),url:url.href});
      project='build.hxml';
    }
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
    const admission=entry.admission?new DemoAdmission(client,{changed:state=>{if(query.has('debug'))console.info('demo admission:',state.status,state.message);answer({ev:'demo.status',...state});}}):null;
    if(query.has('debug'))console.info('demo controller:',!!admission,'remote endpoint:',!!endpoint);
    const files = (mode, body) => new Promise((resolve, reject) => {
      const transaction = database.transaction("files", mode);
      const request = body(transaction.objectStore("files"));
      transaction.oncomplete = () => resolve(request?.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
    const previewOrigin = document.querySelector('meta[name="rayde-preview-origin"]')?.content ??
      (['127.0.0.1','localhost','[::1]'].includes(location.hostname) ? `${location.protocol}//${location.hostname==='localhost'?'127.0.0.1':'localhost'}:${location.port}` : 'https://preview.rayde.org');
    const cached = client && preset?.preview ? new CachedDemo(preset,new URL(sample,import.meta.url),previewOrigin,
      ()=>remoteDemoEntries(client),client) : null;
    const documents = client ? new EditorDocuments(client, answer) : null;
    const tree = client ? new TreeCache(client,{changed:()=>answer({ev:'page.tree.changed'})}) : null;
    const previews = client ? new AppPreviews(client,undefined,answer) : null;
    for (const event of ["proc.out", "proc.exit", "term.ready", "term.update", "term.failed", "fs.changed", "doc.update", "sync.status"]) client?.on(event, answer);
    const syncStatus = () => { void client?.request("sync.status").then(reply => {
      if (Object.hasOwn(reply,"syncWriteback")) client.receive({ev:"sync.status",syncWriteback:reply.syncWriteback});
    }).catch(()=>{}); };
    client?.on("disconnected", detail => {previews?.connection(false);answer({ ev: "session.disconnected", generation:client.generation, ...detail });});
    client?.on("context-changed", ({message}) => {previews?.connection(false);previews?.reset();answer({ev:"session.disconnected",generation:client.generation,code:"workspace-changed",message});});
    const hello=()=>({...(client?.hello??{root:'/work',name:preset?.name??'work',exec:false}),treeCache:!!tree,
      appPreviews:client?.hello.appPreviews===true||!!cached,webPreviews:client?.hello.webPreviews===true||!!cached,demoPreview:!!cached,
      generation:client?.generation??0,online:client?client.ready:true,remote:!!client,embedded:window.parent!==window,documentBridge:!!documents,
      documentMoves:!!documents&&client.documentMoves,storageKey:client?.workspace,workspaceId:entry.workspace,demo,repositories:query.get('repositories')==='1',project,
      deferred:!!admission,demoState:admission?.state.status,demoMessage:admission?.state.message});
    client?.on("connected", () => {previews?.connection(true);answer({ ev: "session.connected", generation:client.generation, capabilities:hello(), documentMoves:!!documents && client.documentMoves, syncWriteback:client.hello?.syncWriteback??null });syncStatus();});
    if (client) syncStatus();
    const localPath = path => typeof path === "string" && (path === "/home/web" || path.startsWith("/home/web/") || !client && demo && (path === "/work" || path.startsWith("/work/"))) && !path.split("/").includes("..");
    const requests = new Frames(text => {
      const request = JSON.parse(text);
      void (async () => {
        try {
          let reply;
          if (request.op === "hello") reply = hello();
          else if(request.op==='page.demo-retry'&&admission){void admission.start(true);reply={};}
          else if(request.op==='page.tree.list'&&tree)reply=await tree.list(request);
          else if(request.op==='page.tree.refresh'&&tree){tree.invalidate(request.path??'',request.mount??null,true);reply={};}
          else if (request.op.startsWith("view.") && documents) {
            reply = {result:await documents.request(request.op, request)};
            if (request.id === undefined) return;
          }
          else if (request.op === "fs.rename" && documents && client.documentMoves) reply = await documents.rename(request.from,request.to);
          else if (request.op.startsWith("account.")) {
            if (request.op === "account.connect") {
              await files("readonly", store => store.count());
              if (storageFailure) throw storageFailure;
            }
            reply = { result: await accounts.request(request.op, request.op === "account.resources" ? {...request,workspace:entry.workspace} : request) };
          }
          else if (request.op === "page.markdown") reply = {result:documentation(request.source)};
          else if (request.op === 'page.demo-preview') {
            reply = cached && !request.force ? await cached.open(request.root,request.configuration) : {available:false};
            if(reply.available)previews.register(reply);
          }
          else if (request.op === 'page.demo-close') { previews?.unregister(request.preview);reply={}; }
          else if (request.op === "page.preview") {
            if (!previews) throw new Error("Connect an app preview session first.");
            reply = previews.update(request);
            if (request.id === undefined) return;
          }
          else if (request.op === "page.reopen") {
            const status = client && !client.invalidated ? (await client.request("sync.status")).syncWriteback : null;
            const renew = status?.error === "sync-auth" && status.workspace === entry.workspace
              ? () => accounts.request("account.sync-reopen", {workspace:status.workspace}) : undefined;
            reply = await reopenWorkspace(client, async () => {
              await files("readonly", store => store.count());
              if (storageFailure) throw storageFailure;
            }, {renew});
          }
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
            try { reply = await client.forward(op, params); }
            finally { if (op === "preview.close") previews.unregister(params.preview); }
            if (op === "preview.open") previews.register(reply);
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
    const stopAccounts = followAccount(accounts, entry.workspace ? client : null, status => answer({ev:"account.changed", user:status.user}));
    const stopReady=admission?afterEditorReady(()=>{if(query.has('debug'))console.info('demo editor ready');void admission.start();}):()=>{};
    return {
      send(bytes) { try { requests.push(bytes); } catch (error) { closed(error.message); client?.close(); } },
      close() { stopReady();admission?.close();stopAccounts(); accounts.signin?.cancel(); tree?.close(); previews?.dispose(); documents?.close(); client?.close(); database.close(); closed("The page closed the session."); },
    };
  },
});
