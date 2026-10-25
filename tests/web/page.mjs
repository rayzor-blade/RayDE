// Opens RayDE's page build (scripts/build-web.sh) in Chrome, drives it, and prints what it measured.
//
//   node tests/web/page.mjs [--dir bin/web/rayde] [--shots bin/web/shots]
//
// Needs Google Chrome (WebGPU, wasm exception handling) and puppeteer-core (web/session's node_modules).
import { spawn, execSync } from "node:child_process";
import { mkdirSync, existsSync } from "node:fs";
import { createServer } from "node:net";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const require = createRequire(join(root, "web/session/package.json"));
const puppeteer = require("puppeteer-core");
const args = process.argv.slice(2);
const option = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const dir = resolve(root, option("--dir", "bin/web/rayde"));
const shots = resolve(root, option("--shots", "bin/web/shots"));
const visitor = option("--visitor", "");
const scheme = option("--scheme", "");
const flip = args.includes("--flip");
const envs = [visitor && "RAYDE_VISITOR=" + visitor, args.includes("--standalone") && "RAYDE_STANDALONE=1"].filter(Boolean);
const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
mkdirSync(shots, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((r) => { const s = createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => r(port)); }); });
const mb = (kb) => (kb / 1024).toFixed(0) + " MB";

/** Resident memory of the browser and its helpers, in KB, by role. */
function memory(pid) {
  const rows = execSync("ps -axo pid=,ppid=,rss=,command=").toString().split("\n").filter(Boolean).map((l) => {
    const m = l.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
    return m && { pid: +m[1], ppid: +m[2], rss: +m[3], command: m[4] };
  }).filter(Boolean);
  const mine = new Set([pid]);
  for (let grew = true; grew;) { grew = false; for (const r of rows) if (!mine.has(r.pid) && mine.has(r.ppid)) { mine.add(r.pid); grew = true; } }
  const out = { renderer: 0, gpu: 0, other: 0 };
  for (const r of rows) if (mine.has(r.pid)) out[/--type=renderer/.test(r.command) ? "renderer" : /--type=gpu-process/.test(r.command) ? "gpu" : "other"] += r.rss;
  return out;
}

const port = await freePort();
const server = spawn("ash", ["serve", "--port", String(port), dir], { stdio: "ignore" });
await sleep(1500);
const browser = await puppeteer.launch({ executablePath: chrome, headless: "new", args: ["--no-sandbox", "--enable-unsafe-webgpu", "--window-size=1280,900"], defaultViewport: { width: 1280, height: 800 } });
const result = { ok: false };
try {
  const page = await browser.newPage();
  const lines = [];
  page.on("console", (m) => lines.push(m.text()));
  page.on("pageerror", (e) => lines.push("PAGE ERROR " + e.message));
  if (scheme) await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme }]);
  const started = Date.now();
  await page.goto(`http://127.0.0.1:${port}/index.html${envs.length ? "?" + envs.map((e) => "env=" + e).join("&") : ""}`);
  await page.waitForFunction(() => /RayDE/.test(document.title), { timeout: 120000 });
  const titled = Date.now() - started;
  for (let i = 0; i < 400 && !lines.some((l) => /ashui: ready/.test(l)); i++) await sleep(100);
  const ready = Date.now() - started;
  await sleep(Number(option("--settle", "2")) * 1000);
  result.title = await page.title();
  result.readyMs = ready;
  result.titledMs = titled;
  result.afterReady = memory(browser.process().pid);
  await page.screenshot({ path: join(shots, "welcome.png") });
  if (args.includes("--timeline")) for (const t of [3, 6, 10]) { await sleep(t * 1000 - (t > 3 ? (t === 6 ? 3000 : 6000) : 0)); await page.screenshot({ path: join(shots, `t${t}.png`) }); }

  // The scheme changes while the page runs: the app follows.
  if (flip) {
    await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme === "light" ? "dark" : "light" }]);
    await sleep(Number(option("--settle", "2")) * 1000);
    await page.screenshot({ path: join(shots, "flipped.png") });
  }

  // Open Main.hx from the Explorer, then type into it.
  await page.mouse.click(147, 189);
  await sleep(1500);
  await page.screenshot({ path: join(shots, "open.png") });
  await page.mouse.click(700, 300);
  await sleep(300);
  await page.keyboard.type("// typed in a page", { delay: 15 });
  await sleep(1000);
  await page.screenshot({ path: join(shots, "typed.png") });
  result.afterEdit = memory(browser.process().pid);
  result.console = lines.filter((l) => !/^thread |agent entering|^\[ash\] loaded/.test(l)).slice(-12);
  result.ok = true;
} finally {
  await browser.close();
  server.kill();
}
const fmt = (m) => `renderer ${mb(m.renderer)}, gpu ${mb(m.gpu)}, other ${mb(m.other)}, total ${mb(m.renderer + m.gpu + m.other)}`;
console.log(`title: ${result.title}`);
console.log(`window title at ${result.titledMs} ms, ashui ready at ${result.readyMs} ms (local server, no compression)`);
console.log(`memory after ready: ${fmt(result.afterReady)}`);
console.log(`memory after opening a file and typing: ${fmt(result.afterEdit)}`);
console.log("last console lines:\n  " + result.console.join("\n  "));
process.exit(result.ok ? 0 : 1);
