// A local Cloud Sync gateway with the compute it needs: the Worker on 127.0.0.1:8787, and a stand-in for the runner that restores a published
// generation into a folder and serves it with `rayde-session`. Development only: accounts are `X-Dev-Account` names, signed in with /auth/dev.
//
//   node dev/sync-dev.mjs [--port 8787] [--data DIR] [--assets URL] [--account alice]
// The editor page is site/dist, served here as the root of the assets origin; --assets points at another server that does the same.
//   RAYDE_SYNC_GATEWAY=http://127.0.0.1:8787 RAYDE_SYNC_DEV_ACCOUNT=alice  (then Sync, and Open, in the Cloud Sync panel)
import { Miniflare } from "miniflare";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { createServer as http } from "node:http";
import { readFile } from "node:fs/promises";
import { chmod, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
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
const restore = async ({ id, repository, publish }) => {
  const source = repository?.sync;
  if (!source) return new Response(JSON.stringify({ message: "This runner only restores synced workspaces." }), { status: 400 });
  const get = path => mf.dispatchFetch(`${base}/api/sync/runner/${id}${path}`, { headers: { Authorization: `Bearer ${secret}` } });
  const response = await get("/manifest");
  if (!response.ok) return new Response(JSON.stringify({ message: "The snapshot is not available." }), { status: 502 });
  const manifest = await response.json();
  // The session saves back with the capability it is given here; the generation is the one this tree is a copy of.
  // The folder is named after the one that was synced, which is what the editor shows as the workspace's name.
  const name = String(manifest.name ?? "").replace(/[^\w.-]+/g, "-").replace(/^[.-]+/, "") || "workspace";
  const root = join(data, "workspaces", id, String(manifest.generation), name);
  await rm(root, { recursive: true, force: true });
  for (const file of manifest.files) {
    const target = join(root, file.path);
    if (!target.startsWith(root + "/")) throw new Error(`path escapes the workspace: ${file.path}`);
    await mkdir(dirname(target), { recursive: true });
    if (file.kind === "symlink") { await symlink(file.link, target); continue; }
    const parts = [];
    for (const chunk of file.chunks) parts.push(Buffer.from(await (await get(`/chunks/${chunk.hash}`)).arrayBuffer()));
    await writeFile(target, Buffer.concat(parts));
    if (file.kind === "executable") await chmod(target, 0o755);
  }
  running.get(id)?.kill();
  const sessionPort = await freePort(), token = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("hex");
  // The extension host needs --exec; this stand-in runs on the developer's own machine, as the local session does. The toolchain in bin/ (rayzor) is on its PATH, app previews have their tools, and Heaps and Ashui previews their surface scripts.
  const child = spawn(session, ["--root", root, "--port", String(sessionPort), "--token", token, "--origin", base, "--exec", "--extension-host", join(repo, "bin/rayde-extension-host"), "--extensions", join(repo, "extensions"), "--preview-tools", join(repo, "bin/preview-tools")], { stdio: "inherit", env: { ...process.env, PATH: `${join(repo, "bin")}:${process.env.PATH}`, RAYDE_HEAPS_SURFACE: join(repo, "scripts/heaps-surface.sh"), RAYDE_ASHUI_SURFACE: join(repo, "scripts/ashui-surface.sh"), ...(publish ? { RAYDE_SYNC_GATEWAY: base, RAYDE_SYNC_WORKSPACE: publish.workspace, RAYDE_SYNC_TOKEN: publish.token, RAYDE_SYNC_GENERATION: String(manifest.generation) } : {}) } });
  running.set(id, child);
  await listening(sessionPort, child);
  console.log(`restored ${id} generation ${manifest.generation} (${manifest.files.length} files) on :${sessionPort}`);
  // Recoverable: a visit that finds the session gone has the Worker ask for a new one, which is what a gateway restart leaves behind.
  const project = manifest.files.some(f => f.path === "build.hxml") ? "build.hxml" : null;
  return new Response(JSON.stringify({ url: `ws://127.0.0.1:${sessionPort}/session`, token, project, recoverable: true }), { headers: { "Content-Type": "application/json" } });
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
  for (const child of running.values()) child.kill();
  // Disposing can wait on open sockets; the process leaves either way.
  setTimeout(() => process.exit(0), 2000).unref();
  await mf.dispose();
  process.exit(0);
};
process.on("exit", () => { for (const child of running.values()) child.kill(); });
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
