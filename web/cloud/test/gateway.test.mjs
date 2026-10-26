import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fixture, signin, origin } from "./fixture.mjs";
import { once } from "node:events";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const freePort = () => new Promise(resolve => { const server = createServer().listen(0, "127.0.0.1", () => { const port = server.address().port; server.close(() => resolve(port)); }); });

test("authenticated Rust gateway reaches a real Rust workspace, hides its token, and disconnects on logout", async t => {
  const root = await mkdtemp(join(tmpdir(), "rayde-gateway-"));
  await writeFile(join(root, "hello.txt"), "from the remote workspace");
  const port = await freePort();
  const server = spawn(resolve("../../native/session/target/debug/rayde-session"), ["--root", root, "--port", String(port), "--token", "compute-secret", "--origin", origin], { stdio: "ignore" });
  t.after(async () => { server.kill(); await rm(root, { recursive: true, force: true }); });
  await sleep(300);
  const { mf, fetch } = await fixture({ endpoint: `ws://127.0.0.1:${port}/session` }); t.after(() => mf.dispose());
  const alice = await signin(fetch), bob = await signin(fetch, "bob");
  const opening = await (await fetch("/api/workspaces/open", { method: "POST", headers: alice.headers, body: '{"repository":111}' })).json();
  const path = "/api/workspaces/" + opening.id;
  for (let i = 0; i < 100; i++) { if ((await (await fetch(path, { headers: alice.headers })).json()).status === "ready") break; await sleep(10); }
  assert.equal((await fetch(path + "/socket", { headers: { ...bob.headers, Upgrade: "websocket" } })).status, 403);
  assert.equal((await fetch(path + "/socket", { headers: { ...alice.headers, Origin: "https://evil.invalid", Upgrade: "websocket" } })).status, 403);
  const response = await fetch(path + "/socket", { headers: { ...alice.headers, Upgrade: "websocket" } });
  assert.equal(response.status, 101, await response.text());
  const socket = response.webSocket; socket.accept();
  let next = 1;
  const waiting = new Map();
  socket.addEventListener("message", event => { const data = JSON.parse(event.data); waiting.get(data.id)?.(data); waiting.delete(data.id); });
  function rpc(op, params = {}) { return new Promise((resolve, reject) => {
    const id = next++, timer = setTimeout(() => { waiting.delete(id); reject(new Error("Gateway timeout: " + op)); }, 5000);
    waiting.set(id, value => { clearTimeout(timer); resolve(value); });
    socket.send(JSON.stringify({ ...params, id, op }));
  }); }
  const hello = await rpc("hello", { token: "a browser cannot supply the compute credential" });
  assert.equal(hello.ok, true, JSON.stringify(hello));
  const file = await rpc("fs.read", { path: "hello.txt" });
  assert.equal(file.data, "from the remote workspace");
  assert.ok(!JSON.stringify(hello).includes("compute-secret"));
  assert.equal(hello.cacheIdentity.version, 1);
  assert.equal(hello.cacheIdentity.workspace, opening.id);
  assert.equal(hello.cacheIdentity.principal, "account:1");
  const repeated = await Promise.all([rpc("hello"), rpc("hello")]);
  for (const reply of repeated) assert.deepEqual(reply.cacheIdentity, hello.cacheIdentity);
  const closed = new Promise(resolve => socket.addEventListener("close", resolve, { once: true }));
  assert.equal((await fetch("/api/logout", { method: "POST", headers: alice.headers, body: "{}" })).status, 200);
  const event = await Promise.race([closed, sleep(3000).then(() => { throw new Error("Logout left the workspace socket open"); })]);
  assert.equal(event.code, 1008);
});

test("hosted recovery follows the verified owner, logical workspace, and compute document-state generation", async t => {
  const root = await mkdtemp(join(tmpdir(), "rayde-gateway-identity-")), port = await freePort();
  let server;
  async function stop() { if (server?.exitCode === null && server.signalCode === null) { const exited = once(server, "exit"); server.kill(); await exited; } }
  async function start(state) {
    server = spawn(resolve("../../native/session/target/debug/rayde-session"), ["--root", root, "--state-root", join(root, state), "--port", String(port), "--token", "compute-secret", "--origin", origin], { stdio: "ignore" });
    await sleep(300); assert.equal(server.exitCode, null);
  }
  t.after(async () => { await stop(); await rm(root, { recursive: true, force: true }); });
  await start("state");
  const { mf, fetch } = await fixture({ endpoint: `ws://127.0.0.1:${port}/session` }); t.after(() => mf.dispose());
  const alice = await signin(fetch), bob = await signin(fetch, "bob");
  async function workspace(user) {
    const opening = await (await fetch("/api/workspaces/open", { method: "POST", headers: user.headers, body: '{"repository":111}' })).json();
    const path = "/api/workspaces/" + opening.id;
    for (let i = 0; i < 100; i++) { if ((await (await fetch(path, { headers: user.headers })).json()).status === "ready") return { id: opening.id, path }; await sleep(10); }
    throw Error("Workspace did not become ready");
  }
  async function identity(user, workspace) {
    const response = await fetch(workspace.path + "/socket", { headers: { ...user.headers, Upgrade: "websocket" } });
    assert.equal(response.status, 101); const socket = response.webSocket; socket.accept();
    try {
      const hello = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(Error("Hello timed out")), 5000);
        socket.addEventListener("message", event => { const reply = JSON.parse(event.data); if (reply.id === 1) { clearTimeout(timer); resolve(reply); } });
        socket.send(JSON.stringify({ id: 1, op: "hello", cacheIdentity: { authority: "spoof", workspace: "spoof", principal: "account:999" } }));
      });
      assert.equal(hello.ok, true); assert.equal(hello.cacheIdentity.workspace, workspace.id);
      assert.ok(!JSON.stringify(hello.cacheIdentity).includes("spoof"));
      assert.ok(!JSON.stringify(hello.cacheIdentity).includes("compute-secret"));
      return hello.cacheIdentity;
    } finally { socket.close(); }
  }
  const a = await workspace(alice), b = await workspace(bob);
  const original = await identity(alice, a), other = await identity(bob, b);
  assert.equal(original.principal, "account:1"); assert.equal(other.principal, "account:2");
  assert.notEqual(original.workspace, other.workspace); assert.notDeepEqual(original, other);
  await stop(); await start("state");
  assert.deepEqual(await identity(alice, a), original);
  await stop(); await start("new-state");
  const replacement = await identity(alice, a);
  assert.equal(replacement.workspace, original.workspace); assert.equal(replacement.principal, original.principal);
  assert.notEqual(replacement.authority, original.authority);
});
