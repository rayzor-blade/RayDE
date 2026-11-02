// A local Cloud Sync gateway with the compute it needs: the Worker on 127.0.0.1:8787, and a stand-in for the runner that restores a published
// generation into a folder and serves it with `rayde-session`. Development only: accounts are `X-Dev-Account` names, signed in with /auth/dev.
//
//   node dev/sync-dev.mjs [--port 8787] [--data DIR] [--assets URL] [--account alice]
// The editor page is site/dist, served here as the root of the assets origin; --assets points at another server that does the same.
//   RAYDE_SYNC_GATEWAY=http://127.0.0.1:8787 RAYDE_SYNC_DEV_ACCOUNT=alice  (then Sync, and Open, in the Cloud Sync panel)
import { Miniflare } from "miniflare";
import { WebSocket } from "ws";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { createServer as http } from "node:http";
import { readFile } from "node:fs/promises";
import { chmod, mkdir, rename, stat, symlink, writeFile } from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { listening, options } from "../test/fixture.mjs";

const flag = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback; };
const port = Number(flag("port", 8787));
const data = resolve(flag("data", join(homedir(), ".rayde", "sync-dev")));
const base = `http://127.0.0.1:${port}`;
const dist = resolve(dirname(fileURLToPath(import.meta.url)), "../../../site/dist");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".wasm": "application/wasm", ".hl": "application/octet-stream", ".svg": "image/svg+xml", ".png": "image/png" };
let assets = flag("assets");
if (!assets) {
  const files = http(async (request, response) => {
    const path = new URL(request.url, "http://x").pathname;
    const file = resolve(dist, "." + (path === "/" ? "/index.html" : path));
    if (file !== dist && !file.startsWith(dist + "/")) { response.writeHead(403).end(); return; }
    try {
      const body = await readFile(file);
      response.writeHead(200, { "Content-Type": types[file.slice(file.lastIndexOf("."))] ?? "application/octet-stream", "Access-Control-Allow-Origin": "*" }).end(body);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(done => files.listen(0, "127.0.0.1", done));
  assets = `http://127.0.0.1:${files.address().port}`;
}
const secret = "dev-runner-secret";
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const session = resolve(dirname(fileURLToPath(import.meta.url)), "../../../native/session/target/debug/rayde-session");
const freePort = () => new Promise(done => { const server = createServer().listen(0, "127.0.0.1", () => { const p = server.address().port; server.close(() => done(p)); }); });
const running = new Map();

let mf;
// One restore of a workspace at a time: overlapping requests would each start a session and lose track of one of them.
const turns = new Map();
const runner = async request => {
  if (request.headers.get("Authorization") !== `Bearer ${secret}`) return new Response("{}", { status: 403 });
  const body = await request.json();
  const before = turns.get(body.id) ?? Promise.resolve();
  const turn = before.then(() => restore(body), () => restore(body));
  turns.set(body.id, turn.catch(() => {}));
  return turn;
};
async function authorize(entry,publish) {
  if(!publish)return;
  await new Promise((resolve,reject)=>{
    const socket=new WebSocket(entry.connection.url,{headers:{Origin:base}});let finished=false;
    const done=error=>{if(finished)return;finished=true;clearTimeout(timer);socket.close();error?reject(error):resolve();};
    const timer=setTimeout(()=>done(Error("The session did not accept its renewed credential.")),5000);
    socket.on("error",done);socket.on("close",()=>{if(!finished)done(Error("The session disconnected."));});
    socket.on("open",()=>socket.send(JSON.stringify({id:1,op:"hello",token:entry.connection.token})));
    socket.on("message",bytes=>{
      const reply=JSON.parse(bytes);if(reply.id==null)return;
      if(reply.ok!==true){done(Error("The session could not renew Cloud Sync."));return;}
      if(reply.id===1)socket.send(JSON.stringify({id:2,op:"sync.authorize",control:entry.control,gateway:base,workspace:publish.workspace,token:publish.token}));
      else if(reply.id===2)done();
    });
  });
}
const restore = async ({ id, repository, publish }) => {
  if (!repository?.sync) return new Response(JSON.stringify({ message: "This runner only restores synced workspaces." }), { status: 400 });
  const active=running.get(id);
  if(active?.child.exitCode===null && active.child.signalCode===null){await authorize(active,publish);return Response.json(active.connection);}
  const metadata=join(data,"computes",id+".json");let saved=null,fresh=false;
  try{saved=JSON.parse(await readFile(metadata,"utf8"));}catch(error){if(error.code!=="ENOENT")throw error;}
  if(saved && (saved.id!==id || typeof saved.root!=="string" || !resolve(saved.root).startsWith(join(data,"workspaces",id)+sep)))throw Error("The saved development workspace is invalid.");
  if(saved){if(!await stat(saved.root).then(s=>s.isDirectory(),()=>false))throw Error("The saved development workspace is missing. It was not replaced.");}
  else{
    const get = path => mf.dispatchFetch(`${base}/api/sync/runner/${id}${path}`, { headers: { Authorization: `Bearer ${secret}` } });
    const response = await get("/manifest");
    if (!response.ok) return new Response(JSON.stringify({ message: "The snapshot is not available." }), { status: 502 });
    const manifest = await response.json();
    const name = String(manifest.name ?? "").replace(/[^\w.-]+/g, "-").replace(/^[.-]+/, "") || "workspace";
    const root = join(data, "workspaces", id, String(manifest.generation), name);
    fresh=!await stat(root).then(()=>true,error=>{if(error.code==="ENOENT")return false;throw error;});
    if(fresh){
      await mkdir(root,{recursive:true});
      for (const file of manifest.files) {
        const target = join(root, file.path);
        if (!target.startsWith(root + sep)) throw Error("The manifest path leaves its workspace.");
        await mkdir(dirname(target), { recursive: true });
        if (file.kind === "symlink") { await symlink(file.link, target); continue; }
        const parts = [];
        for (const chunk of file.chunks) parts.push(Buffer.from(await (await get(`/chunks/${chunk.hash}`)).arrayBuffer()));
        await writeFile(target, Buffer.concat(parts));
        if (file.kind === "executable") await chmod(target, 0o755);
      }
    }
    saved={id,root,generation:manifest.generation,project:manifest.files.some(f=>f.path==="build.hxml")?"build.hxml":null};
    await mkdir(dirname(metadata),{recursive:true});await writeFile(metadata+".next",JSON.stringify(saved),{mode:0o600});await rename(metadata+".next",metadata);
  }
  const sessionPort = await freePort(), token = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("hex");
  const control=Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
  const inherited=Object.fromEntries(Object.entries(process.env).filter(([name])=>!name.startsWith("RAYDE_SYNC_")));
  const env={...inherited,PATH:`${join(repo,"bin")}:${process.env.PATH}`,RAYDE_HEAPS_SURFACE:join(repo,"scripts/heaps-surface.sh"),RAYDE_ASHUI_SURFACE:join(repo,"scripts/ashui-surface.sh"),
    ...(publish?{RAYDE_SYNC_GATEWAY:base,RAYDE_SYNC_WORKSPACE:publish.workspace,RAYDE_SYNC_TOKEN:publish.token,RAYDE_SYNC_CONTROL:control,RAYDE_SYNC_GENERATION:String(saved.generation),RAYDE_SYNC_FRESH:fresh?"1":"0"}:{})};
  const child=spawn(session,["--root",saved.root,"--state-root",join(data,"sessions",id),"--port",String(sessionPort),"--token",token,"--origin",base,"--exec","--extension-host",join(repo,"bin/rayde-extension-host"),"--extensions",join(repo,"extensions"),"--preview-tools",join(repo,"bin/preview-tools")],{stdio:"inherit",env});
  const connection={url:`ws://127.0.0.1:${sessionPort}/session`,token,project:saved.project,recoverable:true};
  running.set(id,{child,control,connection});await listening(sessionPort,child);
  return Response.json(connection);
};

const { config } = options({ appOrigin: base, asset: assets, port, runnerSecret: secret, provision: null });
config.durableObjectsPersist = join(data, "state");
config.r2Persist = join(data, "files");
config.serviceBindings.RUNNER = runner;
// There is no GitHub here: the signed-in account has the app installed on no repositories, so the repository picker lists none.
const none = body => new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });
config.serviceBindings.GITHUB = request => {
  const path = new URL(request.url).pathname;
  if (path === "/user/installations") return none({ installations: [{ id: 1 }] });
  if (path.endsWith("/repositories")) return none({ repositories: [] });
  return none({ message: "No GitHub on a local gateway" });
};
// A visit with no session is signed in as this account, since a local gateway has no GitHub to send it to.
config.bindings.DEV_ACCOUNT = flag("account", "alice");
mf = new Miniflare(config);
await mf.ready;
console.log(`Cloud Sync gateway: ${base}\nsign in a browser with ${base}/auth/dev?account=alice`);
const stop = async () => {
  for (const entry of running.values()) entry.child.kill();
  // Disposing can wait on open sockets; the process leaves either way.
  setTimeout(() => process.exit(0), 2000).unref();
  await mf.dispose();
  process.exit(0);
};
process.on("exit", () => { for (const entry of running.values()) entry.child.kill(); });
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
