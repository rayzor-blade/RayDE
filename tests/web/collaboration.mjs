// Two full WASM editors, isolated browser storage, one Rust workspace session.
// node tests/web/collaboration.mjs bin/web/crdt-editor
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {createServer} from "node:http";
import {createServer as tcpServer} from "node:net";
import {createRequire} from "node:module";
import {resolve, join} from "node:path";

const root = resolve(import.meta.dirname,"../.."), dir = resolve(process.argv[2] ?? "bin/web/crdt-editor");
const require = createRequire(join(root,"web/session/package.json")), puppeteer = require("puppeteer-core");
const shots = join(root,"bin/web/crdt-shots"); mkdirSync(shots,{recursive:true});
const workspace = mkdtempSync(join(tmpdir(),"rayde-crdt-")); mkdirSync(join(workspace,"src"));
const source = 'class Main {\n\tstatic function main() {\n\t\ttrace("hello");\n\t}\n}\n';
writeFileSync(join(workspace,"src/Main.hx"),source);
writeFileSync(join(workspace,"src/Other.hx"),"class Other {}\n");
writeFileSync(join(workspace,"build.hxml"),"-cp src\n-main Main\n--interp\n");
const sleep = ms => new Promise(r => setTimeout(r,ms));
const freePort = () => new Promise(r => { const s = tcpServer().listen(0,"127.0.0.1",() => { const port = s.address().port; s.close(() => r(port)); }); });
async function until(check, label, limit = 60000) {
  const end = Date.now() + limit;
  while (!await check()) { if (Date.now() > end) throw new Error("Timed out: " + label); await sleep(50); }
}
const webPort = await freePort(), sessionPort = await freePort();
const server = createServer((request,response) => {
  try {
    const name = new URL(request.url,"http://local").pathname;
    const path = resolve(dir,"." + (name === "/" ? "/index.html" : name));
    if (!path.startsWith(dir + "/")) throw new Error("outside");
    let body = readFileSync(path);
    if (name === "/ashui-host.mjs") body = Buffer.from(body.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)","3"));
    if (name === "/rayde_session.mjs") body = Buffer.from(body.toString()
      .replace("const answer = (message) => {", 'const answer = (message) => { if (message.ok === false || message.ev?.startsWith("view.") || typeof message.result?.text === "string") console.log("projection:" + JSON.stringify(message));')
      .replace("const request = JSON.parse(text2);", 'const request = JSON.parse(text2); if (request.op?.startsWith("view.")) console.log("editor-request:" + JSON.stringify(request));')
      .replace("reply = { result: await documents.request(request.op, request) };", 'if (request.op === "view.save") await new Promise(resolve => setTimeout(resolve,1000)); reply = { result: await documents.request(request.op, request) }; if (request.op === "view.save") console.log("saved:" + request.handle);'));
    response.writeHead(200,{"Content-Type":path.endsWith(".wasm") ? "application/wasm" : /\.m?js$/.test(path) ? "text/javascript" : "text/html", "Cross-Origin-Opener-Policy":"same-origin", "Cross-Origin-Embedder-Policy":"require-corp"});
    response.end(body);
  } catch { response.writeHead(404).end(); }
}).listen(webPort,"127.0.0.1");
const run = () => spawn(join(root,"native/session/target/debug/rayde-session"),["--root",workspace,"--port",String(sessionPort),"--token","collaboration-test","--origin",`http://127.0.0.1:${webPort}`],{stdio:"ignore"});
let session = run(), browser;
const logs = {a:[],b:[]};
const report = {ok:false,workspace};
try {
  browser = await puppeteer.launch({executablePath:process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless:true,
    args:["--no-sandbox","--enable-unsafe-webgpu"], defaultViewport:{width:1280,height:800}});
  const endpoint = `ws://127.0.0.1:${sessionPort}/session`;
  const url = `http://127.0.0.1:${webPort}/?session=${encodeURIComponent(endpoint)}&project=build.hxml&env=RAYDE_VISITOR=Linux#token=collaboration-test`;
  const projection = who => logs[who].filter(line => line.startsWith("projection:")).map(line => JSON.parse(line.slice(11)));
  const requests = who => logs[who].filter(line => line.startsWith("editor-request:")).map(line => JSON.parse(line.slice(15)));
  const file = () => readFileSync(join(workspace,"src/Main.hx"),"utf8");
  async function open(who) {
    const context = await browser.createBrowserContext(), page = await context.newPage();
    await page.evaluateOnNewDocument(() => Object.defineProperty(navigator,"userAgentData",{value:{platform:"Linux"}}));
    page.on("console",message => { logs[who].push(message.text()); writeFileSync(join(shots,who + ".log"),logs[who].join("\n")); });
    page.on("pageerror",error => logs[who].push("PAGE ERROR " + error.stack));
    await page.goto(url,{waitUntil:"domcontentloaded"});
    await until(() => logs[who].includes("ashui: ready"),who + " ready");
    await sleep(800); await page.screenshot({path:join(shots,who + "-welcome.png")});
    await page.keyboard.down("Control"); await page.keyboard.press("p"); await page.keyboard.up("Control");
    await sleep(500); await page.keyboard.type("Main.hx",{delay:20}); await sleep(300); await page.keyboard.press("Enter");
    await until(() => requests(who).some(r => r.op === "view.ready"),who + " document binding");
    await page.screenshot({path:join(shots,who + "-open.png")});
    return page;
  }
  const a = await open("a"), b = await open("b");
  const aHandle = requests("a").find(r => r.op === "view.open").handle;
  async function append(page,text) {
    await page.bringToFront(); await page.mouse.click(700,300);
    await page.keyboard.down("Control"); await page.keyboard.press("End"); await page.keyboard.up("Control");
    await page.keyboard.type(text,{delay:10});
  }
  await append(a,"// from A\n");
  await until(() => file().includes("// from A"),"A edits reach the server");
  await until(() => projection("b").some(p => p.ev === "view.remote" && p.text.includes("// from A")),"B receives A's edit");
  await append(b,"// from B\n");
  await until(() => file().includes("// from B"),"B edits reach the server");
  await until(() => projection("a").some(p => p.ev === "view.remote" && p.text.includes("// from B")),"A receives B's edit");
  await a.bringToFront(); await a.mouse.click(700,300);
  await a.keyboard.down("Control"); await a.keyboard.press("z"); await a.keyboard.up("Control");
  await until(() => requests("a").some(r => r.op === "view.undo"),"A uses shared undo");
  await sleep(400);
  assert.ok(file().includes("// from B"),"A's undo must preserve B's changes");
  report.authorUndo = true;
  await a.keyboard.down("Control"); await a.keyboard.press("s"); await a.keyboard.up("Control");
  await until(() => requests("a").some(r => r.op === "view.save"),"Save uses a CRDT barrier");
  const interruptedSave = requests("a").find(r => r.op === "view.save");
  // Stop only the compute session: both editors retain live local documents.
  await new Promise(r => { session.once("exit",r); session.kill("SIGTERM"); });
  await sleep(800);
  await append(a,"// offline A\n");
  await a.screenshot({path:join(shots,"a-offline.png")});
  await until(() => projection("a").some(p => p.id === interruptedSave.id && p.ok === false),"interrupted Save reports an error without stopping the editor");
  report.saveFailure = true;
  await sleep(500);
  session = run();
  await until(() => file().includes("// offline A"),"offline edits merge after reconnect");
  await until(() => projection("b").some(p => p.ev === "view.remote" && p.text.includes("// offline A")),"reconnected B receives offline edits");
  report.reconnect = true;
  await a.screenshot({path:join(shots,"a-merged.png")}); await b.screenshot({path:join(shots,"b-merged.png")});
  const before = file(), from = logs.a.length;
  await a.reload({waitUntil:"domcontentloaded"});
  await until(() => logs.a.slice(from).includes("ashui: ready"),"reloaded editor ready");
  await until(() => logs.a.slice(from).some(line => line.startsWith("editor-request:") && JSON.parse(line.slice(15)).op === "view.ready"),"document and tabs restored after reload");
  assert.equal(file(),before,"reload must not duplicate persisted CRDT text");
  const restored = requests("a").findLast(r => r.op === "view.open");
  assert.notEqual(restored.handle,aHandle,"reload must allocate a fresh binding");
  async function quickOpen(page,name) {
    await page.bringToFront(); await page.keyboard.down("Control"); await page.keyboard.press("p"); await page.keyboard.up("Control");
    await sleep(350); await page.keyboard.type(name,{delay:20}); await sleep(250); await page.keyboard.press("Enter");
  }
  await quickOpen(a,"Other.hx");
  await until(() => requests("a").some(r => r.op === "view.open" && r.path === "src/Other.hx"),"second tab opens");
  await quickOpen(a,"Main.hx"); await sleep(400);
  assert.equal(requests("a").filter(r => r.op === "view.open" && r.path === "src/Main.hx").length,2,"switching tabs must reuse the persistent binding");
  await a.keyboard.down("Control"); await a.keyboard.press("w"); await a.keyboard.up("Control");
  await until(() => requests("a").some(r => r.op === "view.close" && r.handle === restored.handle),"closing a saved tab releases its binding");
  await quickOpen(a,"Main.hx");
  await until(() => requests("a").filter(r => r.op === "view.open" && r.path === "src/Main.hx").length === 3,"closed tab reopens with a new binding");
  await until(() => projection("a").some(p => p.result?.text === before && p.id === requests("a").findLast(r => r.op === "view.open").id),"reopened document retains its text");
  assert.equal(projection("a").filter(p => p.ev === "view.error").length,0);
  assert.equal(projection("b").filter(p => p.ev === "view.error").length,0);
  assert.equal(logs.a.concat(logs.b).some(line => /PAGE ERROR|uncaught exception|RayDE stopped:/.test(line)),false);
  report.reload = report.tabLifecycle = report.ok = true;
} finally {
  writeFileSync(join(shots,"result.json"),JSON.stringify(report,null,2));
  for (const who of ["a","b"]) writeFileSync(join(shots,who + ".log"),logs[who].join("\n"));
  await browser?.close(); session?.kill("SIGTERM"); server.close();
}
console.log(JSON.stringify(report,null,2));
