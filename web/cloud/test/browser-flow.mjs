// Explicit end-to-end test: mocked GitHub/compute, Rust edge and a real remote Rust workspace.
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createServer as netServer } from "node:net";
import { mkdtemp, mkdir, readFile, writeFile, appendFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";
import { fixture, listening } from "./fixture.mjs";
const puppeteer = createRequire(new URL("../../session/package.json", import.meta.url))("puppeteer-core");
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
const native=spawn(join(root,"native/session/target/debug/rayde-session"),["--root",directory,"--state-root",state,"--port",String(compute),"--token","compute-secret","--origin",appOrigin],{stdio:"ignore"});
await listening(compute,native);
const assets=createServer(async(req,res)=>{try{
  const name=decodeURIComponent(new URL(req.url,"http://localhost").pathname);
  const file=resolve(artifact,"."+(name==="/"?"/index.html":name));
  if (!file.startsWith(artifact+"/")) throw new Error("outside assets");
  let bytes=await readFile(file);
  if (name==="/thread.js") bytes=Buffer.from('addEventListener("unhandledrejection",e=>console.error("thread rejected:",String(e.reason)));\n'+bytes.toString());
  if (name==="/ashui-host.mjs") bytes=Buffer.from(bytes.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)","3"));
  if (name==="/rayde_session.mjs") bytes=Buffer.from(bytes.toString()
    .replace("const answer = (message) => {",'const answer = (message) => { if(message.result?.durable) console.log("durable-save:"+JSON.stringify(message.result.durable));')
    .replace("const request = JSON.parse(text2);",'const request = JSON.parse(text2); if(request.op==="view.ready") console.log("shared-view-ready");'));
  res.writeHead(200,{"Content-Type":/\.wasm$/.test(name)?"application/wasm":/\.(m?js)$/.test(name)?"text/javascript":"text/html"});res.end(bytes);
}catch{res.writeHead(404).end();}}).listen(0,"127.0.0.1");
await new Promise(resolve=>assets.once("listening",resolve));
const local=await fixture({port,appOrigin,asset:`http://127.0.0.1:${assets.address().port}`,endpoint:`ws://127.0.0.1:${compute}/session`});
const browser=await puppeteer.launch({executablePath:"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",headless:"new",args:["--no-sandbox","--enable-unsafe-webgpu"],defaultViewport:{width:1280,height:800}});
const lines=[];let page;
await writeFile(join(shots,"live.log"),"");
try {
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
    const modifier=await page.evaluate(()=>/mac/i.test(navigator.userAgentData?.platform??navigator.platform)?"Meta":"Control");
    await page.keyboard.down(modifier);await page.keyboard.press("p");await page.keyboard.up(modifier);
    await sleep(500);await page.keyboard.type("Main.hx",{delay:20});await sleep(250);await page.keyboard.press("Enter");
    for(let i=0;i<300 && !lines.includes("shared-view-ready");i++)await sleep(50);
    assert.ok(lines.includes("shared-view-ready"),"hosted editor did not open its shared document");
    const content='class Main { static function main() { trace("durable browser save"); } }';
    await page.mouse.click(700,300);await page.keyboard.down(modifier);await page.keyboard.press("a");await page.keyboard.up(modifier);
    await page.keyboard.type(content,{delay:3});
    await page.keyboard.down(modifier);await page.keyboard.press("s");await page.keyboard.up(modifier);
    for(let i=0;i<300 && !lines.some(line=>line.startsWith("durable-save:"));i++)await sleep(50);
    const receipt=JSON.parse(lines.find(line=>line.startsWith("durable-save:"))?.slice(13)??"null");
    assert.ok(receipt?.id,"browser Save returned no durable checkpoint receipt");
    assert.equal(await readFile(join(directory,"src/Main.hx"),"utf8"),content);
    const namespace=await local.mf.getDurableObjectNamespace("WORKSPACES"),id=new URL(page.url()).pathname.slice(1);
    const stored=await namespace.get(namespace.idFromName(id)).fetch("https://internal/checkpoint",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner:1,id:receipt.id})});
    assert.equal(stored.status,200);assert.equal((await stored.json()).manifest.sha256,receipt.sha256);
    const start=lines.length;await page.reload();await ready(start);await page.screenshot({path:join(shots,"restored-workspace.png")});
    assert.equal(local.calls.runner.length,1,"reload reprovisioned the workspace");
    assert.equal(await readFile(join(directory,"src/Main.hx"),"utf8"),content);
    assert.equal(lines.some(line=>/RayDE stopped:|uncaught exception|thread rejected:/.test(line)),false);
    console.log("GitHub sign-in, repository chooser, real Rust gateway, full-editor durable Save and reload passed");
  }
} catch(error){if(page)await page.screenshot({path:join(shots,"failure.png")});throw error;}
finally{await writeFile(join(shots,"browser.log"),lines.join("\n"));await browser.close();await local.mf.dispose();await new Promise(resolve=>assets.close(resolve));native.kill();await rm(directory,{recursive:true,force:true});await rm(state,{recursive:true,force:true});}
