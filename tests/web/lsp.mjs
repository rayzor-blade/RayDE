// Full WASM editor, built-in Rayzor extension, and an LSP process on the workspace host.
// node tests/web/lsp.mjs bin/web/remote-lsp
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync} from "node:fs";
import {tmpdir} from "node:os";
import {createServer} from "node:http";
import {createServer as tcpServer} from "node:net";
import {createRequire} from "node:module";
import {resolve, join, dirname} from "node:path";

const root = resolve(import.meta.dirname,"../.."), dir = resolve(process.argv[2] ?? "bin/web/remote-lsp");
const require = createRequire(join(root,"web/session/package.json")), puppeteer = require("puppeteer-core");
const {WebSocketServer,WebSocket} = require("ws");
const rayzor = resolve(process.env.RAYDE_RAYZOR_LSP ?? join(root,"../rayzor/target/release/rayzor"));
const stdlib = resolve(process.env.RAYZOR_STD_PATH ?? join(root,"../rayzor/compiler/haxe-std"));
if (!existsSync(rayzor)) throw new Error("Build Rayzor first or set RAYDE_RAYZOR_LSP.");
const shots = join(root,"bin/web/lsp-shots"); mkdirSync(shots,{recursive:true});
const workspace = mkdtempSync(join(tmpdir(),"rayde-lsp-"));
mkdirSync(join(workspace,"src")); mkdirSync(join(workspace,".rayde"));
const source = '/** A browser session demo. */\nclass Main {\n\t/** Adds two integers. */\n\tstatic function add(a:Int, b:Int):Int {\n\t\treturn a + b;\n\t}\n\tstatic function main() {\n\t\tvar result = add(1, 2);\n\t\ttrace(result);\n\t}\n}\n';
writeFileSync(join(workspace,"src/Main.hx"),source);
writeFileSync(join(workspace,"build.hxml"),"-cp src\n-main Main\n--interp\n");
writeFileSync(join(workspace,".rayde/settings.json"),JSON.stringify({"extension.rayzor":{stdlib},extensions:{disabled:["git","markdown"]}}));
const sleep = ms => new Promise(r => setTimeout(r,ms));
const freePort = () => new Promise(r => { const server = tcpServer().listen(0,"127.0.0.1",() => { const port = server.address().port; server.close(() => r(port)); }); });
async function until(check,label,limit = 60000) {
  const end = Date.now()+limit;
  while (!await check()) {
    const failure = logs.find(line => /lsp-failure:|RayDE stopped:|uncaught exception/.test(line)); if (failure) throw new Error(failure);
    if (Date.now() > end) throw new Error("Timed out: "+label); await sleep(50);
  }
}
const webPort = await freePort(), sessionPort = await freePort(), proxyPort = await freePort(), logs = [], requests = [], replies = [], messages = [], streams = new Map();
const report = {ok:false,workspace};
function stdout(pid,base64) {
  let bytes = Buffer.concat([streams.get(pid) ?? Buffer.alloc(0),Buffer.from(base64,"base64")]);
  for (;;) {
    const end = bytes.indexOf("\r\n\r\n"); if (end < 0) break;
    const length = Number(bytes.subarray(0,end).toString().match(/content-length:\s*(\d+)/i)?.[1]);
    if (!length || bytes.length < end+4+length) break;
    try { messages.push({pid,body:JSON.parse(bytes.subarray(end+4,end+4+length).toString())}); } catch {}
    bytes = bytes.subarray(end+4+length);
  }
  if (bytes.length > 20*1024*1024) throw new Error("Test stream exceeded its limit.");
  streams.set(pid,bytes);
}
const server = createServer((request,response) => {
  try {
    const name = new URL(request.url,"http://local").pathname, path = resolve(dir,"."+(name === "/" ? "/index.html" : name));
    if (!path.startsWith(dir+"/")) throw new Error("outside");
    let body = readFileSync(path);
    if (name === "/ashui-host.mjs") body = Buffer.from(body.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)","3"));
    if (name === "/ash_browser.js") body = Buffer.from(body.toString().replace("const ret = new WebSocket(getStringFromWasm0(arg0, arg1));",'const address = getStringFromWasm0(arg0, arg1); console.log("native-socket:"+address); const ret = new WebSocket(address);'));
    if (name === "/rayde_session.mjs") body = Buffer.from(body.toString()
      .replace("const socket = new WebSocket(this.options.url);", 'console.log("session-socket:"+JSON.stringify({attempt:this.attempt,time:performance.now()})); const socket = new WebSocket(this.options.url);')
      .replace("socket.onclose = () => {", 'socket.onclose = (event) => { console.log("session-closed:"+JSON.stringify({code:event.code,time:performance.now()}));')
      .replace("const answer = (message) => {", 'const answer = (message) => { if (message.ev === "proc.out" || message.ok && message.pid != null || message.result?.kind === "document") console.log("process-reply:"+JSON.stringify(message));')
      .replace("const request = JSON.parse(text2);", 'const request = JSON.parse(text2); if (request.op === "proc.spawn" || request.op === "proc.kill" || request.op === "proc.write" || request.op === "page.markdown") console.log("process-request:"+JSON.stringify(request));'));
    response.writeHead(200,{"Content-Type":path.endsWith(".wasm") ? "application/wasm" : /\.m?js$/.test(path) ? "text/javascript" : "text/html","Cross-Origin-Opener-Policy":"same-origin","Cross-Origin-Embedder-Policy":"require-corp"}); response.end(body);
  } catch { response.writeHead(404).end(); }
}).listen(webPort,"127.0.0.1");
const session = spawn(join(root,"native/session/target/debug/rayde-session"),["--root",workspace,"--port",String(sessionPort),"--token","lsp-test","--origin",`http://127.0.0.1:${webPort}`,"--exec","--extension-host",join(root,"bin/rayde-extension-host"),"--extensions",join(root,"extensions")],{
  stdio:"ignore",env:{...process.env,PATH:dirname(rayzor)+":"+process.env.PATH,RAYZOR_STD_PATH:stdlib}
});
const peers = new Set();
let available = true;
function proxy() {
  const relay = new WebSocketServer({host:"127.0.0.1",port:proxyPort});
  relay.on("connection",page => {
    if (!available) { page.close(1013,"Workspace unavailable"); return; }
    const remote = new WebSocket(`ws://127.0.0.1:${sessionPort}/session`,{headers:{Origin:`http://127.0.0.1:${webPort}`}}), pending = [];
    peers.add(page); peers.add(remote);
    page.on("message",bytes => remote.readyState === WebSocket.OPEN ? remote.send(bytes.toString()) : pending.push(bytes));
    remote.on("open",() => pending.splice(0).forEach(bytes => remote.send(bytes.toString())));
    remote.on("message",bytes => { if (page.readyState === WebSocket.OPEN) page.send(bytes.toString()); });
    page.on("close",() => { peers.delete(page); remote.terminate(); });
    remote.on("close",() => { peers.delete(remote); page.terminate(); });
    remote.on("error",() => page.terminate()); page.on("error",() => remote.terminate());
  });
  return relay;
}
let relay = proxy();
let browser;
try {
  browser = await puppeteer.launch({executablePath:process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",headless:true,args:["--no-sandbox","--enable-unsafe-webgpu"],defaultViewport:{width:1280,height:800}});
  const page = await browser.newPage();
  const network = await page.createCDPSession(); await network.send("Network.enable");
  network.on("Network.webSocketCreated",event => logs.push("socket-created:"+event.url));
  await page.evaluateOnNewDocument(() => Object.defineProperty(navigator,"userAgentData",{value:{platform:"Linux"}}));
  page.on("console",message => {
    const line = message.text(); logs.push(line);
    if (line.startsWith("process-request:")) requests.push(JSON.parse(line.slice(16)));
    if (line.startsWith("process-reply:")) {
      const data = JSON.parse(line.slice(14)); replies.push(data);
      if (data.ev === "proc.out" && data.stream === "stdout") stdout(data.pid,data.data);
    }
    writeFileSync(join(shots,"console.log"),logs.join("\n"));
  });
  page.on("pageerror",error => logs.push("PAGE ERROR "+error.stack));
  const url = `http://127.0.0.1:${webPort}/?session=${encodeURIComponent(`ws://127.0.0.1:${proxyPort}/session`)}&project=build.hxml&env=RAYDE_LSP_TRACE=1#token=lsp-test`;
  await page.goto(url,{waitUntil:"domcontentloaded"});
  await until(() => logs.includes("ashui: ready"),"browser ready"); await sleep(1000);
  assert.equal(requests.some(r => r.command === "rayzor"),false,"Welcome must not start the lazy language server");
  await page.keyboard.down("Control"); await page.keyboard.press("p"); await page.keyboard.up("Control");
  await sleep(400); await page.keyboard.type("Main.hx",{delay:20}); await sleep(250); await page.keyboard.press("Enter");
  await until(() => requests.some(r => r.op === "proc.spawn" && r.command === "rayzor"),"built-in extension starts a remote Rayzor");
  const start = requests.find(r => r.op === "proc.spawn" && r.command === "rayzor");
  assert.deepEqual(start.args,["lsp"]); assert.equal(start.cwd,""); assert.equal(start.env.RAYZOR_STD_PATH,stdlib);
  await until(() => replies.some(r => r.id === start.id && r.pid != null),"remote Rayzor process ID");
  const pid = replies.find(r => r.id === start.id).pid;
  await until(() => messages.some(m => m.pid === pid && m.body.result?.capabilities?.hoverProvider),"remote initialize response");
  await until(() => messages.some(m => m.pid === pid && m.body.method === "textDocument/publishDiagnostics"),"remote diagnostics");
  await sleep(500); await page.screenshot({path:join(shots,"ready.png")});
  await page.mouse.move(488,153); await sleep(1500);
  await until(() => messages.some(m => m.pid === pid && JSON.stringify(m.body.result?.contents ?? "").includes("Main")),"semantic hover from actual editor pointer");
  await until(() => replies.some(reply => reply.result?.kind === "document" && reply.result.children.some(node => node.kind === "code")),"browser-local Markdown fragment");
  await sleep(300);
  await page.screenshot({path:join(shots,"hover.png")});
  report.hover = report.diagnostics = report.lazyStart = true;
  await page.mouse.click(700,340); await page.keyboard.down("Control"); await page.keyboard.press("End"); await page.keyboard.up("Control");
  await page.keyboard.type("// synced edit\n",{delay:15});
  await until(() => messages.some(m => m.pid === pid && m.body.method === "textDocument/publishDiagnostics" && m.body.params.version > 1),"diagnostics after an editor change");
  report.liveEdits = true;
  assert.equal(requests.filter(request => request.command === "rayzor").length,1,"rendering and editing must not restart a healthy language server");

  // A sustained transport loss must not exhaust either the extension or LSP restart budget.
  available = false;
  for (const peer of peers) peer.terminate();
  await sleep(1000);
  const offlineAt = requests.length;
  await page.keyboard.type("// offline recovery edit\n",{delay:15});
  await sleep(8500);
  assert.equal(requests.slice(offlineAt).filter(request => request.op === "proc.spawn").length,0,"offline supervision must not keep starting extension hosts or language servers");
  const recoveredAt = messages.length;
  available = true;
  await until(() => requests.filter(request => request.command === "rayzor").length === 2,"Rayzor extension recovers after a long outage");
  const restarted = requests.filter(request => request.command === "rayzor")[1];
  await until(() => replies.some(reply => reply.id === restarted.id && reply.pid != null),"replacement process ID");
  const replacement = replies.find(reply => reply.id === restarted.id).pid;
  await until(() => messages.slice(recoveredAt).some(message => message.pid === replacement && message.body.method === "textDocument/publishDiagnostics" && message.body.params.version >= 1),"diagnostics after replaying offline edits");
  assert.ok(requests.some(request => request.op === "proc.write" && request.pid === replacement && Buffer.from(request.data,"base64").toString().includes("offline recovery edit")),"reinitialized LSP must receive the current unsaved document");
  await page.keyboard.type("// after reconnect\n",{delay:15});
  await until(() => messages.slice(recoveredAt).some(message => message.pid === replacement && message.body.method === "textDocument/publishDiagnostics" && message.body.params.version > 1),"live diagnostics remain active after reconnect");
  await page.screenshot({path:join(shots,"reconnected.png")});
  report.reconnect = report.offlineEdits = true;
  assert.equal(logs.some(line => line.includes("native-socket:")),false,"browser inspection must not fall back to probing native compiler ports");
  assert.equal(logs.some(line => /PAGE ERROR|RayDE stopped:|uncaught exception/.test(line)),false);
  report.ok = true;
} finally {
  writeFileSync(join(shots,"result.json"),JSON.stringify(report,null,2));
  writeFileSync(join(shots,"messages.json"),JSON.stringify(messages,null,2));
  writeFileSync(join(shots,"processes.json"),JSON.stringify({requests,replies:replies.filter(r => r.pid != null && r.ev == null)},null,2));
  await browser?.close(); for (const peer of peers) peer.terminate(); relay.close(); session.kill("SIGINT"); server.close();
}
console.log(JSON.stringify(report,null,2));
