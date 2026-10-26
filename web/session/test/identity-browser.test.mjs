import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import puppeteer from 'puppeteer-core';

const binary=resolve('../..','native/session/target/debug/rayde-session'),dist=resolve('dist');
const chrome=process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const freePort=()=>new Promise(r=>{const s=createServer().listen(0,'127.0.0.1',()=>{const port=s.address().port;s.close(()=>r(port));});});
async function until(check,label){const end=Date.now()+10000;while(!await check()){if(Date.now()>end)throw Error('Timed out: '+label);await pause(40);}}
function fixture(){
 const base=mkdtempSync(join(tmpdir(),'rayde-cache-')),a=join(base,'a/project'),b=join(base,'b/project');
 for(const [root,text] of [[a,'alpha'],[b,'beta']]){mkdirSync(root,{recursive:true});writeFileSync(join(root,'a.txt'),text);}
 return {base,a,b,state:join(base,'private-state')};
}
async function start(root,port,state,auth=false){
 const args=['--root',root,'--state-root',state,'--port',String(port),'--token','test','--web',dist];
 if(auth)args.push('--auth-secret','test-edge','--login-url','https://login.invalid');
 const child=spawn(binary,args,{stdio:'ignore'});
 await until(async()=>{try{return(await fetch(`http://127.0.0.1:${port}/`)).ok;}catch{return false;}},'server');
 return async()=>{if(child.exitCode!==null||child.signalCode!==null)return;await new Promise(r=>{child.once('exit',r);child.kill('SIGTERM');});};
}
let browser;
before(async()=>{if(existsSync(chrome))browser=await puppeteer.launch({executablePath:chrome,headless:true,args:['--no-sandbox']});});
after(async()=>{await browser?.close();});
async function pageAt(port,credential){
 const page=await browser.newPage();
 await page.goto(`http://127.0.0.1:${port}/#token=test${credential?'&credential='+encodeURIComponent(credential):''}`);
 await page.waitForFunction(()=>window.demo?.client.ready);return page;
}
async function open(page){await page.evaluate(()=>window.demo.openFile('a.txt'));}
const text=page=>page.$eval('#editor',node=>node.value);
async function offline(page,extra){
 await page.evaluate(()=>{window.demo.client.stopped=true;window.demo.client.socket.close();});
 await until(()=>page.evaluate(()=>!window.demo.client.ready),'offline');
 await page.focus('#editor');await page.keyboard.press('End');await page.keyboard.type(extra);await pause(300);
 assert(await page.evaluate(()=>window.demo.doc.unsent));
}

test('same endpoint and display name cannot import another workspace cache; the original draft still recovers',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort();let stop=await start(f.a,port,f.state),page;
 try{
  page=await pageAt(port);await open(page);assert.equal(await text(page),'alpha');
  const original=await page.evaluate(()=>window.demo.client.workspace);
  await offline(page,' + private draft');await page.close();await stop();
  stop=await start(f.b,port,f.state);page=await pageAt(port);await open(page);
  assert.equal(await text(page),'beta');assert.notEqual(await page.evaluate(()=>window.demo.client.workspace),original);
  assert.equal(readFileSync(join(f.b,'a.txt'),'utf8'),'beta');await page.close();await stop();
  stop=await start(f.a,port,f.state);page=await pageAt(port);await open(page);
  await until(()=>readFileSync(join(f.a,'a.txt'),'utf8')==='alpha + private draft','original recovery');
  assert.equal(await text(page),'alpha + private draft');assert.equal(await page.evaluate(()=>window.demo.client.workspace),original);
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('a live reconnect to a different workspace stops before sending its old CRDT state',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort();let stop=await start(f.a,port,f.state),page;
 try{
  page=await pageAt(port);await open(page);await stop();
  await until(()=>page.evaluate(()=>!window.demo.client.ready),'disconnect');
  await page.focus('#editor');await page.keyboard.press('End');await page.keyboard.type(' + offline');await pause(200);
  stop=await start(f.b,port,f.state);
  await until(()=>page.evaluate(()=>window.demo.client.invalidated?.code==='workspace-changed'),'replacement fence');
  assert.equal(await page.evaluate(()=>window.demo.client.ready),false);assert.equal(await text(page),'alpha + offline');
  await pause(300);assert.equal(readFileSync(join(f.b,'a.txt'),'utf8'),'beta');
  const result=await page.evaluate(()=>window.demo.doc.save().then(()=>null,error=>error.message));assert(result);
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('account caches stay separate while a renamed login with the same account ID recovers its draft',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state,true);let page;
 const credential=(name,id)=>execFileSync(binary,['issue','--auth-secret','test-edge','--login',name,'--id',String(id)],{encoding:'utf8'}).trim();
 try{
  page=await pageAt(port,credential('alice',1));await open(page);await offline(page,' + Alice draft');await page.close();
  page=await pageAt(port,credential('bob',2));await open(page);
  assert.equal(await text(page),'alpha');assert.equal(await page.evaluate(()=>window.demo.client.cacheIdentity.principal),'account:2');await page.close();
  page=await pageAt(port,credential('alice-renamed',1));await open(page);
  await until(()=>readFileSync(join(f.a,'a.txt'),'utf8')==='alpha + Alice draft','renamed account recovery');
  assert.equal(await text(page),'alpha + Alice draft');
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('legacy unscoped IndexedDB data is left intact and never merged automatically',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 try{
  page=await pageAt(port);
  const legacy=await page.evaluate(async()=>{
   const {Y}=await import('/session-client.js'),doc=new Y.Doc();doc.getText('text').insert(0,'legacy draft');
   const name=`rayde:ws://${location.host}/session:project:a.txt`;
   await new Promise((resolve,reject)=>{const req=indexedDB.open(name,1);req.onupgradeneeded=()=>{req.result.createObjectStore('updates',{autoIncrement:true});req.result.createObjectStore('custom');};req.onerror=()=>reject(req.error);req.onsuccess=()=>{const db=req.result,tx=db.transaction('updates','readwrite');tx.objectStore('updates').add(Y.encodeStateAsUpdate(doc));tx.oncomplete=()=>{db.close();resolve();};};});
   doc.destroy();return name;
  });
  await open(page);assert.equal(await text(page),'alpha');assert.equal(readFileSync(join(f.a,'a.txt'),'utf8'),'alpha');
  assert(await page.evaluate(async name=>(await indexedDB.databases()).some(db=>db.name===name),legacy));
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});
