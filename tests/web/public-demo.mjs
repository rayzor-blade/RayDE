// Local HTTPS probe of the landing hostname; no public DNS or deployment is changed.
import { execFileSync } from "node:child_process";
import { createServer } from "node:https";
import { createRequire } from "node:module";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";
const puppeteer = createRequire(new URL("../../web/session/package.json", import.meta.url))("puppeteer-core");
const root = resolve(process.argv[2] ?? "bin/web/entries"), shots = resolve("bin/web/public-demo");
await mkdir(shots,{recursive:true});
const temporary = await mkdtemp(join(tmpdir(),"rayde-demo-tls-")), key = join(temporary,"key.pem"), cert = join(temporary,"cert.pem");
execFileSync("openssl",["req","-x509","-newkey","rsa:2048","-nodes","-keyout",key,"-out",cert,"-days","1","-subj","/CN=rayde.org"],{stdio:"ignore"});
let privateCalls=0;
const server=createServer({key:await readFile(key),cert:await readFile(cert)},async(req,res)=>{try{
  const name=decodeURIComponent(new URL(req.url,"https://rayde.org").pathname);
  if(name.startsWith("/api/"))privateCalls++;
  const file=resolve(root,"."+(name==="/"?"/index.html":name));
  if(!file.startsWith(root+"/"))throw new Error("outside assets");
  let data=await readFile(file);
  if(name==="/ashui-host.mjs")data=Buffer.from(data.toString().replace("Math.max(1, (navigator.hardwareConcurrency || 4) - 1)","3"));
  res.writeHead(200,{"Content-Type":name.endsWith(".wasm")?"application/wasm":/\.(m?js)$/.test(name)?"text/javascript":"text/html","Cross-Origin-Opener-Policy":"same-origin","Cross-Origin-Embedder-Policy":"require-corp"});res.end(data);
}catch{res.writeHead(404).end();}}).listen(0,"127.0.0.1");
await new Promise(resolve=>server.once("listening",resolve));
const browser=await puppeteer.launch({executablePath:process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",headless:"new",args:["--no-sandbox","--enable-unsafe-webgpu","--ignore-certificate-errors","--no-proxy-server","--host-resolver-rules=MAP rayde.org 127.0.0.1"],defaultViewport:{width:1280,height:800}});
const lines=[];
try {
  const page=await browser.newPage();page.on("console",message=>lines.push(message.text()));page.on("pageerror",error=>lines.push(String(error)));
  await page.goto(`https://rayde.org:${server.address().port}/`);
  for(let i=0;i<1200 && !lines.some(line=>line==="ashui: ready");i++)await new Promise(resolve=>setTimeout(resolve,100));
  assert.ok(lines.includes("ashui: ready"),lines.join("\n"));
  await new Promise(resolve=>setTimeout(resolve,800));
  assert.equal(new URL(page.url()).searchParams.has("demo"),false);
  const example=await page.evaluate(()=>new Promise((resolve,reject)=>{
    const open=indexedDB.open("rayde-page",1);open.onerror=()=>reject(open.error);open.onsuccess=()=>{
      const db=open.result,request=db.transaction("files").objectStore("files").get("/work/src/Main.hx");
      request.onsuccess=()=>{resolve(request.result ? atob(request.result.data) : null);db.close();};request.onerror=()=>reject(request.error);
    };
  }));
  assert.match(example,/Hello from RayDE in browser/);
  assert.equal(privateCalls,0,"The landing demo queried a private account API");
  assert.equal(await page.evaluate(()=>document.querySelectorAll("canvas").length),1);
  assert.ok(!lines.some(line=>/RayDE stopped:|uncaught exception/.test(line)),lines.join("\n"));
  await page.screenshot({path:join(shots,"initial.png")});
  await writeFile(join(shots,"result.json"),JSON.stringify({ok:true,url:page.url(),privateCalls,example},null,2));
  console.log("Public landing hostname: demo seeded automatically with the browser greeting; no private API calls");
}finally{
  await writeFile(join(shots,"browser.log"),lines.join("\n"));await browser.close();await new Promise(resolve=>server.close(resolve));await rm(temporary,{recursive:true,force:true});
}
