// Explicit browser check (needs Chrome): a synced workspace opened in the editor talks to its restored session. It records the editor's own socket to
// /api/workspaces/{id}/socket and requires that the file listing and a file's content arrive over it.
//   node test/sync-browser.mjs
import { createRequire } from "node:module";
import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";

const puppeteer = createRequire(new URL("../../session/package.json", import.meta.url))("puppeteer-core");
const push = resolve("../../native/sync/target/debug/examples/push");
const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = ms => new Promise(done => setTimeout(done, ms));
const freePort = () => new Promise(done => { const s = createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => done(p)); }); });

const port = await freePort(), base = `http://127.0.0.1:${port}`;
const data = await mkdtemp(join(tmpdir(), "rayde-sync-browser-"));
const folder = await mkdtemp(join(tmpdir(), "rayde-sync-folder-"));
const marker = `synced-${Date.now()}`;
const git = (...args) => spawnSync("git", ["-C", folder, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", ...args], { encoding: "utf8" });
git("init", "-q", "-b", "main");
await writeFile(join(folder, "build.hxml"), "-main Main\n--interp\n");
await writeFile(join(folder, "Main.hx"), `class Main {\n  static function main() { trace("${marker}"); }\n}\n`);
git("add", "-A"); git("commit", "-q", "-m", "first");

const server = spawn("node", ["dev/sync-dev.mjs", "--port", String(port), "--data", data], { stdio: ["ignore", "pipe", "inherit"] });
let browser;
const cleanup = async () => { await browser?.close().catch(() => {}); server.kill(); await rm(data, { recursive: true, force: true }); await rm(folder, { recursive: true, force: true }); };
try {
  await new Promise((done, fail) => { server.stdout.on("data", c => String(c).includes("Cloud Sync gateway") && done()); server.once("exit", () => fail(Error("the dev gateway exited"))); });
  const run = (...extra) => JSON.parse(spawnSync(push, [folder, base, "alice", ...extra], { encoding: "utf8" }).stdout.trim().split("\n").at(-1));
  const published = run();
  assert.equal(published.event, "published", JSON.stringify(published));
  assert.equal(run("open").event, "opened");
  const id = published.id;

  browser = await puppeteer.launch({ executablePath: chrome, headless: "new", args: ["--no-sandbox", "--enable-unsafe-webgpu"], defaultViewport: { width: 1280, height: 800 } });
  const page = await browser.newPage();
  const cdp = await page.createCDPSession();
  await cdp.send("Network.enable");
  const sockets = new Map(), sent = [], received = [];
  const text = frame => frame.opcode === 2 ? Buffer.from(frame.payloadData, "base64").toString("latin1") : frame.payloadData;
  cdp.on("Network.webSocketCreated", e => sockets.set(e.requestId, e.url));
  cdp.on("Network.webSocketFrameSent", e => { if (sockets.get(e.requestId)?.includes(`/api/workspaces/${id}/socket`)) sent.push(text(e.response)); });
  cdp.on("Network.webSocketFrameReceived", e => { if (sockets.get(e.requestId)?.includes(`/api/workspaces/${id}/socket`)) received.push(text(e.response)); });
  const errors = [];
  page.on("pageerror", e => errors.push(String(e)));

  // A direct visit with no session is signed in as the development account.
  await page.goto(`${base}/${id}`, { waitUntil: "domcontentloaded" });
  const until = async (done, what, ms = 60000) => { const end = Date.now() + ms; while (Date.now() < end) { if (done()) return; await sleep(250); } throw Error(`${what}\nsent ${sent.length}, received ${received.length}\n${errors.join("\n")}`); };

  await until(() => [...sockets.values()].some(url => url.includes(`/api/workspaces/${id}/socket`)), "the editor never opened the workspace socket");
  await until(() => sent.length > 0 && received.length > 0, "the editor and the session exchanged nothing");
  await until(() => received.some(frame => frame.includes("Main.hx")), "the session never listed the synced files");

  // Open the file from the Explorer: its content has to come back from the session, not from anything the page had.
  await sleep(1500);
  await page.mouse.click(140, 140);
  await page.mouse.click(140, 140, { count: 2 });
  try {
    await until(() => received.some(frame => frame.includes(marker)), "Main.hx was not read through the session");
  } catch (error) {
    await page.screenshot({ path: join(tmpdir(), "sync-browser-failure.png") });
    throw error;
  }
  assert.equal(errors.length, 0, errors.join("\n"));
  console.log(`channel ok: ${sent.length} frames sent, ${received.length} received, content of Main.hx came from the session`);
} finally {
  await cleanup();
}
process.exit(0);
