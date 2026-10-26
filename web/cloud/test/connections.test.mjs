import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer as tcpServer } from "node:net";
import { createServer as httpServer } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fixture, signin, origin, listening } from "./fixture.mjs";

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, timeout = 5000) {
  const end = Date.now() + timeout;
  while (!await check()) {
    if (Date.now() >= end) throw Error("Connection cleanup did not settle");
    await pause(20);
  }
}
const freePort = () => new Promise(resolve => {
  const server = tcpServer().listen(0, "127.0.0.1", () => {
    const port = server.address().port; server.close(() => resolve(port));
  });
});
async function workspace(fetch, user) {
  const response = await fetch("/api/workspaces/open", { method: "POST", headers: user.headers, body: '{"repository":111}' });
  assert.equal(response.status, 200);
  const record = await response.json(), path = "/api/workspaces/" + record.id;
  await until(async () => (await (await fetch(path, { headers: user.headers })).json()).status === "ready");
  return path;
}
function rpc(socket) {
  let next = 1;
  const waiting = new Map();
  socket.addEventListener("message", event => {
    const reply = JSON.parse(event.data);
    waiting.get(reply.id)?.(reply); waiting.delete(reply.id);
  });
  return (op, params = {}) => new Promise((resolve, reject) => {
    const id = next++, timer = setTimeout(() => { waiting.delete(id); reject(Error("Gateway timeout: " + op)); }, 5000);
    waiting.set(id, reply => { clearTimeout(timer); resolve(reply); });
    socket.send(JSON.stringify({ ...params, id, op }));
  });
}
async function accept(response) {
  assert.equal(response.status, 101);
  const socket = response.webSocket; socket.accept();
  const request = rpc(socket);
  assert.equal((await request("hello")).ok, true);
  return { socket, request };
}

test("hosted connection admission includes the final concurrent slot and releases on close, invalid input, logout and backend loss", async t => {
  const root = await mkdtemp(join(tmpdir(), "rayde-connections-")), port = await freePort();
  let server;
  async function stop() {
    if (server?.exitCode === null && server.signalCode === null) {
      const exited = once(server, "exit"); server.kill(); await exited;
    }
  }
  async function start() {
    server = spawn(resolve("../../native/session/target/debug/rayde-session"), ["--root", root, "--state-root", join(root, "state"), "--port", String(port), "--token", "compute-secret", "--origin", origin], { stdio: "ignore" });
    await listening(port, server);
  }
  await start();
  const cloud = await fixture({ endpoint: `ws://127.0.0.1:${port}/session` });
  t.after(async () => { await cloud.mf.dispose(); await stop(); await rm(root, { recursive: true, force: true }); });
  const alice = await signin(cloud.fetch), bob = await signin(cloud.fetch, "bob");
  const a = await workspace(cloud.fetch, alice), b = await workspace(cloud.fetch, bob);
  const open = user => cloud.fetch((user === bob ? b : a) + "/socket", { headers: { ...user.headers, Upgrade: "websocket" } });
  const clients = [];
  for (let i = 0; i < 7; i++) clients.push(await accept(await open(alice)));
  const contenders = await Promise.all([open(alice), open(alice)]);
  assert.deepEqual(contenders.map(r => r.status).sort(), [101, 429]);
  clients.push(await accept(contenders.find(r => r.status === 101)));
  for (let i = 0; i < 10; i++) assert.equal((await clients[0].request("hello")).ok, true);
  assert.equal((await open(alice)).status, 429);
  const other = await accept(await open(bob));
  assert.equal((await other.request("fs.list")).ok, true, "another workspace retains its own capacity");
  async function replace() {
    let response;
    await until(async () => { response = await open(alice); assert.ok([101, 429].includes(response.status)); return response.status === 101; });
    return accept(response);
  }
  clients.pop().socket.close();
  clients.push(await replace());
  const invalid = clients.pop();
  const invalidClosed = new Promise(resolve => invalid.socket.addEventListener("close", resolve, { once: true }));
  invalid.socket.send("not json");
  assert.equal((await invalidClosed).code, 1008);
  clients.push(await replace());
  const lost = clients.map(client => new Promise(resolve => client.socket.addEventListener("close", resolve, { once: true })));
  await stop(); await Promise.all(lost); await start();
  clients.length = 0;
  for (let i = 0; i < 8; i++) clients.push(await accept(await open(alice)));
  const signedOut = clients.map(client => new Promise(resolve => client.socket.addEventListener("close", resolve, { once: true })));
  assert.equal((await cloud.fetch("/api/logout", { method: "POST", headers: alice.headers, body: "{}" })).status, 200);
  assert.ok((await Promise.all(signedOut)).every(event => event.code === 1008));
  const again = await signin(cloud.fetch);
  await workspace(cloud.fetch, again);
  for (let i = 0; i < 8; i++) clients[i] = await accept(await open(again));
  assert.equal((await open(again)).status, 429);
  for (const client of clients) client.socket.close(); other.socket.close();
});

test("hosted admission reserves slow upstream opens and releases failed, timed out and signed-out handshakes", async t => {
  let mode = "stall", attempts = 0;
  const held = new Set();
  const fail = socket => socket.end("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n", () => socket.destroy());
  const backend = httpServer();
  backend.on("upgrade", (_request, socket) => {
    attempts++;
    socket.on("error", () => {});
    socket.once("end", () => socket.destroy());
    socket.resume();
    if (mode === "fail") fail(socket);
    else { held.add(socket); socket.once("close", () => held.delete(socket)); }
  });
  backend.listen(0, "127.0.0.1"); await once(backend, "listening");
  const cloud = await fixture({ endpoint: `ws://127.0.0.1:${backend.address().port}/session` });
  t.after(async () => { for (const socket of held) socket.destroy(); backend.close(); await cloud.mf.dispose(); });
  const user = await signin(cloud.fetch), path = await workspace(cloud.fetch, user);
  const open = (account = user) => cloud.fetch(path + "/socket", { headers: { ...account.headers, Upgrade: "websocket" } });
  let pending = Array.from({ length: 8 }, () => open());
  await until(() => attempts === 8);
  assert.equal((await open()).status, 429);
  assert.equal(attempts, 8, "refusal must happen before dialing compute");
  for (const socket of held) fail(socket);
  assert.ok((await Promise.all(pending)).every(response => response.status === 502));
  await until(() => held.size === 0);
  mode = "fail";
  for (let i = 0; i < 10; i++) assert.equal((await open()).status, 502, "failed upgrades must release their reservation");
  mode = "stall";
  const before = attempts;
  pending = Array.from({ length: 8 }, () => open());
  await until(() => attempts === before + 8);
  const started = Date.now();
  assert.ok((await Promise.all(pending)).every(response => response.status === 504));
  assert.ok(Date.now() - started < 12000, "upstream deadline must finish stalled opens");
  await until(() => held.size === 0);
  const beforeLogout = attempts;
  pending = Array.from({ length: 8 }, () => open());
  await until(() => attempts === beforeLogout + 8);
  assert.equal((await cloud.fetch("/api/logout", { method: "POST", headers: user.headers, body: "{}" })).status, 200);
  assert.ok((await Promise.all(pending)).every(response => response.status === 403));
  await until(() => held.size === 0);
  const again = await signin(cloud.fetch); await workspace(cloud.fetch, again);
  mode = "fail";
  assert.ok((await Promise.all(Array.from({ length: 8 }, () => open(again)))).every(response => response.status === 502));
});
