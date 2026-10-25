// Opens RayDE's page build (scripts/build-web.sh) in Chrome, drives it, and prints what it measured.
//
//   node tests/web/page.mjs [--dir bin/web/rayde] [--shots bin/web/shots]
//
// Needs Google Chrome (WebGPU, wasm exception handling) and puppeteer-core (web/session's node_modules).
import { spawn, execSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { createServer as httpServer } from "node:http";
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
const probe = args.includes("--probe");
const envs = [args.includes("--standalone") && "RAYDE_STANDALONE=1", ...args.flatMap((arg, i) => arg === "--env" ? [args[i + 1]] : [])].filter(Boolean);
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
const workspace = option("--session-root", null);
let session, sessionPort;
if (workspace) {
  sessionPort = await freePort();
  session = spawn(join(root, "native/session/target/debug/rayde-session"), [
    "--root", resolve(workspace), "--port", String(sessionPort), "--token", "page-test",
    "--origin", `http://127.0.0.1:${port}`, "--exec", "--extension-host", join(root, "bin/rayde-extension-host"),
    "--extensions", join(root, "extensions"),
  ], { stdio: "ignore" });
}
let server;
if (probe) {
  server = httpServer((request, response) => {
    try {
      const name = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
      const file = resolve(dir, "." + (name === "/" ? "/index.html" : name));
      if (!file.startsWith(dir + "/")) throw new Error("outside output");
      let body = name === "/gpu-probe.mjs" ? readFileSync(join(here, "gpu-probe.mjs")) : readFileSync(file);
      if (name === "/gpu-worker.mjs") body = Buffer.from('import "./gpu-probe.mjs";\n' + body);
      if (name === "/gpu-agent.mjs") body = Buffer.from(body.toString().replace("execute(wire, words[2] >>> 0, words[3] >>> 0);", "globalThis.raydeBatch(wire, words[2] >>> 0, words[3] >>> 0); execute(wire, words[2] >>> 0, words[3] >>> 0);"));
      if (name === "/ashui-host.mjs" && args.includes("--agents")) body = Buffer.from(body.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)", String(Number(option("--agents", "3")))));
      if (name === "/rayde_session.mjs" && args.includes("--trace")) body = Buffer.from('console.log("session agent", location.search);\n' + body);
      response.writeHead(200, { "Content-Type": /\.wasm$/.test(name) ? "application/wasm" : /\.(m?js)$/.test(name) ? "text/javascript" : "text/html", "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp" });
      response.end(body);
    } catch { response.writeHead(404).end(); }
  }).listen(port, "127.0.0.1");
} else server = spawn("ash", ["serve", "--port", String(port), dir], { stdio: "ignore" });
await sleep(1500);
const browser = await puppeteer.launch({ executablePath: chrome, headless: "new", args: ["--no-sandbox", "--enable-unsafe-webgpu", "--window-size=1280,900"], defaultViewport: { width: 1280, height: 800 } });
const result = { ok: false };
try {
  const page = await browser.newPage();
  if (visitor) await page.evaluateOnNewDocument(value => {
    Object.defineProperty(navigator, "userAgentData", { value: { platform: value === "Mac" ? "macOS" : value } });
  }, visitor);
  if (probe) await page.evaluateOnNewDocument(() => {
    const marks = [], OriginalWorker = Worker;
    globalThis.raydeProbe = { marks, gpu: null, memory: null };
    globalThis.Worker = class extends OriginalWorker {
      constructor(...args) {
        super(...args);
        marks.push({ kind: "worker", url: String(args[0]), at: performance.now() });
        this.addEventListener("message", ({ data }) => {
          if (data.memory instanceof WebAssembly.Memory) globalThis.raydeProbe.memory = data.memory;
          if (data.kind === "rayde-gpu-probe") globalThis.raydeProbe.gpu = data.stats;
          if (data.text === "ashui: ready" || data.kind === "spawn-agent") marks.push({ kind: data.kind, name: data.name, text: data.text, at: performance.now() });
        });
      }
    };
  });
  const lines = [];
  result.console = lines;
  const log = line => { lines.push(line); if (args.includes("--trace")) writeFileSync(join(shots, "console.log"), lines.join("\n")); };
  page.on("console", (m) => log(m.text()));
  page.on("pageerror", (e) => log("PAGE ERROR " + e.message));
  if (args.includes("--trace")) {
    const debug = await page.createCDPSession(); await debug.send("Network.enable");
    const trace = [];
    for (const event of ["Network.webSocketFrameSent", "Network.webSocketFrameReceived"]) debug.on(event, value => {
      let message; try { message = JSON.parse(value.response.payloadData); } catch { return; }
      delete message.token;
      trace.push({event, message}); writeFileSync(join(shots, "session.json"), JSON.stringify(trace, null, 2));
    });
  }
  if (scheme) await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme }]);
  const started = Date.now();
  const query = new URLSearchParams(envs.map(e => ["env", e]));
  if (session) { query.set("session", `ws://127.0.0.1:${sessionPort}/session`); query.set("project", "build.hxml"); }
  await page.goto(`http://127.0.0.1:${port}/index.html?${query}${session ? "#token=page-test" : ""}`);
  await page.waitForFunction(() => /RayDE/.test(document.title), { timeout: 120000 });
  const titled = Date.now() - started;
  for (let i = 0; i < 400 && !lines.some((l) => /ashui: ready|RayDE stopped:|uncaught exception/.test(l)); i++) await sleep(100);
  const ready = Date.now() - started;
  if (!lines.some(l => l === "ashui: ready")) throw new Error("window did not become ready:\n" + lines.join("\n"));
  await sleep(Number(option("--settle", "2")) * 1000);
  await page.screenshot({ path: join(shots, "initial.png") });
  if (probe) result.initial = await page.evaluate(() => ({ marks:raydeProbe.marks, url:location.href }));
  if (args.includes("--extension-proof")) {
    const proof = join(resolve(workspace), "extension-proof.txt");
    for (let i = 0; i < 200; i++) {
      try { if (readFileSync(proof, "utf8") === "remote extension answered\nlarge file: \n" + "🙂漢字".repeat(9000)) { result.extension = true; break; } } catch {}
      await sleep(100);
    }
    if (!result.extension) throw new Error("the remote extension did not answer its workspace service call:\n" + lines.join("\n"));
  }
  result.title = await page.title();
  result.visitor = await page.evaluate(() => new URLSearchParams(location.search).getAll("env").find(e => e.startsWith("RAYDE_VISITOR=")));
  if (visitor && result.visitor !== "RAYDE_VISITOR=" + visitor) throw new Error("shortcuts do not follow the browser platform");
  result.readyMs = ready;
  result.titledMs = titled;
  result.afterReady = memory(browser.process().pid);
  async function sample(label) {
    if (!probe) return;
    result[label] = await page.evaluate(() => ({ marks: raydeProbe.marks, timeOrigin: performance.timeOrigin, wasmBytes: raydeProbe.memory?.buffer.byteLength, gpu: raydeProbe.gpu, jsHeap: performance.memory?.usedJSHeapSize }));
  }
  await sample("readyProbe");
  if (session && probe) {
    await sleep(1500); await sample("idleProbe");
    result.idleSubmissions = result.idleProbe.gpu.submissions - result.readyProbe.gpu.submissions;
    if (result.idleSubmissions > 2) throw new Error("idle session work kept rendering GPU frames: " + result.idleSubmissions);
  }
  await page.screenshot({ path: join(shots, "welcome.png") });
  if (args.includes("--timeline")) for (const t of [3, 6, 10]) { await sleep(t * 1000 - (t > 3 ? (t === 6 ? 3000 : 6000) : 0)); await page.screenshot({ path: join(shots, `t${t}.png`) }); }

  // The scheme changes while the page runs: the app follows.
  if (flip) {
    await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme === "light" ? "dark" : "light" }]);
    await sleep(Number(option("--settle", "2")) * 1000);
    await page.screenshot({ path: join(shots, "flipped.png") });
  }

  // Open Main.hx from the Explorer, then type into it.
  if (session) await page.mouse.click(480, 412);
  else await page.mouse.click(147, 165);
  for (const t of [1, 3, 6]) {
    await sleep(t === 1 ? 1000 : t === 3 ? 2000 : 3000);
    await page.screenshot({ path: join(shots, `open-${t}s.png`) });
    result[`title after ${t}s`] = await page.title();
  }
  await page.screenshot({ path: join(shots, "open.png") });
  await sample("openProbe");
  const capture = await page.screenshot();
  const varied = await page.evaluate(async base64 => {
    const image = new Image(); image.src = "data:image/png;base64," + base64; await image.decode();
    const canvas = document.createElement("canvas"); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext("2d", { willReadFrequently: true }); context.drawImage(image, 0, 0);
    const pixels = context.getImageData(330, 80, 900, 650).data;
    const colors = new Set();
    for (let i = 0; i < pixels.length; i += 16) colors.add((pixels[i] >> 4) * 256 + (pixels[i + 1] >> 4) * 16 + (pixels[i + 2] >> 4));
    return colors.size;
  }, Buffer.from(capture).toString("base64"));
  if (varied < 8) throw new Error("opening Main.hx left a blank canvas");
  await page.mouse.click(700, 300);
  await sleep(300);
  await page.keyboard.type("// typed in a page", { delay: 15 });
  await sleep(1000);
  await page.screenshot({ path: join(shots, "typed.png") });
  if (session) {
    const modifier = result.visitor === "RAYDE_VISITOR=Mac" ? "Meta" : "Control";
    await page.keyboard.down(modifier); await page.keyboard.press("S"); await page.keyboard.up(modifier);
    for (let i = 0; i < 100; i++) {
      if (readFileSync(join(resolve(workspace), "src/Main.hx"), "utf8").includes("// typed in a page")) { result.saved = true; break; }
      await sleep(100);
    }
    if (!result.saved) throw new Error("the editor's save did not reach the session file");
  }
  result.afterEdit = memory(browser.process().pid);
  await sample("editProbe");
  if (probe && (!result.editProbe.gpu?.completed || !result.editProbe.gpu.batches || result.editProbe.gpu.crossBatchSubmits)) throw new Error("GPU frames did not complete in one batch");
  if (args.includes("--shortcuts")) {
    const before = await page.screenshot();
    const modifier = result.visitor === "RAYDE_VISITOR=Mac" ? "Meta" : "Control";
    await page.keyboard.down(modifier); await page.keyboard.down("Shift"); await page.keyboard.press("P");
    await page.keyboard.up("Shift"); await page.keyboard.up(modifier);
    await sleep(3000);
    const after = await page.screenshot({ path: join(shots, "commands.png") });
    result.shortcutPixelsChanged = await page.evaluate(async sources => {
      const images = await Promise.all(sources.map(async source => {
        const image = new Image(); image.src = "data:image/png;base64," + source; await image.decode(); return image;
      }));
      const canvas = document.createElement("canvas"); canvas.width = 1280; canvas.height = 800;
      const context = canvas.getContext("2d", { willReadFrequently: true });
      const pixels = images.map(image => { context.drawImage(image, 0, 0); return context.getImageData(400, 80, 400, 240).data; });
      let changed = 0;
      for (let i = 0; i < pixels[0].length; i += 16) if (Math.abs(pixels[0][i] - pixels[1][i]) + Math.abs(pixels[0][i + 1] - pixels[1][i + 1]) + Math.abs(pixels[0][i + 2] - pixels[1][i + 2]) > 32) changed++;
      return changed;
    }, [before, after].map(bytes => Buffer.from(bytes).toString("base64")));
    if (result.shortcutPixelsChanged < 500) throw new Error("the browser platform's command shortcut did not open the command center");
    await page.keyboard.press("Escape");
  }
  if (lines.some(l => /gpu error|device was lost|uncaught exception|RayDE stopped:|PAGE ERROR/.test(l))) throw new Error("page reported a runtime or GPU error:\n" + lines.join("\n"));
  result.console = args.includes("--all") ? lines : lines.filter((l) => !/^thread |agent entering|^\[ash\] loaded/.test(l)).slice(-12);
  result.ok = true;
} finally {
  if (probe) writeFileSync(join(shots, "probe.json"), JSON.stringify(result, null, 2));
  await browser.close();
  if (probe) server.close(); else server.kill();
  session?.kill();
}
const fmt = (m) => `renderer ${mb(m.renderer)}, gpu ${mb(m.gpu)}, other ${mb(m.other)}, total ${mb(m.renderer + m.gpu + m.other)}`;
console.log(`title: ${result.title}`);
for (const key of Object.keys(result)) if (key.startsWith("title after")) console.log(`${key}: ${result[key]}`);
console.log(`window title at ${result.titledMs} ms, ashui ready at ${result.readyMs} ms (local server, no compression)`);
console.log(`memory after ready: ${fmt(result.afterReady)}`);
console.log(`memory after opening a file and typing: ${fmt(result.afterEdit)}`);
console.log("last console lines:\n  " + result.console.join("\n  "));
process.exit(result.ok ? 0 : 1);
