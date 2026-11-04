// Yjs/Yrs protocol interoperability only; no browser process is launched.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import * as Y from 'yjs';
import {DemoSource} from '../src/demo-seed.js';
import {SessionClient} from '../src/client.js';

function bundle(){
 const contents={'build.hxml':'-main Main\n','src/hello.txt':'Hello 🌍\r\n','empty.txt':'','bom.txt':'\ufeffText','binary.bin':Buffer.from([255,0,254])};
 const entries=[{path:'/work/pocket-studio',directory:true},{path:'/work/pocket-studio/src',directory:true},
  ...Object.entries(contents).map(([path,text])=>({path:'/work/pocket-studio/'+path,directory:false,data:Buffer.from(text).toString('base64')}))];
 return {contents,bytes:new TextEncoder().encode(JSON.stringify({version:1,name:'Pocket Studio',root:'/work/pocket-studio',project:'pocket-studio/build.hxml',entries}))};
}
function replica(update){const doc=new Y.Doc();Y.applyUpdate(doc,update);return doc;}
const encode=bytes=>Buffer.from(bytes).toString('base64');

test('public source graphs are release-bound, preserve UTF-16 text and contain no visitor edits',async()=>{
 const {bytes,contents}=bundle(),source=await DemoSource.read(bytes);
 await assert.rejects(DemoSource.read(bytes,'0'.repeat(64)),/release/);
 assert.equal(source.graph('../build.hxml'),null);assert.equal(source.graph('binary.bin'),null);
 for(const [path,text]of Object.entries(contents)){
  if(typeof text!=='string')continue;
  const one=replica(source.graph(path)),two=replica(source.graph(path));
  assert.equal(one.getText('text').toString(),text);assert.notEqual(one.clientID,0);
  one.getText('text').insert(0,'private:');Y.applyUpdate(two,source.graph(path));
  assert.equal(two.getText('text').toString(),text);one.destroy();two.destroy();
 }
});

test('browser edits made before admission merge with native edits without replacing either history',async t=>{
 const root=await mkdtemp(join(tmpdir(),'rayde-demo-graph-'));let process,client;
 t.after(async()=>{client?.close();if(process&&process.exitCode===null&&process.signalCode===null){const exited=once(process,'exit');process.kill('SIGINT');await exited;}await rm(root,{recursive:true,force:true});});
 const {bytes,contents}=bundle(),source=await DemoSource.read(bytes),project=join(root,'project'),seed=join(root,'demo.json');
 await mkdir(join(project,'src'),{recursive:true});await writeFile(seed,bytes);
 for(const [path,text]of Object.entries(contents))await writeFile(join(project,path),text);
 // A workspace program may update disk before the first editor buffer opens.
 await writeFile(join(project,'src/hello.txt'),contents['src/hello.txt']+'native');
 const browser=replica(source.graph('src/hello.txt'));t.after(()=>browser.destroy());
 browser.getText('text').insert(0,'browser: ');
 async function start(release=source.release){
  process=spawn(fileURLToPath(new URL('../../../native/session/target/release/rayde-session',import.meta.url)),[
   '--root',project,'--state-root',join(root,'state'),'--port','0','--token','test-demo-graph',
   '--demo-seed',seed,'--demo-release',release
  ],{stdio:['ignore','pipe','pipe']});
  const url=await new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>reject(Error('Native session did not start')),10000);let output='',failure='';
   process.stderr.on('data',bytes=>failure+=bytes.toString());
   process.stdout.on('data',bytes=>{output+=bytes.toString();const match=output.match(/http:\/\/127\.0\.0\.1:\d+/);if(match){clearTimeout(timer);resolve(match[0]);}});
   process.once('exit',()=>{clearTimeout(timer);reject(Error('Native demo session exited: '+failure));});
  });
  client=new SessionClient({url:url.replace('http:','ws:')+'/session',token:'test-demo-graph',persist:false,reconnect:false});
  await client.connect();assert.deepEqual(client.hello.demoSeed,{version:1,release:source.release});
 }
 await start();
 const native=await client.openDoc('src/hello.txt');
 assert.equal(native.text.toString(),contents['src/hello.txt']+'native');
 const reply=await client.request('doc.update',{path:'src/hello.txt',update:encode(Y.encodeStateAsUpdate(browser))});
 assert.equal(reply.ok,true);await native.sync();
 assert.equal(native.text.toString(),'browser: '+contents['src/hello.txt']+'native');
 Y.applyUpdate(browser,Y.encodeStateAsUpdate(native.ydoc));assert.equal(browser.getText('text').toString(),native.text.toString());
 // Repeated seeding and reconnecting must not duplicate text or reset saved history.
 for(const [path,text]of Object.entries(contents))if(typeof text==='string'&&path!=='src/hello.txt'){
  const doc=await client.openDoc(path),local=replica(source.graph(path));
  Y.applyUpdate(local,Y.encodeStateAsUpdate(doc.ydoc));assert.equal(local.getText('text').toString(),text);local.destroy();
 }
 await native.save();client.close();const exited=once(process,'exit');process.kill('SIGINT');await exited;
 await start();const restored=await client.openDoc('src/hello.txt');
 assert.equal(restored.text.toString(),browser.getText('text').toString());
 Y.applyUpdate(browser,Y.encodeStateAsUpdate(restored.ydoc));assert.equal(browser.getText('text').toString(),restored.text.toString());
 client.close();const stopped=once(process,'exit');process.kill('SIGINT');await stopped;
 const changed=JSON.parse(new TextDecoder().decode(bytes));changed.entries.at(-1).data=Buffer.from('different release').toString('base64');
 const nextBytes=new TextEncoder().encode(JSON.stringify(changed)),next=await DemoSource.read(nextBytes);await writeFile(seed,nextBytes);
 await assert.rejects(start(next.release),/does not match.*document history/);
});
