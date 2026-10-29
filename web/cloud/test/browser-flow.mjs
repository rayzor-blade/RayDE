// Explicit end-to-end test: mocked GitHub/compute, Rust edge and a real remote Rust workspace.
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createServer as netServer } from "node:net";
import { mkdtemp, mkdir, readFile, writeFile, appendFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import { fixture, listening } from "./fixture.mjs";
const puppeteer = createRequire(new URL("../../session/package.json", import.meta.url))("puppeteer-core");
const Y = createRequire(new URL("../../session/package.json", import.meta.url))("yjs");
const {WebSocket}=createRequire(new URL("../../session/package.json",import.meta.url))("ws");
const buffered=process.argv.includes("--buffered-restore"),file=buffered?"src/Recovered.hx":"src/Main.hx";
const runnerConfig=process.env.RAYDE_MSB_RUNNER_CONFIG?JSON.parse(await readFile(process.env.RAYDE_MSB_RUNNER_CONFIG,"utf8")):null;
const appPreview=process.argv.includes("--app-preview");
if(buffered&&runnerConfig)throw Error("Run buffered restore and the MSB provider flow separately");
if(appPreview&&!runnerConfig)throw Error("--app-preview requires a preview-equipped MSB runner configuration");
const root = resolve("../.."), artifact = resolve(process.argv.slice(2).find(arg=>!arg.startsWith("--")) ?? "../../bin/web/repositories"), shots = join(root,"bin/web/github-flow");
await mkdir(shots,{recursive:true});
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
const freePort = () => new Promise(resolve => { const s=netServer().listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>resolve(p));});});
const port=await freePort(), compute=await freePort(), appOrigin=`http://127.0.0.1:${port}`;
const directory=await mkdtemp(join(tmpdir(),"rayde-cloud-browser-"));
const state=await mkdtemp(join(tmpdir(),"rayde-cloud-browser-state-"));
await mkdir(join(directory,"src")); await mkdir(join(directory,".rayde"));
await writeFile(join(directory,"build.hxml"),"-cp src\n-main Main\n--interp\n");
await writeFile(join(directory,"src/Main.hx"),'class Main {\n  static function main() { trace("remote GitHub workspace"); }\n}\n');
const native=runnerConfig?null:spawn(join(root,"native/session/target/debug/rayde-session"),["--root",directory,"--state-root",state,"--port",String(compute),"--token","compute-secret","--origin",appOrigin],{stdio:"ignore"});
if(native)await listening(compute,native);
let savedBaseline='class Recovered {}\n';
async function prepareBuffered(){
  if(!buffered)return;
  await writeFile(join(directory,file),savedBaseline);
  const doc=new Y.Doc();doc.getText("text").insert(0,'class Recovered { static function main() { trace("recovered unsaved buffer"); } }');
  const bytes=Buffer.from(Y.encodeStateAsUpdate(doc)),checkpoint={version:1,update:bytes.toString("base64"),sha256:createHash("sha256").update(bytes).digest("hex")};doc.destroy();
  const socket=new WebSocket(`ws://127.0.0.1:${compute}/session`,{origin:appOrigin});await new Promise((resolve,reject)=>{socket.once("open",resolve);socket.once("error",reject);});
  let serial=0;const pending=new Map();socket.on("message",data=>{const response=JSON.parse(String(data));pending.get(response.id)?.(response);pending.delete(response.id);});
  const request=(op,params={})=>new Promise((resolve,reject)=>{const id=++serial,timer=setTimeout(()=>reject(Error("Restore preparation timed out")),10000);pending.set(id,response=>{clearTimeout(timer);resolve(response);});socket.send(JSON.stringify({id,op,...params}));});
  await request("hello",{token:"compute-secret"});assert.equal((await request("doc.restore",{path:file,mode:"buffer",diskSha256:createHash("sha256").update(savedBaseline).digest("hex"),checkpoint})).ok,true);socket.close();
}
const assets=createServer(async(req,res)=>{try{
  const name=decodeURIComponent(new URL(req.url,"http://localhost").pathname);
  const file=resolve(artifact,"."+(name==="/"?"/index.html":name));
  if (!file.startsWith(artifact+"/")) throw new Error("outside assets");
  let bytes=await readFile(file);
  if (name==="/thread.js") bytes=Buffer.from('addEventListener("unhandledrejection",e=>console.error("thread rejected:",String(e.reason)));\n'+bytes.toString());
  if (name==="/ashui-host.mjs") bytes=Buffer.from(bytes.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)","3"));
  if (name==="/rayde_session.mjs") bytes=Buffer.from(bytes.toString()
    .replace("const answer = (message) => {",`const previewRequests=new Set(),previewPids=new Set();
      const answer = (message) => {
        if(previewRequests.delete(message.id)&&message.pid)previewPids.add(message.pid);
        if(previewPids.has(message.pid)){
          if(message.ev==="proc.out")console.log("preview-output:"+atob(message.data));
          if(message.ev==="proc.exit"){previewPids.delete(message.pid);if(message.code!==0)globalThis.previewFailure="Guest compiler exited with "+message.code;}
        }
        if(message.ok===false)console.log("workspace-rpc-error:"+message.code+":"+message.message);
        if(message.cacheNote)console.log("preview-cache-note:"+message.cacheNote);
        if(message.cached==="wasm")console.log("preview-cache-hit");
        if(message.result?.dirty)console.log("restored-buffer-dirty");
        if(message.result?.durable)console.log("durable-save:"+JSON.stringify(message.result.durable));`)
    .replace("const request = JSON.parse(text2);",'const request = JSON.parse(text2); if(request.op==="proc.spawn"&&request.args?.some(arg=>String(arg).endsWith("/app.hl"))){console.log("preview-compile");previewRequests.add(request.id);} if(request.op==="view.ready") console.log("shared-view-ready");'));
  res.writeHead(200,{"Content-Type":/\.wasm$/.test(name)?"application/wasm":/\.(m?js)$/.test(name)?"text/javascript":name.endsWith(".css")?"text/css":"text/html"});res.end(bytes);
}catch{res.writeHead(404).end();}}).listen(0,"127.0.0.1");
await new Promise(resolve=>assets.once("listening",resolve));
const runnerSettings=runnerConfig?{runnerUrl:runnerConfig.url,runnerSecret:(await readFile(runnerConfig.secretFile,"utf8")).trim()}:{};
const local=await fixture({port,appOrigin,asset:`http://127.0.0.1:${assets.address().port}`,endpoint:`ws://127.0.0.1:${compute}/session`,...runnerSettings});
const browser=await puppeteer.launch({executablePath:"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",headless:"new",args:["--no-sandbox","--enable-unsafe-webgpu"],defaultViewport:{width:1280,height:800}});
const lines=[];let page,remoteFiles,account;
await writeFile(join(shots,"live.log"),"");
try {
  await prepareBuffered();
  page=await browser.newPage();page.on("console",m=>{lines.push(m.text());void appendFile(join(shots,"live.log"),m.text()+"\n");});page.on("pageerror",e=>lines.push(String(e)));
  const devtools=await page.createCDPSession();
  await devtools.send("Fetch.enable",{patterns:[{urlPattern:"https://github.com/login/oauth/authorize*",requestStage:"Request"}]});
  devtools.on("Fetch.requestPaused",async event=>{
    const url=new URL(event.request.url);
    await devtools.send("Fetch.fulfillRequest",{requestId:event.requestId,responseCode:302,responseHeaders:[{name:"Location",value:`${appOrigin}/auth/github/callback?state=${url.searchParams.get("state")}&code=alice`}]});
  });
  async function ready(from=0) {for(let i=0;i<1200;i++){if(lines.slice(from).some(l=>l==="ashui: ready")){await sleep(800);return;}if(lines.slice(from).some(l=>/RayDE stopped:|uncaught exception/.test(l)))break;await sleep(100);}throw new Error("editor not ready: "+lines.slice(from).join("\n"));}
  await page.goto(appOrigin+"/?repositories=1");await ready();
  await page.screenshot({path:join(shots,"signed-out.png")});
  if(process.argv.includes("--capture-only")){console.log("signed-out captured");}
  else {
    const from=lines.length;
    await page.mouse.click(640,420);
    for(let i=0;i<300 && local.calls.exchanges.length===0;i++)await sleep(100);
    assert.equal(local.calls.exchanges.length,1,"Continue with GitHub did not start OAuth");
    await ready(from);
    await sleep(600);await page.screenshot({path:join(shots,"repositories.png")});
    const before=lines.length;
    await page.mouse.click(600,292);
    for(let i=0;i<600 && !/^\/[\w-]{43}$/.test(new URL(page.url()).pathname);i++)await sleep(100);
    assert.match(new URL(page.url()).pathname,/^\/[\w-]{43}$/, "repository did not open its workspace URL");
    assert.equal(new URL(page.url()).searchParams.get("session"),null);
    await ready(before);await sleep(600);
    await page.screenshot({path:join(shots,"remote-workspace.png")});
    assert.equal(local.calls.runner.length,1);assert.ok(!page.url().includes("compute-secret"));
    assert.equal(await page.evaluate(()=>document.querySelectorAll("canvas").length),1);
    const session=await page.evaluate(async()=>{const r=await fetch("/api/session");return r.json();});assert.equal(session.user.login,"alice");
    const cookie=(await page.cookies(appOrigin)).map(value=>value.name+"="+value.value).join("; ");
    account={cookie,csrf:session.csrf};
    const upgraded=await local.fetch("/api/workspaces/"+new URL(page.url()).pathname.slice(1)+"/socket",{headers:{Cookie:cookie,Origin:appOrigin,Upgrade:"websocket"}});assert.equal(upgraded.status,101);
    remoteFiles=upgraded.webSocket;remoteFiles.accept();let serial=0;const pending=new Map();
    remoteFiles.addEventListener("message",event=>{const reply=JSON.parse(event.data);pending.get(reply.id)?.(reply);pending.delete(reply.id);});
    const rpc=(op,params={})=>new Promise((resolve,reject)=>{const id=++serial,timer=setTimeout(()=>{pending.delete(id);reject(Error("Remote file check timed out"));},10000);pending.set(id,reply=>{clearTimeout(timer);resolve(reply);});remoteFiles.send(JSON.stringify({id,op,...params}));});
    assert.equal((await rpc("hello")).ok,true);
    const savedText=async()=>{const reply=await rpc("fs.read",{path:file});assert.equal(reply.ok,true);return reply.data;};
    const modifier=await page.evaluate(()=>/mac/i.test(navigator.userAgentData?.platform??navigator.platform)?"Meta":"Control");
    await page.keyboard.down(modifier);await page.keyboard.press("p");await page.keyboard.up(modifier);
    await sleep(500);await page.keyboard.type(buffered?"Recovered.hx":"Main.hx",{delay:20});await sleep(250);await page.keyboard.press("Enter");
    for(let i=0;i<300 && !lines.includes("shared-view-ready");i++)await sleep(50);
    assert.ok(lines.includes("shared-view-ready"),"hosted editor did not open its shared document");
    if(appPreview){
      async function choose(query){
        await page.evaluate(()=>document.querySelector("#screen").focus());
        await page.keyboard.down(modifier);await page.keyboard.press("p");await page.keyboard.up(modifier);
        await sleep(500);await page.keyboard.sendCharacter(query);await sleep(400);await page.keyboard.press("Enter");
      }
      async function previewReady(previous){
        await page.waitForFunction(previous=>{const frame=document.querySelector('iframe[data-rayde-app-preview]');return globalThis.previewFailure||frame?.title==="Pocket Studio"&&(!previous||frame.src!==previous);},{timeout:180000},previous);
        assert.equal(await page.evaluate(()=>globalThis.previewFailure),undefined,"The guest app compiler failed; see browser.log");
        const element=await page.$('iframe[data-rayde-app-preview]'),frame=await element.contentFrame();
        await frame.waitForFunction(()=>document.querySelector("#status")?.hidden,{timeout:90000});
        return {element,frame};
      }
      console.log("Building Pocket Studio through the Worker and real MSB guest");
      await choose(">Preview App");
      let preview=await previewReady();
      let previewUrl=preview.frame.url();
      assert.notEqual(new URL(previewUrl).origin,appOrigin);
      assert.equal(await preview.frame.evaluate(()=>crossOriginIsolated),true);
      assert.equal(await preview.frame.evaluate(()=>{try{parent.localStorage;return false;}catch{return true;}}),true);
      const compiles=lines.filter(line=>line==="preview-compile").length;
      assert.equal(compiles,2,"The initial preview must compile Haxe and WASM in the guest");
      const cached=lines.length;
      await choose(">Preview App");
      for(let i=0;i<600&&!lines.slice(cached).includes("preview-cache-hit");i++)await sleep(50);
      assert.ok(lines.slice(cached).includes("preview-cache-hit"),"unchanged MSB preview missed its build cache");
      preview=await previewReady(previewUrl);previewUrl=preview.frame.url();
      assert.equal(lines.filter(line=>line==="preview-compile").length,compiles,"cached MSB preview ran a compiler");
      const savedTasks=async()=>{const response=await rpc("fs.read",{path:"data/tasks.json"});assert.equal(response.ok,true);return JSON.parse(response.data);};
      const tasks=await savedTasks(),box=await preview.element.boundingBox();
      await page.mouse.click(box.x+box.width-80,box.y+106);await sleep(300);
      await page.mouse.click(box.x+box.width-200,box.y+106);
      let changed=tasks;
      for(let i=0;i<300&&changed.length===tasks.length;i++){await sleep(50);changed=await savedTasks();}
      assert.equal(changed.length,tasks.length+1,"the guest-built app did not save its task through the authorized workspace bridge");
      await preview.element.screenshot({path:join(shots,"msb-app-preview.png")});
      assert.equal((await fetch(previewUrl)).status,200,"the active preview capability is unavailable");
      await choose(">Close Tab");
      await page.waitForFunction(()=>!document.querySelector('iframe[data-rayde-app-preview]'),{timeout:15000});
      let status=0;
      for(let i=0;i<100&&status!==404;i++){status=(await fetch(previewUrl)).status;if(status!==404)await sleep(50);}
      assert.equal(status,404,"obsolete MSB preview capability remained usable");
      await choose("Main.hx");
      console.log("MSB preview render, origin isolation, cached rebuild, workspace save and closure passed");
    }
    if(buffered){
      assert.ok(lines.includes("restored-buffer-dirty"));assert.equal(await savedText(),savedBaseline);
      await page.keyboard.down(modifier);await page.keyboard.press("s");await page.keyboard.up(modifier);
      for(let i=0;i<300&&!lines.some(line=>line.startsWith("durable-save:"));i++)await sleep(50);
      assert.ok(lines.some(line=>line.startsWith("durable-save:")),"initial recovered tab must be dirty and saveable before further typing");
      savedBaseline=await savedText();assert.match(savedBaseline,/recovered unsaved buffer/);
    }
    const savesFrom=lines.length;
    const content='class Main { static function main() { trace("durable browser save"); } }';
    await page.mouse.click(700,300);await page.keyboard.down(modifier);await page.keyboard.press("a");await page.keyboard.up(modifier);
    await page.keyboard.type(content,{delay:3});
    const namespace=await local.mf.getDurableObjectNamespace("WORKSPACES"),id=new URL(page.url()).pathname.slice(1),stub=namespace.get(namespace.idFromName(id));
    const control=async(op,body={})=>{const response=await stub.fetch("https://internal/"+op,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner:1,...body})});assert.equal(response.status,200);return response.json();};
    let recovered="";
    for(let i=0;i<300 && recovered!==content;i++) {
      const journals=await control("journals");
      for(const journal of journals.ids) {
        const record=await control("journal",{id:journal});
        if(record.manifest.path!==file)continue;
        const doc=new Y.Doc();Y.applyUpdate(doc,Buffer.from(record.checkpoint.update,"base64"));recovered=doc.getText("text").toString();doc.destroy();
      }
      if(recovered!==content)await sleep(50);
    }
    assert.equal(recovered,content,"full-editor changes must be durably recoverable before Save");
    if(buffered)assert.equal(await savedText(),savedBaseline,"recovered buffer edits must leave the saved file unchanged");
    await page.keyboard.down(modifier);await page.keyboard.press("s");await page.keyboard.up(modifier);
    for(let i=0;i<300 && !lines.slice(savesFrom).some(line=>line.startsWith("durable-save:"));i++)await sleep(50);
    const receipt=JSON.parse(lines.slice(savesFrom).find(line=>line.startsWith("durable-save:"))?.slice(13)??"null");
    assert.ok(receipt?.id,"browser Save returned no durable checkpoint receipt");
    assert.equal(await savedText(),content);
    const stored=await namespace.get(namespace.idFromName(id)).fetch("https://internal/checkpoint",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner:1,id:receipt.id})});
    assert.equal(stored.status,200);assert.equal((await stored.json()).manifest.sha256,receipt.sha256);
    const start=lines.length;await page.reload();await ready(start);await page.screenshot({path:join(shots,"restored-workspace.png")});
    assert.equal(local.calls.runner.length,1,"reload reprovisioned the workspace");
    assert.equal(await savedText(),content);
    assert.equal(lines.some(line=>/RayDE stopped:|uncaught exception|thread rejected:/.test(line)),false);
    console.log("GitHub sign-in, repository chooser, "+(runnerConfig?"real MSB compute, ":"")+(buffered?"buffered recovery, dirty-tab Save, ":"")+"unsaved edit recovery, durable Save and reload passed");
  }
} catch(error){if(page)await page.screenshot({path:join(shots,"failure.png")});throw error;}
finally{
  // Sign out while the edge is still alive, so outgoing compute sockets finish
  // before disposing the local Worker (the real MSB service stays running).
  if(account)await local.fetch("/api/logout",{method:"POST",headers:{Cookie:account.cookie,Origin:appOrigin,"X-RayDE-CSRF":account.csrf,"Content-Type":"application/json"},body:"{}"});
  remoteFiles?.close();await writeFile(join(shots,"browser.log"),lines.join("\n"));await browser.close();await local.mf.dispose();await new Promise(resolve=>assets.close(resolve));native?.kill();await rm(directory,{recursive:true,force:true});await rm(state,{recursive:true,force:true});
}
