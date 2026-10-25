import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fixture, signin, origin } from "./fixture.mjs";

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
  const closed = new Promise(resolve => socket.addEventListener("close", resolve, { once: true }));
  assert.equal((await fetch("/api/logout", { method: "POST", headers: alice.headers, body: "{}" })).status, 200);
  const event = await Promise.race([closed, sleep(3000).then(() => { throw new Error("Logout left the workspace socket open"); })]);
  assert.equal(event.code, 1008);
});
