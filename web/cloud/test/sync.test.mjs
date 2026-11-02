import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtemp, writeFile, rm, cp } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fixture, json } from "./fixture.mjs";

const cli = resolve("../../native/sync/target/debug/examples/push");
const freePort = () => new Promise(done => { const server = createServer().listen(0, "127.0.0.1", () => { const port = server.address().port; server.close(() => done(port)); }); });
const digest = bytes => createHash("sha256").update(bytes).digest("hex");

async function gateway(t) {
  const port = await freePort(), base = `http://127.0.0.1:${port}`;
  const host = await fixture({ port, appOrigin: base }); t.after(() => host.mf.dispose());
  const as = name => async (path, init = {}) => host.mf.dispatchFetch(base + "/api/sync" + path, { ...init, headers: { "X-Dev-Account": name, ...(init.headers ?? {}) } });
  return { ...host, base, alice: as("alice"), bob: as("bob") };
}
const post = (body, method = "POST") => ({ method, body: JSON.stringify(body), headers: { "Content-Type": "application/json" } });

test("sync routes need an account, and a workspace is invisible to another one", async t => {
  const { alice, bob, mf, base } = await gateway(t);
  assert.equal((await mf.dispatchFetch(base + "/api/sync/workspaces", { method: "POST" })).status, 401);
  const made = await (await alice("/workspaces", post({}))).json();
  assert.match(made.id, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(made.url, `${base}/${made.id}`);
  assert.equal((await bob(`/workspaces/${made.id}`)).status, 404);
  assert.equal((await bob(`/workspaces/${made.id}/uploads`, post({ chunks: [] }))).status, 404);
  assert.equal((await alice(`/workspaces/${made.id}`)).status, 200);
  assert.equal((await alice("/workspaces/not-an-id")).status, 404);
});

test("chunks are verified, deduplicated and resumable", async t => {
  const { alice } = await gateway(t);
  const { id } = await (await alice("/workspaces", post({}))).json();
  const a = Buffer.from("alpha".repeat(1000)), b = Buffer.from("beta".repeat(1000));
  const declared = [a, b].map(bytes => ({ hash: digest(bytes), size: bytes.length }));
  const begun = await (await alice(`/workspaces/${id}/uploads`, post({ chunks: declared }))).json();
  assert.deepEqual([...begun.missing].sort(), declared.map(c => c.hash).sort());
  const put = (hash, bytes) => alice(`/workspaces/${id}/uploads/${begun.lease}/chunks/${hash}`, { method: "PUT", body: bytes });
  const wrong = await put(declared[0].hash, b);
  assert.equal(wrong.status, 422);
  assert.equal((await wrong.json()).code, "bad-chunk");
  assert.equal((await put(declared[0].hash, a)).status, 200);
  assert.equal((await put(declared[0].hash, a)).status, 200, "a chunk sent twice counts once");
  const stranger = Buffer.from("never declared");
  assert.equal((await put(digest(stranger), stranger)).status, 422);
  const pending = await (await alice(`/workspaces/${id}/uploads/${begun.lease}`)).json();
  assert.deepEqual(pending.missing, [declared[1].hash]);
  const cancelled = await alice(`/workspaces/${id}/uploads/${begun.lease}`, { method: "DELETE" });
  assert.equal(cancelled.status, 200);
  assert.equal((await alice(`/workspaces/${id}/uploads/${begun.lease}`)).status, 404, "a cancelled lease is unknown");
});

test("an upload over the allocation is refused without reserving anything", async t => {
  const { alice } = await gateway(t);
  const { id } = await (await alice("/workspaces", post({ allocation: 1000 }))).json();
  const big = Buffer.alloc(5000, 7);
  const refused = await alice(`/workspaces/${id}/uploads`, post({ chunks: [{ hash: digest(big), size: big.length }] }));
  assert.ok(refused.status >= 400 && refused.status < 500);
  assert.equal((await refused.json()).code, "workspace-over-allocation");
  const status = await (await alice(`/workspaces/${id}`)).json();
  assert.equal(status.usage.reserved, 0);
});

test("a forged manifest is refused and leaves the last generation alone", async t => {
  const { alice } = await gateway(t);
  const { id } = await (await alice("/workspaces", post({}))).json();
  const begun = await (await alice(`/workspaces/${id}/uploads`, post({ chunks: [] }))).json();
  const forged = await alice(`/workspaces/${id}/uploads/${begun.lease}/publish`, { method: "POST", body: '{"format":1,"workspace":"x"}' });
  assert.equal(forged.status, 422);
  assert.equal((await (await alice(`/workspaces/${id}`)).json()).generation, 0);
});

async function repository(files) {
  const root = await mkdtemp(join(tmpdir(), "rayde-sync-"));
  const git = (...args) => spawnSync("git", ["-C", root, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", ...args], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  for (const [name, content] of Object.entries(files)) await writeFile(join(root, name), content);
  git("add", "-A"); git("commit", "-q", "-m", "first");
  return { root, git };
}
const push = (root, base) => {
  const run = spawnSync(cli, [root, base, "alice"], { encoding: "utf8" });
  const events = run.stdout.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  return { code: run.status, events, last: events.at(-1) };
};

test("the upload client publishes a folder, then only what changed, and the cloud copy reads back", async t => {
  const { base, alice, mf } = await gateway(t);
  const { root } = await repository({ "main.hx": "class Main {}\n".repeat(200), "notes.txt": "one" });
  t.after(() => rm(root, { recursive: true, force: true }));
  const first = push(root, base);
  assert.equal(first.code, 0, JSON.stringify(first.events));
  assert.equal(first.last.event, "published");
  assert.equal(first.last.generation, 1);
  assert.match(first.last.url, new RegExp(`^${base}/[A-Za-z0-9_-]{43}$`));
  await writeFile(join(root, "notes.txt"), "two");
  const second = push(root, base);
  assert.equal(second.last.generation, 2, JSON.stringify(second.events));
  const uploads = second.events.filter(e => e.event === "upload");
  assert.ok(uploads.every(u => u.total <= 2), "only the changed file's chunks go again");
  const id = first.last.url.split("/").pop();
  const manifest = await (await alice(`/workspaces/${id}/export/manifest`)).json();
  assert.equal(manifest.generation, 2);
  const entry = manifest.files.find(f => f.path === "notes.txt");
  const chunk = Buffer.from(await (await alice(`/workspaces/${id}/export/chunks/${entry.chunks[0].hash}`)).arrayBuffer());
  assert.equal(chunk.toString(), "two");
  const bucket = await mf.getR2Bucket("WORKSPACE_FILES");
  const keys = (await bucket.list({ prefix: `sync/${id}/` })).objects.map(o => o.key);
  assert.ok(keys.some(k => k.endsWith("generations/000000000002.json")));
  assert.ok(!keys.some(k => k.endsWith(digest("one"))), "a chunk no generation references is deleted");
});

test("a synced workspace opens in a browser session on the restored files", async t => {
  const { spawn } = await import("node:child_process");
  const { readFile } = await import("node:fs/promises");
  const port = await freePort(), base = `http://127.0.0.1:${port}`, data = await mkdtemp(join(tmpdir(), "rayde-sync-dev-"));
  const server = spawn("node", ["dev/sync-dev.mjs", "--port", String(port), "--data", data], { stdio: ["ignore", "pipe", "inherit"] });
  t.after(async () => {
    const exited = new Promise(done => server.once("exit", done));
    server.kill();
    await exited;
    server.stdout.destroy();
    await rm(data, { recursive: true, force: true });
  });
  await new Promise((done, fail) => { server.stdout.on("data", chunk => String(chunk).includes("Cloud Sync gateway") && done()); server.once("exit", () => fail(new Error("the dev gateway exited"))); });
  const { root } = await repository({ "main.hx": "class Main {}\n", "notes.txt": "synced text" });
  const name = root.split("/").pop();
  t.after(() => rm(root, { recursive: true, force: true }));
  const pushed = push(root, base);
  assert.equal(pushed.last.event, "published", JSON.stringify(pushed.events));
  const id = pushed.last.url.split("/").pop();
  const api = (path, init = {}) => fetch(base + path, { redirect: "manual", ...init, headers: { "X-Dev-Account": "alice", ...(init.headers ?? {}) } });

  const stranger = await fetch(`${base}/api/sync/workspaces/${id}/open`, { method: "POST", headers: { "X-Dev-Account": "bob" } });
  assert.equal(stranger.status, 404, "another account cannot open it");
  const forged = await fetch(`${base}/api/sync/runner/${id}/manifest`, { headers: { Authorization: "Bearer guess" } });
  assert.equal(forged.status, 403, "only the runner reads a snapshot without an account");

  // The published link works before anyone has pressed Open, for its owner only.
  const visitor = async account => {
    const signin = await fetch(`${base}/auth/dev?account=${account}&return=/${id}`, { redirect: "manual" });
    return fetch(`${base}/${id}`, { headers: { Cookie: signin.headers.getSetCookie()[0].split(";")[0] }, redirect: "manual" });
  };
  assert.equal((await visitor("alice")).status, 200, "the owner's first visit makes the browser workspace");
  assert.equal((await visitor("bob")).status, 403, "another account is refused it");
  const opened = await api(`/api/sync/workspaces/${id}/open`, { method: "POST" });
  assert.equal(opened.status, 200, await opened.text());
  const login = await fetch(`${base}/auth/dev?account=alice&return=/${id}`, { redirect: "manual" });
  assert.equal(login.status, 302);
  const cookie = login.headers.getSetCookie().find(c => c.startsWith("rayde_session=")).split(";")[0];
  const anonymous = await fetch(`${base}/${id}`, { redirect: "manual" });
  assert.equal(anonymous.status, 302);
  assert.equal(new URL(anonymous.headers.get("Location")).pathname, "/auth/dev", "a local gateway signs in its development account, not GitHub");
  // Open Repository starts GitHub sign-in; here it signs in the development account and returns to the repository picker.
  const start = await fetch(`${base}/auth/github/start`, { redirect: "manual" });
  assert.equal(new URL(start.headers.get("Location")).pathname, "/auth/dev");
  const picker = await fetch(new URL(start.headers.get("Location")), { redirect: "manual" });
  const back = new URL(picker.headers.get("Location"));
  assert.equal(back.pathname + back.search, "/?repositories=1", "the repository picker link keeps its query");
  const pickerCookie = picker.headers.getSetCookie()[0].split(";")[0];
  const listed = await (await fetch(`${base}/api/repositories`, { headers: { Cookie: pickerCookie } })).json();
  assert.deepEqual(listed.repositories.map(r => [r.id, r.fullName]), [[id, `${name} (synced)`]], "Open Repository offers the account's synced workspaces");
  const bobSignin = await fetch(`${base}/auth/dev?account=bob&return=/`, { redirect: "manual" });
  const bobs = await (await fetch(`${base}/api/repositories`, { headers: { Cookie: bobSignin.headers.getSetCookie()[0].split(";")[0] } })).json();
  assert.deepEqual(bobs.repositories, [], "another account's list does not include it");
  const csrf = (await (await fetch(`${base}/api/session`, { headers: { Cookie: pickerCookie } })).json()).csrf;
  const choose = await fetch(`${base}/api/workspaces/open`, { method: "POST", headers: { Cookie: pickerCookie, Origin: base, "X-RayDE-CSRF": csrf, "Content-Type": "application/json" }, body: JSON.stringify({ repository: id }) });
  const chosen = await choose.json();
  assert.equal(choose.status, 200, JSON.stringify(chosen));
  assert.equal(chosen.id, id, "choosing it opens the browser workspace");
  const page = await fetch(`${base}/${id}`, { headers: { Cookie: cookie }, redirect: "manual" });
  assert.equal(page.status, 200, "the workspace page opens for its owner");
  let state;
  for (let i = 0; i < 100; i++) { state = await (await fetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status !== "preparing") break; await new Promise(r => setTimeout(r, 100)); }
  assert.equal(state.status, "ready", JSON.stringify(state));
  assert.equal(await readFile(join(data, "workspaces", id, "1", name, "notes.txt"), "utf8"), "synced text");

  // The browser's own connection reaches the restored session through the Worker.
  const { default: WebSocket } = await import("ws");
  const socket = new WebSocket(`ws://127.0.0.1:${port}/api/workspaces/${id}/socket`, { headers: { Cookie: cookie, Origin: base } });
  await new Promise((done, fail) => { socket.once("open", done); socket.once("error", fail); socket.once("unexpected-response", (_, response) => fail(new Error(`socket ${response.statusCode}`))); setTimeout(() => fail(new Error("the socket did not open")), 10000); });
  socket.close();

  const restored = join(data, "workspaces", id, "1", name, "notes.txt");
  await writeFile(restored, "local saved edit");
  await writeFile(join(root, "notes.txt"), "changed text");
  assert.equal(push(root, base).last.generation, 2);
  assert.equal((await api(`/api/sync/workspaces/${id}/open`, { method: "POST" })).status, 200);
  for (let i = 0; i < 100; i++) { state = await (await fetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status === "ready") break; await new Promise(r => setTimeout(r, 100)); }
  assert.equal(state.status,"ready",JSON.stringify(state));
  assert.equal(await readFile(restored,"utf8"),"local saved edit","reopening renews access without replacing working files with the newer snapshot");
});

test("a restored session saves back with a capability for its own workspace, and only that", async t => {
  const port = await freePort(), base = `http://127.0.0.1:${port}`, captured = [];
  const host = await fixture({ port, appOrigin: base, provision: data => { captured.push(data); return json({ url: "ws://127.0.0.1:1/session", token: "compute-secret", project: "main.hx" }); } });
  t.after(() => host.mf.dispose());
  const { root } = await repository({ "main.hx": "class Main {}\n", "notes.txt": "one" });
  t.after(() => rm(root, { recursive: true, force: true }));
  const cliRun = (...args) => {
    const run = spawnSync(cli, args, { encoding: "utf8" });
    const events = run.stdout.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    return { code: run.status, events, last: events.at(-1) };
  };
  const first = cliRun(root, base, "alice");
  assert.equal(first.last.event, "published", JSON.stringify(first.events));
  const id = first.last.url.split("/").pop();
  const alice = (path, init = {}) => host.mf.dispatchFetch(base + "/api/sync" + path, { ...init, headers: { "X-Dev-Account": "alice", ...(init.headers ?? {}) } });
  assert.equal((await alice(`/workspaces/${id}/open`, { method: "POST" })).status, 200);
  const login = await host.mf.dispatchFetch(`${base}/auth/dev?account=alice&return=/${id}`, { redirect: "manual" });
  const cookie = login.headers.getSetCookie()[0].split(";")[0];
  let state;
  for (let i = 0; i < 100; i++) { state = await (await host.mf.dispatchFetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status !== "preparing") break; await new Promise(done => setTimeout(done, 100)); }
  assert.equal(state.status, "ready", JSON.stringify(state));
  assert.ok(!JSON.stringify(state).includes("rsp1."), "the capability is never stored or shown to the page");
  const grant = captured.at(-1).publish;
  assert.equal(grant.workspace, id);
  assert.match(grant.token, /^rsp1\./);

  const bearer = (token, path, init = {}) => host.mf.dispatchFetch(base + "/api/sync" + path, { ...init, headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) } });
  assert.equal((await bearer(grant.token, `/workspaces/${id}`)).status, 200, "it reads its own workspace");
  const other = await (await alice("/workspaces", post({}))).json();
  assert.equal((await bearer(grant.token, `/workspaces/${other.id}`)).status, 403, "not another workspace of the same owner");
  assert.equal((await bearer(grant.token, "/workspaces", post({}))).status, 403, "it cannot create workspaces");
  assert.equal((await bearer(grant.token, `/workspaces/${id}/open`, { method: "POST" })).status, 403, "it cannot open them");
  const forged = grant.token.slice(0, -2) + (grant.token.endsWith("AA") ? "BB" : "AA");
  assert.equal((await bearer(forged, `/workspaces/${id}`)).status, 401, "a token with a bad signature is refused");

  // The restored tree has no .git. Edit, add and delete, and save it back.
  const tree = await mkdtemp(join(tmpdir(), "rayde-sync-restored-"));
  t.after(() => rm(tree, { recursive: true, force: true }));
  await cp(root, tree, { recursive: true, filter: source => !source.split("/").includes(".git") });
  await writeFile(join(tree, "main.hx"), "class Main { static function main() {} }\n");
  await writeFile(join(tree, "added.txt"), "new");
  await rm(join(tree, "notes.txt"));
  const saved = cliRun(tree, base, "-", "writeback", id, grant.token, "1");
  assert.equal(saved.last.event, "published", JSON.stringify(saved.events));
  assert.equal(saved.last.generation, 2);
  const manifest = await (await alice(`/workspaces/${id}/export/manifest`)).json();
  assert.deepEqual(manifest.files.map(file => file.path).sort(), ["added.txt", "main.hx"]);
  assert.equal(manifest.baseGeneration ?? manifest.base_generation, 1);

  // The desktop has not seen generation 2, so syncing now would replace the browser's edits: it refuses and sends nothing.
  const desktop = cliRun(root, base, "alice");
  assert.equal(desktop.last.event, "error", JSON.stringify(desktop.events));
  assert.equal(desktop.last.code, "conflict");
  assert.equal((await (await alice(`/workspaces/${id}`)).json()).generation, 2, "nothing was replaced");

  // A second save against the old base is a conflict, and nothing moves.
  const stale = cliRun(tree, base, "-", "writeback", id, grant.token, "1");
  assert.equal(stale.last.event, "error", JSON.stringify(stale.events));
  assert.equal(stale.last.code, "conflict");
  assert.equal((await (await alice(`/workspaces/${id}`)).json()).generation, 2);

  // Only an explicit decision to replace them goes through.
  const forced = spawnSync(cli, [root, base, "alice"], { encoding: "utf8", env: { ...process.env, RAYDE_SYNC_FORCE: "1" } });
  const forcedEvents = forced.stdout.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  assert.equal(forcedEvents.at(-1).event, "published", forced.stdout);
  assert.equal(forcedEvents.at(-1).generation, 3);
});

test("a restored session saves its edits back through its own socket, and a newer cloud copy is a conflict", async t => {
  const { spawn } = await import("node:child_process");
  const { readFile } = await import("node:fs/promises");
  const port = await freePort(), base = `http://127.0.0.1:${port}`, data = await mkdtemp(join(tmpdir(), "rayde-sync-dev-"));
  const server = spawn("node", ["dev/sync-dev.mjs", "--port", String(port), "--data", data], { stdio: ["ignore", "pipe", "inherit"] });
  let log = "";
  server.stdout.on("data", chunk => { log += String(chunk); });
  t.after(async () => {
    const exited = new Promise(done => server.once("exit", done));
    server.kill();
    await exited;
    server.stdout.destroy();
    await rm(data, { recursive: true, force: true });
  });
  await new Promise((done, fail) => { const wait = setInterval(() => log.includes("Cloud Sync gateway") && (clearInterval(wait), done()), 50); server.once("exit", () => fail(new Error("the dev gateway exited"))); });
  const { root } = await repository({ "main.hx": "class Main {}\n", "notes.txt": "synced text" });
  t.after(() => rm(root, { recursive: true, force: true }));
  const pushed = push(root, base);
  assert.equal(pushed.last.event, "published", JSON.stringify(pushed.events));
  const id = pushed.last.url.split("/").pop();
  const alice = (path, init = {}) => fetch(base + "/api/sync" + path, { ...init, headers: { "X-Dev-Account": "alice", ...(init.headers ?? {}) } });
  assert.equal((await alice(`/workspaces/${id}/open`, { method: "POST" })).status, 200);
  const login = await fetch(`${base}/auth/dev?account=alice&return=/${id}`, { redirect: "manual" });
  const cookie = login.headers.getSetCookie()[0].split(";")[0];
  let state;
  for (let i = 0; i < 150; i++) { state = await (await fetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status !== "preparing") break; await new Promise(r => setTimeout(r, 100)); }
  assert.equal(state.status, "ready", JSON.stringify(state));
  const [, restoredRoot, sessionPort, sessionToken] = [...log.matchAll(/session for (\S+)\n\s+http:\/\/127\.0\.0\.1:(\d+)\/\n\s+token (\w+)/g)].at(-1);

  const { default: WebSocket } = await import("ws");
  const socket = new WebSocket(`ws://127.0.0.1:${sessionPort}/session`);
  await new Promise((done, fail) => { socket.once("open", done); socket.once("error", fail); });
  let next = 0;
  const pending = new Map();
  socket.on("message", raw => { const message = JSON.parse(String(raw)); pending.get(message.id)?.(message); });
  const ask = (op, fields = {}) => new Promise(done => { const id = ++next; pending.set(id, done); socket.send(JSON.stringify({ id, op, ...fields })); });
  t.after(() => socket.close());
  const hello = await ask("hello", { token: sessionToken });
  assert.equal(hello.ok, true, JSON.stringify(hello));
  assert.equal(hello.syncWriteback.workspace,id);
  assert.equal(hello.syncWriteback.generation,1,"the session knows what it was restored from and not the credential");
  assert.ok(!JSON.stringify(hello).includes("rsp1."));

  // Edit in the restored tree, which has no .git, and save it back.
  await writeFile(join(restoredRoot, "notes.txt"), "edited in the browser");
  await writeFile(join(restoredRoot, "added.txt"), "new file");
  const saved = await ask("sync.publish");
  assert.equal(saved.ok, true, JSON.stringify(saved));
  assert.equal(saved.generation, 2);
  const manifest = await (await alice(`/workspaces/${id}/export/manifest`)).json();
  assert.equal(manifest.generation, 2);
  assert.deepEqual(manifest.files.map(file => file.path).sort(), ["added.txt", "main.hx", "notes.txt"]);
  const entry = manifest.files.find(file => file.path === "notes.txt");
  assert.equal(Buffer.from(await (await alice(`/workspaces/${id}/export/chunks/${entry.chunks[0].hash}`)).arrayBuffer()).toString(), "edited in the browser");

  // The desktop pushes in between, so the session's base is stale.
  await writeFile(join(root, "notes.txt"), "desktop edit");
  assert.equal(push(root, base).last.code, "conflict", "the desktop has not seen the save, so it will not replace it unasked");
  const forced = spawnSync(cli, [root, base, "alice"], { encoding: "utf8", env: { ...process.env, RAYDE_SYNC_FORCE: "1" } });
  assert.equal(JSON.parse(forced.stdout.trim().split("\n").at(-1)).generation, 3);
  await writeFile(join(restoredRoot, "notes.txt"), "browser edit after");
  const conflict = await ask("sync.publish");
  assert.equal(conflict.ok, false, JSON.stringify(conflict));
  assert.equal(conflict.code, "conflict");
  assert.equal((await (await alice(`/workspaces/${id}`)).json()).generation, 3, "nothing was overwritten");
});

test("a restored session merges the cloud copy's newer generation: different places combine, the same lines are reported", async t => {
  const { spawn } = await import("node:child_process");
  const { readFile } = await import("node:fs/promises");
  const port = await freePort(), base = `http://127.0.0.1:${port}`, data = await mkdtemp(join(tmpdir(), "rayde-sync-dev-"));
  let server, log = "";
  const stop = async () => {
    if (!server || server.exitCode !== null || server.signalCode !== null) return;
    const exited = new Promise(done => server.once("exit", done));
    server.kill(); await exited; server.stdout.destroy();
  };
  const start = async () => {
    log = "";
    server = spawn("node", ["dev/sync-dev.mjs", "--port", String(port), "--data", data], { stdio: ["ignore", "pipe", "inherit"] });
    server.stdout.on("data", chunk => { log += String(chunk); });
    await new Promise((done, fail) => {
      const timer = setTimeout(() => fail(Error("The dev gateway did not start")), 10000);
      const output = () => { if (log.includes("Cloud Sync gateway")) { clearTimeout(timer); server.stdout.off("data", output); done(); } };
      server.stdout.on("data", output); server.once("exit", () => { clearTimeout(timer); fail(Error("The dev gateway exited")); });
    });
  };
  t.after(async () => { await stop(); await rm(data, { recursive: true, force: true }); });
  await start();
  const lines = edits => Array.from({ length: 12 }, (_, i) => `line ${i + 1}${edits[i + 1] ? " " + edits[i + 1] : ""}\n`).join("");
  const { root } = await repository({ "main.hx": "class Main {}\n", "doc.txt": lines({}) });
  t.after(() => rm(root, { recursive: true, force: true }));
  assert.equal(push(root, base).last.generation, 1);
  const id = JSON.parse(await readFile(join(root, ".git", "rayde-sync.json"), "utf8"))[base].workspace;
  const alice = (path, init = {}) => fetch(base + "/api/sync" + path, { ...init, headers: { "X-Dev-Account": "alice", ...(init.headers ?? {}) } });
  assert.equal((await alice(`/workspaces/${id}/open`, { method: "POST" })).status, 200);
  const login = await fetch(`${base}/auth/dev?account=alice&return=/${id}`, { redirect: "manual" });
  const cookie = login.headers.getSetCookie()[0].split(";")[0];
  let state;
  for (let i = 0; i < 150; i++) { state = await (await fetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status !== "preparing") break; await new Promise(r => setTimeout(r, 100)); }
  assert.equal(state.status, "ready", JSON.stringify(state));
  const { default: WebSocket } = await import("ws");
  let socket, ask;
  const connect = async () => {
    const [, restoredRoot, sessionPort, sessionToken] = [...log.matchAll(/session for (\S+)\n\s+http:\/\/127\.0\.0\.1:(\d+)\/\n\s+token (\w+)/g)].at(-1);
    socket = new WebSocket(`ws://127.0.0.1:${sessionPort}/session`);
    await new Promise((done, fail) => { socket.once("open", done); socket.once("error", fail); });
    let next = 0;
    const pending = new Map();
    socket.on("message", raw => { const message = JSON.parse(String(raw)); pending.get(message.id)?.(message); pending.delete(message.id); });
    ask = (op, fields = {}) => new Promise((done, fail) => {
      const id = ++next, timer = setTimeout(() => { pending.delete(id); fail(Error("Session timeout: " + op)); }, 10000);
      pending.set(id, reply => { clearTimeout(timer); done(reply); }); socket.send(JSON.stringify({ id, op, ...fields }));
    });
    assert.equal((await ask("hello", { token: sessionToken })).ok, true);
    let status;
    for (let i = 0; i < 150; i++) { status = await ask("sync.status"); if (status.syncWriteback?.ready) break; await new Promise(done => setTimeout(done, 20)); }
    assert.equal(status.syncWriteback?.ready, true, JSON.stringify(status));
    return restoredRoot;
  };
  t.after(() => socket?.close());
  const restoredRoot = await connect();
  const doc = join(restoredRoot, "doc.txt");
  const read = path => readFile(path, "utf8");

  // The browser edits line 10; the desktop edits line 2 and syncs first.
  await writeFile(doc, lines({ 10: "(browser)" }));
  await writeFile(join(root, "doc.txt"), lines({ 2: "(desktop)" }));
  assert.equal(push(root, base).last.generation, 2);
  const refused = await ask("sync.publish");
  assert.equal(refused.code, "conflict", "the cloud copy has moved on, so the save is refused");
  socket.close();
  await stop(); await start();
  assert.equal((await alice(`/workspaces/${id}/open`, { method: "POST" })).status, 200);
  for (let i = 0; i < 150; i++) { state = await (await fetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status !== "preparing") break; await new Promise(done => setTimeout(done, 100)); }
  assert.equal(state.status, "ready", JSON.stringify(state));
  assert.equal(await connect(), restoredRoot, "recovery keeps the existing working tree");
  assert.equal(await read(doc), lines({10:"(browser)"}), "recovery preserves the local saved edit");
  assert.equal((await ask("sync.status")).syncWriteback.generation, 1, "recovery keeps the original common base, although the cloud is at generation 2");
  const merged = await ask("sync.merge");
  assert.equal(merged.ok, true, JSON.stringify(merged));
  assert.deepEqual(merged.conflicts, []);
  assert.deepEqual(merged.written, ["doc.txt"]);
  assert.equal(merged.generation, 2);
  assert.equal(await read(doc), lines({ 2: "(desktop)", 10: "(browser)" }), "both edits are in the tree");
  const saved = await ask("sync.publish");
  assert.equal(saved.ok, true, JSON.stringify(saved));
  assert.equal(saved.generation, 3);
  const manifest = await (await alice(`/workspaces/${id}/export/manifest`)).json();
  const entry = manifest.files.find(file => file.path === "doc.txt");
  assert.equal(Buffer.from(await (await alice(`/workspaces/${id}/export/chunks/${entry.chunks[0].hash}`)).arrayBuffer()).toString(), lines({ 2: "(desktop)", 10: "(browser)" }), "the cloud holds both");

  // Both sides edit line 5: nothing is decided and nothing is changed.
  await writeFile(join(root, "doc.txt"), lines({ 2: "(desktop)", 5: "(desktop again)" }));
  const forced = spawnSync(cli, [root, base, "alice"], { encoding: "utf8", env: { ...process.env, RAYDE_SYNC_FORCE: "1" } });
  assert.equal(JSON.parse(forced.stdout.trim().split("\n").at(-1)).generation, 4);
  await writeFile(doc, lines({ 2: "(desktop)", 5: "(browser again)", 10: "(browser)" }));
  const before = await read(doc);
  const overlap = await ask("sync.merge");
  assert.equal(overlap.ok, true, JSON.stringify(overlap));
  assert.deepEqual(overlap.conflicts, [{ path: "doc.txt", reason: "both sides edited the same lines" }]);
  assert.deepEqual(overlap.written, []);
  assert.equal(await read(doc), before, "the file is left as it was");
  assert.equal((await ask("sync.publish")).code, "conflict", "and the save is still refused");

  // Choosing the cloud's version settles it: the tree takes it, and the session can save again.
  const settled = await ask("sync.merge", { choices: { "doc.txt": "theirs" } });
  assert.equal(settled.ok, true, JSON.stringify(settled));
  assert.deepEqual(settled.conflicts, []);
  assert.deepEqual(settled.written, ["doc.txt"]);
  assert.equal(await read(doc), lines({ 2: "(desktop)", 5: "(desktop again)" }), "the cloud's version replaced ours");
  const after = await ask("sync.publish");
  assert.equal(after.ok, true, JSON.stringify(after));
  assert.equal(after.generation, 5);
});

test("a folder pulls the cloud copy's newer generation, and a choice settles the files both devices edited in the same place", async t => {
  const { base } = await gateway(t);
  const lines = edits => Array.from({ length: 12 }, (_, i) => `line ${i + 1}${edits[i + 1] ? " " + edits[i + 1] : ""}\n`).join("");
  const { root: a } = await repository({ "doc.txt": lines({}), "other.txt": lines({}), "main.hx": "class Main {}\n" });
  t.after(() => rm(a, { recursive: true, force: true }));
  const run = (folder, action, env = {}) => {
    const out = spawnSync(cli, [folder, base, "alice", action], { encoding: "utf8", env: { ...process.env, ...env } });
    const events = out.stdout.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    return { events, last: events.at(-1) };
  };
  assert.equal(run(a, "push").last.generation, 1);

  // A second device that has synced generation 1 too: its own clone with the same record of what it last synced.
  const b = await mkdtemp(join(tmpdir(), "rayde-sync-device-"));
  t.after(() => rm(b, { recursive: true, force: true }));
  spawnSync("git", ["clone", "-q", a, join(b, "clone")]);
  const two = join(b, "clone");
  await cp(join(a, ".git", "rayde-sync.json"), join(two, ".git", "rayde-sync.json"));
  await cp(join(a, ".git", "rayde-sync-base"), join(two, ".git", "rayde-sync-base"), { recursive: true });
  const { readFile } = await import("node:fs/promises");
  const read = (folder, name) => readFile(join(folder, name), "utf8");
  const alice = (path, init = {}) => fetch(base + "/api/sync" + path, { ...init, headers: { "X-Dev-Account": "alice", ...(init.headers ?? {}) } });

  // The other device edits line 10 and syncs. This one edited line 2 and has not seen that.
  await writeFile(join(two, "doc.txt"), lines({ 10: "(other device)" }));
  assert.equal(run(two, "push").last.generation, 2);
  await writeFile(join(a, "doc.txt"), lines({ 2: "(this device)" }));
  const remote = run(a, "remote", { RAYDE_SYNC_PATH: "doc.txt" });
  assert.equal(remote.last.event, "remote", JSON.stringify(remote.events));
  assert.equal(remote.last.text, lines({ 10: "(other device)" }), "the cloud's version of a file can be read to compare with the local one");
  assert.equal(run(a, "remote", { RAYDE_SYNC_PATH: "nope.txt" }).last.code, "missing");
  const refused = run(a, "push");
  assert.equal(refused.last.code, "conflict", "it will not replace what the other device saved");

  const pulled = run(a, "pull");
  assert.equal(pulled.last.event, "merged", JSON.stringify(pulled.events));
  assert.deepEqual(pulled.last.conflicts, []);
  assert.deepEqual(pulled.last.written, ["doc.txt"]);
  assert.equal(await read(a, "doc.txt"), lines({ 2: "(this device)", 10: "(other device)" }), "both edits are in the folder");
  assert.equal(run(a, "push").last.generation, 3, "and the merged folder can now sync");
  assert.equal(run(a, "pull").last.written.length, 0, "nothing more to pull");

  // The other device catches up, then both edit the same lines of two files.
  assert.equal(run(two, "pull").last.event, "merged");
  await writeFile(join(two, "doc.txt"), lines({ 2: "(this device)", 10: "(other device)", 5: "(other)" }));
  await writeFile(join(two, "other.txt"), lines({ 5: "(other)" }));
  assert.equal(run(two, "push").last.generation, 4);
  await writeFile(join(a, "doc.txt"), lines({ 2: "(this device)", 10: "(other device)", 5: "(mine)" }));
  await writeFile(join(a, "other.txt"), lines({ 5: "(mine)" }));
  const before = [await read(a, "doc.txt"), await read(a, "other.txt")];
  const stuck = run(a, "pull");
  assert.deepEqual(stuck.last.conflicts.map(c => c.path), ["doc.txt", "other.txt"]);
  assert.deepEqual([await read(a, "doc.txt"), await read(a, "other.txt")], before, "with no choice nothing is changed");
  assert.equal(run(a, "push").last.code, "conflict");

  const settled = run(a, "pull", { RAYDE_SYNC_CHOICES: JSON.stringify({ "doc.txt": "mine", "other.txt": "theirs" }) });
  assert.equal(settled.last.event, "merged", JSON.stringify(settled.events));
  assert.deepEqual(settled.last.conflicts, []);
  assert.equal(await read(a, "doc.txt"), before[0], "kept mine");
  assert.equal(await read(a, "other.txt"), lines({ 5: "(other)" }), "took the other device's");
  assert.equal(run(a, "push").last.generation, 5);
  const id = JSON.parse(await readFile(join(a, ".git", "rayde-sync.json"), "utf8"))[base].workspace;
  const manifest = await (await alice(`/workspaces/${id}/export/manifest`)).json();
  const cloudDoc = manifest.files.find(file => file.path === "doc.txt");
  assert.equal(Buffer.from(await (await alice(`/workspaces/${id}/export/chunks/${cloudDoc.chunks[0].hash}`)).arrayBuffer()).toString(), before[0], "the cloud now holds the version that was kept");
});

test("a folder synced before bases were kept can still pull: what differs is listed, and a choice settles it", async t => {
  const { base } = await gateway(t);
  const { readFile } = await import("node:fs/promises");
  const { root: a } = await repository({ "doc.txt": "doc\n", "other.txt": "other\n", "main.hx": "class Main {}\n" });
  t.after(() => rm(a, { recursive: true, force: true }));
  const run = (folder, action, env = {}) => {
    const out = spawnSync(cli, [folder, base, "alice", action], { encoding: "utf8", env: { ...process.env, ...env } });
    const events = out.stdout.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    return { events, last: events.at(-1) };
  };
  assert.equal(run(a, "push").last.generation, 1);

  // Another device, then this folder as an older version of RayDE left it: it knows its workspace and nothing else.
  const b = await mkdtemp(join(tmpdir(), "rayde-sync-device-"));
  t.after(() => rm(b, { recursive: true, force: true }));
  const two = join(b, "clone");
  spawnSync("git", ["clone", "-q", a, two]);
  await cp(join(a, ".git", "rayde-sync.json"), join(two, ".git", "rayde-sync.json"));
  await cp(join(a, ".git", "rayde-sync-base"), join(two, ".git", "rayde-sync-base"), { recursive: true });
  await rm(join(a, ".git", "rayde-sync-base"), { recursive: true, force: true });
  const state = JSON.parse(await readFile(join(a, ".git", "rayde-sync.json"), "utf8"));
  for (const key of Object.keys(state)) state[key] = { workspace: state[key].workspace };
  await writeFile(join(a, ".git", "rayde-sync.json"), JSON.stringify(state));

  await writeFile(join(two, "other.txt"), "other, edited on the other device\n");
  assert.equal(run(two, "push").last.generation, 2);
  await writeFile(join(a, "main.hx"), "class Main { static function main() {} }\n");
  const before = [await readFile(join(a, "main.hx"), "utf8"), await readFile(join(a, "other.txt"), "utf8")];

  const listed = run(a, "pull");
  assert.equal(listed.last.event, "merged", JSON.stringify(listed.events));
  assert.equal(listed.last.withoutBase, true);
  assert.deepEqual(listed.last.conflicts.map(c => c.path), ["main.hx", "other.txt"], "everything that differs is listed, since there is no telling who changed it");
  assert.deepEqual([await readFile(join(a, "main.hx"), "utf8"), await readFile(join(a, "other.txt"), "utf8")], before, "and nothing is changed");

  const settled = run(a, "pull", { RAYDE_SYNC_CHOICES: JSON.stringify({ "main.hx": "mine", "other.txt": "theirs" }) });
  assert.equal(settled.last.event, "merged", JSON.stringify(settled.events));
  assert.deepEqual(settled.last.conflicts, []);
  assert.equal(await readFile(join(a, "main.hx"), "utf8"), before[0], "kept this folder's own change");
  assert.equal(await readFile(join(a, "other.txt"), "utf8"), "other, edited on the other device\n", "took the other device's");
  assert.equal(run(a, "push").last.generation, 3, "and the folder syncs");

  // From here it has a base like any other folder: a later pull merges without asking.
  await writeFile(join(two, "doc.txt"), "doc, from the other device\n");
  assert.equal(run(two, "pull").last.event, "merged");
  assert.equal(run(two, "push").last.generation, 4);
  await writeFile(join(a, "main.hx"), "class Main { static function main() { trace(1); } }\n");
  const later = run(a, "pull");
  assert.equal(later.last.withoutBase, false);
  assert.deepEqual(later.last.conflicts, []);
  assert.deepEqual(later.last.written, ["doc.txt"]);
});

test("a folder pulls a link another device added or retargeted, and two retargets of one link are a conflict", async t => {
  const { base } = await gateway(t);
  const { root: a } = await repository({ "doc.txt": "one\n", "two.txt": "two\n" });
  t.after(() => rm(a, { recursive: true, force: true }));
  const run = (folder, action, env = {}) => {
    const out = spawnSync(cli, [folder, base, "alice", action], { encoding: "utf8", env: { ...process.env, ...env } });
    const events = out.stdout.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    return { events, last: events.at(-1) };
  };
  assert.equal(run(a, "push").last.generation, 1);
  const b = await mkdtemp(join(tmpdir(), "rayde-sync-device-"));
  t.after(() => rm(b, { recursive: true, force: true }));
  spawnSync("git", ["clone", "-q", a, join(b, "clone")]);
  const two = join(b, "clone");
  await cp(join(a, ".git", "rayde-sync.json"), join(two, ".git", "rayde-sync.json"));
  await cp(join(a, ".git", "rayde-sync-base"), join(two, ".git", "rayde-sync-base"), { recursive: true });
  const { symlink, readlink } = await import("node:fs/promises");

  await symlink("doc.txt", join(two, "latest"));
  assert.equal(run(two, "push").last.generation, 2);
  const added = run(a, "pull");
  assert.equal(added.last.event, "merged", JSON.stringify(added.events));
  assert.deepEqual(added.last.written, ["latest"]);
  assert.equal(await readlink(join(a, "latest")), "doc.txt", "the link came over as a link");

  assert.equal(run(a, "push").last.generation, 3);
  assert.equal(run(two, "pull").last.event, "merged");
  await rm(join(two, "latest"));
  await symlink("two.txt", join(two, "latest"));
  assert.equal(run(two, "push").last.generation, 4);
  assert.equal(run(a, "pull").last.written[0], "latest");
  assert.equal(await readlink(join(a, "latest")), "two.txt", "a retargeted link moves over");

  assert.equal(run(a, "push").last.generation, 5);
  assert.equal(run(two, "pull").last.event, "merged");
  await rm(join(two, "latest"));
  await symlink("doc.txt", join(two, "latest"));
  assert.equal(run(two, "push").last.generation, 6);
  await rm(join(a, "latest"));
  await symlink("other", join(a, "latest"));
  const stuck = run(a, "pull");
  assert.deepEqual(stuck.last.conflicts.map(c => c.reason), ["a link changed on both sides"]);
  assert.equal(await readlink(join(a, "latest")), "other", "nothing was changed");
  const settled = run(a, "pull", { RAYDE_SYNC_CHOICES: JSON.stringify({ latest: "theirs" }) });
  assert.deepEqual(settled.last.conflicts, [], JSON.stringify(settled.events));
  assert.equal(await readlink(join(a, "latest")), "doc.txt", "choosing the remote link replaces ours");
});
