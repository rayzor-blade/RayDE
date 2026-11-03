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

async function legacyDraft(page, suffix, removeIdentityCache = false) {
 return page.evaluate(async ({suffix,removeIdentityCache})=>{
  const {Y}=await import('/session-client.js'),source=window.demo.doc,doc=new Y.Doc();
  Y.applyUpdate(doc,Y.encodeStateAsUpdate(source.ydoc));doc.getText('text').insert(doc.getText('text').length,suffix);
  const name=`rayde:v2:${JSON.stringify([source.workspace,source.path])}`,id=source.documentId;
  await new Promise((resolve,reject)=>{
   const request=indexedDB.open(name);
   request.onupgradeneeded=()=>{request.result.createObjectStore('updates',{autoIncrement:true});request.result.createObjectStore('custom');};
   request.onerror=()=>reject(request.error);
   request.onsuccess=()=>{const db=request.result,tx=db.transaction('updates','readwrite');tx.objectStore('updates').add(Y.encodeStateAsUpdate(doc));tx.oncomplete=()=>{db.close();resolve();};tx.onerror=()=>reject(tx.error);};
  });doc.destroy();
  if(removeIdentityCache){await source.close();await new Promise((resolve,reject)=>{const req=indexedDB.deleteDatabase(`rayde:v3:${JSON.stringify([source.workspace,id])}`);req.onsuccess=resolve;req.onerror=()=>reject(req.error);});}
  return {name,id};
 },{suffix,removeIdentityCache});
}

async function databaseValue(page,name,store,key){
 return page.evaluate(async({name,store,key})=>new Promise((resolve,reject)=>{
  const req=indexedDB.open(name);req.onerror=()=>reject(req.error);req.onsuccess=()=>{const db=req.result,tx=db.transaction(store,'readonly'),value=tx.objectStore(store).get(key);tx.oncomplete=()=>{db.close();resolve(value.result);};tx.onerror=()=>reject(tx.error);};
 }),{name,store,key});
}

test('a closed offline draft follows a directory move while a recreated old path gets its own graph',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort();let stop=await start(f.a,port,f.state),page;
 try{
  page=await pageAt(port);await page.evaluate(async()=>{await window.demo.client.mkdir('src');await window.demo.client.rename('a.txt','src/a.txt');await window.demo.openFile('src/a.txt');});
  const id=await page.evaluate(()=>window.demo.doc.documentId);
  assert.match(id,/^[a-f0-9]{64}$/);
  await offline(page,' + offline draft');await page.evaluate(()=>window.demo.doc.checkpoint());await page.close();await stop();
  stop=await start(f.a,port,f.state);page=await pageAt(port);
  await page.evaluate(async()=>{
   const client=window.demo.client;
   await client.request('fs.rename',{from:'src',to:'moved',preserveDocuments:true});
   await client.mkdir('src');await client.write('src/a.txt','different file');
   await window.demo.openFile('moved/a.txt');
  });
  assert.equal(await text(page),'alpha + offline draft');assert.equal(await page.evaluate(()=>window.demo.doc.documentId),id);
  await page.evaluate(()=>window.demo.openFile('src/a.txt'));
  assert.equal(await text(page),'different file');assert.notEqual(await page.evaluate(()=>window.demo.doc.documentId),id);
  await page.evaluate(()=>window.demo.openFile('moved/a.txt'));
  assert.equal(await text(page),'alpha + offline draft');
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('legacy path recovery migrates durably and follows late updates after a move',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort();let stop=await start(f.a,port,f.state),page;
 try{
  page=await pageAt(port);await open(page);
  const {name,id}=await legacyDraft(page,' + legacy',true);
  await open(page);assert.equal(await text(page),'alpha + legacy');
  const receipt=await databaseValue(page,name,'custom','rayde:binding');
  assert.equal(receipt.id,id);assert(receipt.copied>0);
  await legacyDraft(page,' + older browser tab');await page.evaluate(()=>window.demo.doc.close());
  await page.evaluate(async()=>{await window.demo.client.request('fs.rename',{from:'a.txt',to:'renamed.txt',preserveDocuments:true});await window.demo.openFile('renamed.txt');});
  assert.equal(await text(page),'alpha + legacy + older browser tab');assert.equal(await page.evaluate(()=>window.demo.doc.documentId),id);
  assert((await databaseValue(page,name,'custom','rayde:binding')).copied>receipt.copied);
  assert(await page.evaluate(async name=>(await indexedDB.databases()).some(db=>db.name===name),name));
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('a returning live replica is fenced before sending offline edits into a recreated path',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort();let stop=await start(f.a,port,f.state),page,control;
 try{
  page=await pageAt(port);await open(page);await offline(page,' + private');
  await page.evaluate(()=>window.demo.client.on('document-error',error=>window.documentFailure=error));
  await stop();stop=await start(f.a,port,f.state);control=await pageAt(port);
  await control.evaluate(async()=>{await window.demo.client.request('fs.rename',{from:'a.txt',to:'moved.txt',preserveDocuments:true});await window.demo.client.write('a.txt','replacement');});
  await page.evaluate(async()=>{window.demo.client.stopped=false;await window.demo.client.connect();});
  assert.equal(await page.evaluate(()=>window.documentFailure?.code),'document-changed');
  assert.equal(await text(page),'alpha + private');
  assert.equal(readFileSync(join(f.a,'a.txt'),'utf8'),'replacement');
  await assert.rejects(page.evaluate(()=>window.demo.doc.save()),/different document/);
  assert(await page.evaluate(()=>window.demo.doc.unsent));
 }finally{await page?.close().catch(()=>{});await control?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('unbound legacy graphs cannot attach to a reused path and remain available for recovery',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 try{
  page=await pageAt(port);await open(page);const {name}=await legacyDraft(page,' + private legacy',true);
  await page.evaluate(async()=>{await window.demo.client.request('fs.rename',{from:'a.txt',to:'moved.txt',preserveDocuments:true});await window.demo.client.write('a.txt','replacement');});
  await assert.rejects(open(page),/identity/);
  assert.equal(readFileSync(join(f.a,'a.txt'),'utf8'),'replacement');
  assert.equal(await databaseValue(page,name,'custom','rayde:binding'),undefined);
  assert(await page.evaluate(async name=>(await indexedDB.databases()).some(db=>db.name===name),name));
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('a verified document can reopen offline and reconnect without publishing during cache replay',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 try{
  page=await pageAt(port);await open(page);
  await offline(page,' + offline');
  await page.evaluate(async()=>{await window.demo.doc.checkpoint();await window.demo.doc.close();await window.demo.openFile('a.txt');});
  assert.equal(await text(page),'alpha + offline');assert(await page.evaluate(()=>window.demo.doc.unsent));
  await page.evaluate(async()=>{const client=window.demo.client,request=client.request.bind(client);window.sentUpdates=[];client.request=(op,params)=>{if(op==='doc.update')window.sentUpdates.push(params);return request(op,params);};client.stopped=false;await client.connect();});
  await until(()=>readFileSync(join(f.a,'a.txt'),'utf8')==='alpha + offline','offline reopen catchup');
  assert(await page.evaluate(()=>window.sentUpdates.length>0&&window.sentUpdates.every(p=>p.documentId===window.demo.doc.documentId)));
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('an interrupted migration preserves both graphs and retries without marking uncopied legacy state',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 try{
  page=await pageAt(port);await open(page);const {name,id}=await legacyDraft(page,' + recover me',true);
  await page.evaluate(()=>{const directory=window.demo.client.recoveryDirectory;window.putRecovery=directory.put.bind(directory);directory.put=async()=>{throw Object.assign(Error('storage interrupted'),{code:'recovery-failed'});};});
  await assert.rejects(open(page),/storage interrupted/);
  assert.equal(await databaseValue(page,name,'custom','rayde:binding'),undefined);
  assert.equal(readFileSync(join(f.a,'a.txt'),'utf8'),'alpha','replaying cache cannot publish edits before the recovery barrier');
  await page.evaluate(()=>{window.demo.client.recoveryDirectory.put=window.putRecovery;});
  await open(page);assert.equal(await text(page),'alpha + recover me');
  assert.equal((await databaseValue(page,name,'custom','rayde:binding')).id,id);
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('sign-in never copies account-only recovery back into the viewer cache',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state,true);let page;
 try{
  const credential=execFileSync(binary,['issue','--auth-secret','test-edge','--login','alice','--id','1'],{encoding:'utf8'}).trim();
  page=await pageAt(port,credential);await open(page);await offline(page,' + account private');
  await page.evaluate(()=>window.demo.doc.checkpoint());await page.close();
  page=await pageAt(port);await open(page);assert.equal(await text(page),'alpha');
  const viewer=await page.evaluate(()=>`rayde:v3:${JSON.stringify([window.demo.doc.workspace,window.demo.doc.documentId])}`);
  await page.evaluate(credential=>window.demo.client.login(credential),credential);
  assert.equal(await text(page),'alpha + account private');
  const cached=await page.evaluate(async name=>{
   const {Y}=await import('/session-client.js'),doc=new Y.Doc();
   await new Promise((resolve,reject)=>{const req=indexedDB.open(name);req.onerror=()=>reject(req.error);req.onsuccess=()=>{const db=req.result,tx=db.transaction('updates','readonly'),rows=tx.objectStore('updates').getAll();tx.oncomplete=()=>{for(const row of rows.result)Y.applyUpdate(doc,row);db.close();resolve();};tx.onerror=()=>reject(tx.error);};});
   const value=doc.getText('text').toString();doc.destroy();return value;
  },viewer);
  assert.equal(cached,'alpha');
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('native live directory moves preserve replicas, local undo, cached drafts and later saves',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 try{
  page=await pageAt(port);
  await page.evaluate(async()=>{const client=window.demo.client;await client.mkdir('src');await client.rename('a.txt','src/a.txt');await client.write('src/b.txt','beta');});
  const result=await page.evaluate(async()=>{
   const {Y,SessionClient}=await import('/session-client.js'),client=new SessionClient({url:window.demo.client.options.url,token:'test'});
   await client.connect();const doc=await client.openDoc('src/a.txt'),other=await client.openDoc('src/b.txt');
   const undo=new Y.UndoManager(doc.text,{trackedOrigins:new Set(['editor']),captureTimeout:0}),id=doc.documentId;
   doc.ydoc.transact(()=>doc.text.insert(doc.text.length,' + local'),'editor');
   await client.rename('src','destination');
   const same=client.docs.get('destination/a.txt')===doc&&client.docs.get('destination/b.txt')===other;
   undo.undo();const undone=doc.text.toString();undo.redo();await doc.save();await doc.checkpoint();
   const result={same,id,after:doc.documentId,path:doc.path,undone,text:doc.text.toString()};
   undo.destroy();await doc.close();await other.close();client.close();return result;
  });
  assert.equal(result.same,true);assert.equal(result.id,result.after);assert.equal(result.path,'destination/a.txt');assert.equal(result.undone,'alpha');
  assert.equal(result.text,'alpha + local');assert.equal(readFileSync(join(f.a,'destination/a.txt'),'utf8'),'alpha + local');
  await page.evaluate(async()=>{await window.demo.client.mkdir('src');await window.demo.client.write('src/a.txt','new source');await window.demo.openFile('src/a.txt');});
  assert.equal(await text(page),'new source');
  await page.evaluate(()=>window.demo.openFile('destination/a.txt'));assert.equal(await text(page),'alpha + local');
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('another native subscriber refuses a live move without losing queued edits or the original binding',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page,peer;
 try{
  page=await pageAt(port);peer=await pageAt(port);await open(page);await open(peer);
  await assert.rejects(page.evaluate(()=>window.demo.client.rename('a.txt','moved.txt')),/Close shared documents/);
  assert(await page.evaluate(()=>window.demo.client.docs.get('a.txt')===window.demo.doc&&!window.demo.doc.blocked));
  await page.focus('#editor');await page.keyboard.press('End');await page.keyboard.type(' + kept');
  await until(()=>readFileSync(join(f.a,'a.txt'),'utf8')==='alpha + kept','typing after refused move');
  assert.equal(existsSync(join(f.a,'moved.txt')),false);await until(async()=>await text(peer)==='alpha + kept','peer projection');
  await peer.evaluate(()=>window.demo.doc.close());
  await page.evaluate(()=>window.demo.client.rename('a.txt','moved.txt'));
  assert.equal(await page.evaluate(()=>window.demo.doc.path),'moved.txt');assert.equal(await text(page),'alpha + kept');
 }finally{await page?.close().catch(()=>{});await peer?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('a live move retains a recovered dirty graph over its saved disk baseline until explicit Save',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 try{
  page=await pageAt(port);
  const result=await page.evaluate(async()=>{
   const {Y,SessionClient}=await import('/session-client.js'),client=new SessionClient({url:window.demo.client.options.url,token:'test'});
   await client.connect();const original=await client.openDoc('a.txt'),draft=new Y.Doc();Y.applyUpdate(draft,Y.encodeStateAsUpdate(original.ydoc));
   draft.getText('text').insert(5,' + unsaved');const update=Y.encodeStateAsUpdate(draft),baseline=new TextEncoder().encode('alpha');
   const hash=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
   const checkpoint={version:1,update:btoa(String.fromCharCode(...update)),sha256:await hash(update)},diskSha256=await hash(baseline);
   await original.close();draft.destroy();await client.request('doc.restore',{path:'a.txt',mode:'buffer',checkpoint,diskSha256});
   const doc=await client.openDoc('a.txt'),id=doc.documentId;await client.rename('a.txt','moved.txt');
   const saved=await client.read('moved.txt'),result={id,after:doc.documentId,dirty:doc.restoredDirty,text:doc.text.toString(),saved};
   await doc.save();await doc.close();client.close();return result;
  });
  assert.equal(result.id,result.after);assert.equal(result.dirty,true);assert.equal(result.text,'alpha + unsaved');assert.equal(result.saved,'alpha');
  assert.equal(readFileSync(join(f.a,'moved.txt'),'utf8'),'alpha + unsaved');
 }finally{await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

// The mock transport supplies a fixed seed; recovery uses real IndexedDB across a page reload.
for(const identified of [false,true])test(`cloud lineage and offline graph recover together while unbound history stays fenced (${identified?'identified':'hosted'})`,{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 const Y=await import('yjs'),seed=new Y.Doc();seed.clientID=0;seed.getText('text').insert(0,'cloud seed');
 const offer={documentId:'d'.repeat(64),cloudLineage:'e'.repeat(64),update:Buffer.from(Y.encodeStateAsUpdate(seed)).toString('base64'),vector:Buffer.from(Y.encodeStateVector(seed)).toString('base64'),buffered:true};
 const workspace='cloud-persistence-'+crypto.randomUUID();
 try{
  page=await pageAt(port);
  await page.evaluate(async({offer,workspace,identified})=>{
   const {SessionClient}=await import('/session-client.js');const client=new SessionClient({url:location.origin.replace('http:','ws:')+'/session',persist:true});
   client.ready=client.cacheable=true;client.workspace=workspace;client.hello={documentIdentities:identified?1:0,cloudDocuments:1};client.request=async op=>op==='doc.open'?offer:{};
   const doc=await client.openDoc('cloud.txt');client.ready=false;doc.text.insert(doc.text.length,' + offline');await doc.checkpoint();await doc.close();client.close();
  },{offer,workspace,identified});
  await page.reload();await page.waitForFunction(()=>window.demo?.client.ready);
  const recovered=await page.evaluate(async({offer,workspace,identified})=>{
   const {SessionClient,Doc}=await import('/session-client.js');
   const make=()=>{const client=new SessionClient({url:location.origin.replace('http:','ws:')+'/session',persist:true});client.ready=client.cacheable=true;client.workspace=workspace;client.hello={documentIdentities:identified?1:0,cloudDocuments:1};client.request=async op=>op==='doc.open'?offer:{};return client;};
   const client=make(),doc=await client.openDoc('cloud.txt'),text=doc.text.toString();
   const cloud=await doc.persistence.get('rayde:cloud-lineage');
   await new Promise((resolve,reject)=>{const tx=doc.persistence.db.transaction('custom','readwrite');tx.objectStore('custom').delete('rayde:cloud-lineage');tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});
   await doc.close();client.close();
   const again=make();let code;try{await again.openDoc('cloud.txt');}catch(error){code=error.code;}
   again.ready=false;const kept=new Doc(again,'cloud.txt');kept.identify(offer.documentId);await kept.recover(identified?`rayde:v3:${JSON.stringify([workspace,offer.documentId])}`:`rayde:v2:${JSON.stringify([workspace,"cloud.txt"])}`);const preserved=kept.text.toString();await kept.close();again.close();
   return{text,cloud,code,preserved};
  },{offer,workspace,identified});
  assert.equal(recovered.text,'cloud seed + offline');assert.equal(recovered.cloud.lineage,offer.cloudLineage);assert.equal(recovered.code,'document-lineage');assert.equal(recovered.preserved,recovered.text);
 }finally{seed.destroy();await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});

test('a cloud replica checks account recovery before importing an unbound graph',{skip:!existsSync(chrome)},async()=>{
 const f=fixture(),port=await freePort(),stop=await start(f.a,port,f.state);let page;
 const Y=await import('yjs'),seed=new Y.Doc();seed.clientID=0;seed.getText('text').insert(0,'cloud seed');
 const offer={documentId:'d'.repeat(64),cloudLineage:'e'.repeat(64),update:Buffer.from(Y.encodeStateAsUpdate(seed)).toString('base64'),vector:Buffer.from(Y.encodeStateVector(seed)).toString('base64'),buffered:true};
 try{
  page=await pageAt(port);
  const result=await page.evaluate(async offer=>{
   const {SessionClient,Doc}=await import('/session-client.js'),scope=crypto.randomUUID();
   const make=workspace=>{const client=new SessionClient({url:location.origin.replace('http:','ws:')+'/session',persist:true});client.ready=client.cacheable=true;client.workspace=workspace;client.hello={documentIdentities:1,cloudDocuments:1};client.request=async op=>op==='doc.open'?offer:{};return client;};
   const viewer=make(scope+'-viewer'),doc=await viewer.openDoc('cloud.txt');viewer.ready=false;
   doc.text.insert(doc.text.length,' + private');await doc.checkpoint();
   const account=make(scope+'-account');account.ready=false;const foreign=new Doc(account,'cloud.txt');foreign.identify(offer.documentId);
   const name=`rayde:v3:${JSON.stringify([account.workspace,offer.documentId])}`;
   await foreign.recover(name);foreign.text.insert(0,'unbound account draft');await foreign.checkpointGraph();await foreign.close();
   viewer.workspace=account.workspace;let code;try{await doc.moveRecovery();}catch(error){code=error.code;}
   const active=doc.text.toString();await doc.close();viewer.close();
   const kept=new Doc(account,'cloud.txt');kept.identify(offer.documentId);await kept.recover(name);
   const preserved=kept.text.toString(),tag=await kept.persistence.get('rayde:cloud-lineage');await kept.close();account.close();return{code,active,preserved,tag};
  },offer);
  assert.equal(result.code,'document-lineage');assert.equal(result.active,'cloud seed + private');
  assert.equal(result.preserved,'unbound account draft');assert.equal(result.tag,undefined);
 }finally{seed.destroy();await page?.close().catch(()=>{});await stop();rmSync(f.base,{recursive:true,force:true});}
});
