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

  await writeFile(join(root, "notes.txt"), "changed text");
  assert.equal(push(root, base).last.generation, 2);
  assert.equal((await api(`/api/sync/workspaces/${id}/open`, { method: "POST" })).status, 200);
  for (let i = 0; i < 100; i++) { state = await (await fetch(`${base}/api/workspaces/${id}`, { headers: { Cookie: cookie } })).json(); if (state.status === "ready" && (await readFile(join(data, "workspaces", id, "2", name, "notes.txt"), "utf8").catch(() => ""))) break; await new Promise(r => setTimeout(r, 100)); }
  assert.equal(await readFile(join(data, "workspaces", id, "2", name, "notes.txt"), "utf8"), "changed text", "a newer generation is restored again");
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

  // A second save against the old base is a conflict, and nothing moves.
  const stale = cliRun(tree, base, "-", "writeback", id, grant.token, "1");
  assert.equal(stale.last.event, "error", JSON.stringify(stale.events));
  assert.equal(stale.last.code, "conflict");
  assert.equal((await (await alice(`/workspaces/${id}`)).json()).generation, 2);
});
