// Real browser definition navigation, including targets the connected workspace cannot read.
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {createServer} from "node:http";
import {createServer as tcpServer} from "node:net";
import {createRequire} from "node:module";
import {resolve,join,dirname} from "node:path";
const root=resolve(import.meta.dirname,"../.."),dir=resolve(process.argv[2]??"bin/web/rayde");
const require=createRequire(join(root,"web/session/package.json")),puppeteer=require("puppeteer-core");
const rayzor=resolve(process.env.RAYDE_RAYZOR_LSP??join(root,"../rayzor/target/release/rayzor")),stdlib=resolve(process.env.RAYZOR_STD_PATH??join(root,"../rayzor/compiler/haxe-std"));
const workspace=mkdtempSync(join(tmpdir(),"rayde-navigation-")),shots=join(root,"bin/web/navigation-shots");
mkdirSync(join(workspace,"src"));mkdirSync(join(workspace,".rayde"));mkdirSync(shots,{recursive:true});
writeFileSync(join(workspace,"src/Main.hx"),'class Main {\n static function main() {\n  Helper.go();\n  StringTools.trim(" x ");\n }\n}\n');
writeFileSync(join(workspace,"src/Helper.hx"),'class Helper {\n public static function go() {}\n}\n');
writeFileSync(join(workspace,"build.hxml"),"-cp src\n-main Main\n--interp\n");
writeFileSync(join(workspace,".rayde/settings.json"),JSON.stringify({"extension.rayzor":{stdlib},extensions:{disabled:["git","markdown"]}}));
const pause=ms=>new Promise(r=>setTimeout(r,ms)),logs=[],messages=[],streams=new Map();
const report={ok:false};
const visitor=process.env.RAYDE_VISITOR_TEST??"Linux",modifier=visitor==="Mac"?"Meta":"Control";
const freePort=()=>new Promise(r=>{const s=tcpServer().listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>r(p));});});
const webPort=await freePort(),sessionPort=await freePort();
async function until(check,label,seconds=30){
 const end=Date.now()+seconds*1000;
 while(!check()){
  const failure=logs.find(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s));if(failure)throw new Error(failure);
  if(Date.now()>end)throw new Error("Timed out: "+label);await pause(50);
 }
}
function output(pid,data){
 let b=Buffer.concat([streams.get(pid)??Buffer.alloc(0),Buffer.from(data,"base64")]);
 while(b.includes("\r\n\r\n")){
  const at=b.indexOf("\r\n\r\n"),length=Number(b.subarray(0,at).toString().match(/content-length:\s*(\d+)/i)?.[1]);
  if(!length||b.length<at+4+length)break;
  messages.push(JSON.parse(b.subarray(at+4,at+4+length).toString()));b=b.subarray(at+4+length);
 }
 streams.set(pid,b);
}
const server=createServer((request,response)=>{
 try{
  const name=new URL(request.url,"http://local").pathname,path=resolve(dir,"."+(name==="/"?"/index.html":name));if(!path.startsWith(dir+"/"))throw "outside";
  let body=readFileSync(path);
  if(name==="/ashui-host.mjs")body=Buffer.from(body.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)","3"));
  if(name==="/rayde_session.mjs")body=Buffer.from(body.toString()
   .replace('let reply;', 'let reply; if (globalThis.__holdBuild && request.op.startsWith("fs.") && request.path === "build.hxml") { console.log("build-file-held"); await new Promise(resolve => (globalThis.__buildReaders ??= []).push(resolve)); }')
   .replace('if (request.op === "hello")','if (globalThis.__delayBuild && request.op === "fs.list") { console.log("build-scan-held"); await new Promise(resolve => setTimeout(resolve,3000)); } if (request.op === "hello")')
   .replace("const answer = (message) => {",'const answer = (message) => { if (message.ev === "proc.out") console.log("stream:"+JSON.stringify(message));'));
  response.writeHead(200,{"Content-Type":path.endsWith(".wasm")?"application/wasm":/\.m?js$/.test(path)?"text/javascript":"text/html","Cross-Origin-Opener-Policy":"same-origin","Cross-Origin-Embedder-Policy":"require-corp"});response.end(body);
 }catch{response.writeHead(404).end();}
}).listen(webPort,"127.0.0.1");
const session=spawn(join(root,"native/session/target/debug/rayde-session"),["--root",workspace,"--state-root",join(workspace,".rayde-session"),"--port",String(sessionPort),"--token","navigation-test","--origin",`http://127.0.0.1:${webPort}`,"--exec","--extension-host",join(root,"bin/rayde-extension-host"),"--extensions",join(root,"extensions")],{stdio:"ignore",env:{...process.env,PATH:dirname(rayzor)+":"+process.env.PATH,RAYZOR_STD_PATH:stdlib}});
let browser,page;
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME??"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",headless:true,args:["--no-sandbox","--enable-unsafe-webgpu"],defaultViewport:{width:1280,height:800}});
 page=await browser.newPage();await page.evaluateOnNewDocument(visitor=>Object.defineProperty(navigator,"userAgentData",{value:{platform:visitor==="Mac"?"macOS":visitor}}),visitor);
 page.on("console",m=>{const s=m.text();logs.push(s);if(s.startsWith("stream:")){const r=JSON.parse(s.slice(7));if(r.stream==="stdout")output(r.pid,r.data);}writeFileSync(join(shots,"console.log"),logs.join("\n"));});
 page.on("pageerror",e=>logs.push("PAGE ERROR "+e.stack));
 await page.goto(`http://127.0.0.1:${webPort}/?session=${encodeURIComponent(`ws://127.0.0.1:${sessionPort}/session`)}&project=build.hxml&env=RAYDE_SETTINGS_TIMING=1#token=navigation-test`,{waitUntil:"domcontentloaded"});
 await until(()=>logs.includes("ashui: ready"),"ready");
 await page.evaluate(()=>{globalThis.__holdBuild=true;globalThis.__delayBuild=true;});
 const settingsStart=Date.now();
 await page.mouse.click(155,115);
 await until(()=>logs.includes("build-file-held"),"build file read");
 await until(()=>logs.some(s=>s.startsWith("settings-ready:")),"Settings while build file is held",2);
 report.loadingMs=Date.now()-settingsStart;
 await page.screenshot({path:join(shots,"build-file-loading.png")});
 await page.evaluate(()=>{globalThis.__holdBuild=false;for(const ready of globalThis.__buildReaders??[])ready();globalThis.__buildReaders=[];});
 report.settingsBeforeFile=true;
 await until(()=>logs.includes("build-scan-held"),"background build scan");
 await pause(200);await page.screenshot({path:join(shots,"build-form-during-scan.png")});
 await page.evaluate(()=>globalThis.__delayBuild=false);
 report.buildFormWhileScanning=true;
 async function chord(key){await page.keyboard.down(modifier);await page.keyboard.press(key);await page.keyboard.up(modifier);}
 async function open(name){await chord("p");await pause(250);await page.keyboard.type(name,{delay:10});await pause(200);await page.keyboard.press("Enter");await pause(500);}
 async function definition(word){
  const before=messages.length;
  await chord("f");await pause(150);await page.keyboard.type(word,{delay:10});await pause(200);await page.keyboard.press("Escape");await page.keyboard.press("ArrowLeft");await page.keyboard.press("ArrowRight");
  if(word==="Helper") { await page.keyboard.down(modifier);await page.mouse.click(462,174);await page.keyboard.up(modifier); }
  else await page.keyboard.press("F12");
  await until(()=>messages.slice(before).some(m=>m.result?.uri||Array.isArray(m.result)&&m.result.some(r=>r.uri||r.targetUri)),"definition response");
  await pause(700);
  assert.equal(logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)),false,logs.slice(-15).join("\n"));
 }
 await open("Main.hx");await until(()=>messages.some(m=>m.method==="textDocument/publishDiagnostics"),"Rayzor diagnostics");
 await page.mouse.click(650,155);
 await definition("Helper");await page.screenshot({path:join(shots,"workspace-definition.png")});report.workspaceDefinition=report.modifierClick=true;
 await open("Main.hx");await page.mouse.click(650,155);
 await definition("StringTools");await page.screenshot({path:join(shots,"dependency-definition.png")});report.dependencyHandled=true;
 await open("Helper.hx");await page.screenshot({path:join(shots,"still-responsive.png")});report.ok=true;
}finally{
 writeFileSync(join(shots,"result.json"),JSON.stringify(report,null,2));writeFileSync(join(shots,"messages.json"),JSON.stringify(messages,null,2));
 if(page)await page.screenshot({path:join(shots,"last.png")}).catch(()=>{});
 await browser?.close();session.kill("SIGINT");server.close();
}
console.log(JSON.stringify(report));
