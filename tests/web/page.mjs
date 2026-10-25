// Opens RayDE's page build (scripts/build-web.sh) in Chrome, drives it, and prints what it measured.
//
//   node tests/web/page.mjs [--dir bin/web/rayde] [--shots bin/web/shots]
//
// Needs Google Chrome (WebGPU, wasm exception handling) and puppeteer-core (web/session's node_modules).
import { spawn, execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
if (args.includes("--reload") && !probe) throw new Error("--reload needs --probe");
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
      if (name === "/storage-probe.html") { response.writeHead(200, {"Content-Type":"text/html"}); response.end("<!doctype html><title>Storage probe</title>"); return; }
      const file = resolve(dir, "." + (name === "/" ? "/index.html" : name));
      if (!file.startsWith(dir + "/")) throw new Error("outside output");
      let body = ["/gpu-probe.mjs", "/queue-probe.mjs"].includes(name) ? readFileSync(join(here, name.slice(1))) : readFileSync(file);
      if (name === "/xwindow.mjs" && args.includes("--settings")) body = Buffer.from('import { watchQueue } from "./queue-probe.mjs";\n' + body.toString()
        .replace("const queue = new Queue(memory, address + QUEUE);", "const queue = new Queue(memory, address + QUEUE); const traceQueue = watchQueue(memory, address + QUEUE);")
        .replace("const posted = post_XwEvent(queue, event);", "const posted = post_XwEvent(queue, event); traceQueue(event, posted);"));
      if (name === "/xwindow.mjs" && args.includes("--text-input")) body = Buffer.from(body.toString().replace("const posted = post_XwEvent(queue, event);", 'if (event.kind === "keyboard-input" || event.kind.startsWith("ime-")) console.log("browser-input:" + JSON.stringify(event)); const posted = post_XwEvent(queue, event);'));
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
  if (args.includes("--ime-fallback")) await page.evaluateOnNewDocument(() => { delete globalThis.EditContext; });
  if (args.includes("--shortcuts")) await page.evaluateOnNewDocument(() => {
    globalThis.raydeKeys = [];
    addEventListener("keydown", event => raydeKeys.push({key:event.key, ctrl:event.ctrlKey, meta:event.metaKey, prevented:event.defaultPrevented}));
  });
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
  if (!session && !args.includes("--no-demo")) query.set("demo","1");
  if (session) { query.set("session", `ws://127.0.0.1:${sessionPort}/session`); query.set("project", "build.hxml"); }
  async function pageFiles(put = [], remove = []) {
    return page.evaluate(({put, remove}) => new Promise((resolve, reject) => {
      const open = indexedDB.open("rayde-page", 1);
      open.onupgradeneeded = () => open.result.createObjectStore("files", {keyPath:"path"});
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const db = open.result, transaction = db.transaction("files", put.length || remove.length ? "readwrite" : "readonly"), store = transaction.objectStore("files");
        for (const entry of put) store.put(entry);
        for (const path of remove) store.delete(path);
        const request = store.getAll();
        transaction.oncomplete = () => { resolve(request.result); db.close(); };
        transaction.onerror = () => { reject(transaction.error); db.close(); };
      };
    }), {put, remove});
  }
  const savedMain = 'class Main {\n\tstatic function main() { trace("kept edit λ"); }\n}\n';
  if (args.includes("--reload")) {
    if (session) throw new Error("--reload checks the browser's local sample");
    await page.goto(`http://127.0.0.1:${port}/storage-probe.html`);
    await pageFiles([
      {path:"/work/.rayde/settings.json", directory:false, data:Buffer.from("{}").toString("base64")},
      {path:"/work/src/Main.hx", directory:false, data:Buffer.from(savedMain).toString("base64")},
      {path:"/work/src/notes.txt", directory:false, data:Buffer.from("keep this file").toString("base64")},
    ]);
  }
  await page.goto(`http://127.0.0.1:${port}/index.html?${query}${session ? "#token=page-test" : ""}`);
  let titled = 0;
  for (let i = 0; i < 1200 && !lines.some((l) => /ashui: ready|RayDE stopped:|uncaught exception/.test(l)); i++) {
    if (!titled && /RayDE/.test(await page.title())) titled = Date.now() - started;
    await sleep(100);
  }
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
  result.titledMs = titled || ready;
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
  if (args.includes("--explorer")) {
    if (!session) throw new Error("--explorer requires an isolated --session-root fixture");
    const from = join(resolve(workspace),"src/drag.txt"), into = join(resolve(workspace),"dest/drag.txt");
    if (!existsSync(from) || readFileSync(from,"utf8") !== "remote drag fixture\n") throw new Error("missing isolated drag fixture");
    await page.mouse.move(155,240); await page.mouse.down(); await page.mouse.move(155,165,{steps:12}); await sleep(350);
    await page.screenshot({path:join(shots,"dragging.png")}); await page.mouse.up();
    for (let i=0;i<100 && !existsSync(into);i++) await sleep(100);
    if (existsSync(from) || !existsSync(into) || readFileSync(into,"utf8") !== "remote drag fixture\n") throw new Error("Explorer drag did not move the remote file");
    result.remoteDrag = true;
    result.afterEdit = memory(browser.process().pid);
  }
  if (args.includes("--reload")) {
    const assertSaved = async missing => {
      const files = await pageFiles(), main = files.find(file => file.path === "/work/src/Main.hx");
      if (missing ? main != null || files.some(file => file.path === "/work/build.hxml") : !main || Buffer.from(main.data, "base64").toString() !== savedMain || !files.some(file => file.path === "/work/build.hxml")) throw new Error("sample files were lost, overwritten or recreated");
      if (!files.some(file => file.path === "/work" && file.directory) || !files.some(file => file.path === "/work/src/notes.txt" && Buffer.from(file.data, "base64").toString() === "keep this file")) throw new Error("sample bootstrap or custom file was not preserved");
    };
    const reloadReady = async label => {
      const from = lines.length;
      await page.reload({waitUntil:"domcontentloaded"});
      for (let i = 0; i < 1000 && !lines.slice(from).some(line => /ashui: ready|RayDE stopped:|uncaught exception/.test(line)); i++) await sleep(100);
      if (!lines.slice(from).includes("ashui: ready")) throw new Error("reload failed: " + lines.slice(from).join("\n"));
      await sleep(500); await page.screenshot({path:join(shots, label + ".png")});
    };
    await assertSaved(false);
    await reloadReady("restored"); await assertSaved(false);
    await pageFiles([], ["/work/src/Main.hx", "/work/build.hxml"]);
    await reloadReady("folder-fallback"); await assertSaved(true);
    result.reload = {migration:true, preservedEdits:true, deletedFilesStayDeleted:true, folderFallback:true};
    result.afterEdit = memory(browser.process().pid);
  }
  if (args.includes("--text-input")) {
    await page.mouse.click(140, session ? 165 : 140, {button:"right"}); await sleep(500);
    await page.screenshot({path:join(shots, "new-file-menu.png")});
    await page.mouse.click(220, session ? 185 : 160); await sleep(500);
    await page.screenshot({path:join(shots, "new-file-empty.png")});
    await page.keyboard.type("Hello.hxs", {delay:Number(option("--input-delay", "15"))}); await sleep(500);
    await page.screenshot({path:join(shots, "new-file-typed.png")});
    await page.keyboard.press("Enter"); await sleep(1000);
    const paths = await page.evaluate(() => new Promise((resolve, reject) => {
      const open = indexedDB.open("rayde-page", 1);
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const db = open.result, request = db.transaction("files").objectStore("files").getAll();
        request.onsuccess = () => { resolve(request.result.map(entry => entry.path)); db.close(); };
      };
    }));
    result.inputPaths = paths;
    if (!paths.includes("/work/src/Hello.hxs")) throw new Error("typed filename changed: " + paths.join(", "));
    if (args.includes("--input-only")) { result.ok = true; result.afterEdit = result.afterReady; }
  }
  if (args.includes("--settings")) {
    const waitSettings = async (id, from) => {
      for (let i = 0; i < 1000; i++) {
        const entry = lines.slice(from).find(line => line.startsWith("settings-ready:") && JSON.parse(line.slice(15)).id === id);
        if (entry) return JSON.parse(entry.slice(15));
        await sleep(10);
      }
      throw new Error("settings did not finish rendering: " + id + "\n" + lines.join("\n"));
    };
    await page.mouse.click(33, 742); await waitSettings("build", 0);
    await page.screenshot({ path: join(shots, "settings-initial.png") });
    const timings = [], positions = {build:142, run:180, libraries:218, terminal:256, appearance:294, keys:332, extensions:370};
    for (const name of ["keys", "appearance", "extensions", "build", "keys", "terminal", "keys", "libraries", "build"]) {
      const started = performance.now(), from = lines.length; await page.mouse.click(410, positions[name]);
      const ready = await waitSettings(name, from);
      await page.screenshot({ path: join(shots, `settings-${timings.length}-${name}.png`) });
      timings.push({...ready, observedMs:performance.now() - started});
      if (args.includes("--virtualized") && (ready.keyRows > 18 || ready.libraryRows > 15)) throw new Error("settings rows were not virtualized");
    }
    const from = lines.length, started = performance.now();
    for (const name of ["keys", "build", "terminal", "extensions", "keys", "appearance"]) {
      await page.mouse.click(410, positions[name]); await sleep(15);
    }
    result.settingsBurst = {...await waitSettings("appearance", from), observedMs:performance.now() - started};
    await page.screenshot({path:join(shots, "settings-burst.png")});
    result.settings = timings;
    result.queue = await page.evaluate(() => globalThis.raydeQueueProbe);
    await sample("settingsProbe");
    writeFileSync(join(shots, "settings.json"), JSON.stringify(timings, null, 2));
    if (args.includes("--settings-only")) { result.ok = true; result.afterEdit = result.afterReady; }
  }
  if (args.includes("--timeline")) for (const t of [3, 6, 10]) { await sleep(t * 1000 - (t > 3 ? (t === 6 ? 3000 : 6000) : 0)); await page.screenshot({ path: join(shots, `t${t}.png`) }); }

  // The scheme changes while the page runs: the app follows.
  if (flip) {
    await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme === "light" ? "dark" : "light" }]);
    await sleep(Number(option("--settle", "2")) * 1000);
    await page.screenshot({ path: join(shots, "flipped.png") });
  }

  if (!args.includes("--settings-only") && !args.includes("--input-only") && !args.includes("--reload-only") && !args.includes("--explorer-only")) {
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
    for (const key of ["s", "p", "f"]) {
      const modifier = result.visitor === "RAYDE_VISITOR=Mac" ? "Meta" : "Control";
      await page.keyboard.down(modifier); await page.keyboard.press(key); await page.keyboard.up(modifier);
      await sleep(400);
      const event = await page.evaluate(key => raydeKeys.findLast(event => event.key.toLowerCase() === key), key);
      if (!event?.prevented) throw new Error("browser default was not prevented for " + modifier + "+" + key);
      await page.keyboard.press("Escape"); await sleep(200);
    }
    const before = await page.screenshot();
    const modifier = result.visitor === "RAYDE_VISITOR=Mac" ? "Meta" : "Control";
    await page.keyboard.down(modifier); await page.keyboard.down("Shift"); await page.keyboard.press("P");
    await page.keyboard.up("Shift"); await page.keyboard.up(modifier);
    await sleep(3000);
    result.shortcutEvents = await page.evaluate(() => raydeKeys.filter(event => event.ctrl || event.meta));
    const commandEvent = result.shortcutEvents.findLast(event => event.key.toLowerCase() === "p");
    if (!commandEvent?.prevented) throw new Error("the command shortcut also reached the browser default");
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
