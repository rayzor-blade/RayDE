import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fixture,json} from './fixture.mjs';
const Y=createRequire(resolve('../session/package.json'))('yjs');
const cli=resolve('../../native/sync/target/debug/examples/push'),documentCli=resolve('../../native/sync/target/debug/examples/document');
const post=body=>({method:'POST',body:JSON.stringify(body),headers:{'Content-Type':'application/json'}});
const b64=bytes=>Buffer.from(bytes).toString('base64'),bytes=text=>new Uint8Array(Buffer.from(text,'base64'));
const port=()=>new Promise(done=>{const server=createServer().listen(0,'127.0.0.1',()=>{const p=server.address().port;server.close(()=>done(p));});});
function replica(open){const doc=new Y.Doc();Y.applyUpdate(doc,bytes(open.update));return doc;}
function text(doc){return doc.getText('text').toString();}
async function setup(t,{persist,allocation,capture}={}){
 const base=`http://127.0.0.1:${await port()}`,root=await mkdtemp(join(tmpdir(),'rayde-live-'));
 const create=async()=>{
  const settings={persist,port:Number(new URL(base).port),appOrigin:base,provision:data=>{capture?.push(data);return json({url:'ws://127.0.0.1:1/session',token:'private-compute',project:'a.txt'});}};
  return fixture(settings);
 };
 let host=await create(),stopped=false;
 const api=(path,init={},account='alice')=>host.mf.dispatchFetch(base+'/api/sync'+path,{...init,headers:{'X-Dev-Account':account,...init.headers}});
 const git=(...args)=>{const result=spawnSync('git',['-C',root,'-c','user.name=T','-c','user.email=t@example.invalid','-c','commit.gpgsign=false',...args],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);};
 git('init','-q','-b','main');await writeFile(join(root,'a.txt'),'one 🦀 two');git('add','.');git('commit','-qm','first');
 if(allocation){const made=await(await api('/workspaces',post({allocation}))).json();await writeFile(join(root,'.git','rayde-sync.json'),JSON.stringify({[base]:{workspace:made.id,generation:0}}));}
 const push=()=>{const run=spawnSync(cli,[root,base,'alice'],{encoding:'utf8'});return JSON.parse(run.stdout.trim().split('\n').at(-1));};
 const initial=push();assert.equal(initial.event,'published',JSON.stringify(initial));const id=initial.url.split('/').pop();
 t.after(async()=>{if(!stopped)await host.mf.dispose();await rm(root,{recursive:true,force:true});});
 const call=async(op,body,account)=>{const response=await api(`/workspaces/${id}/documents/${op}`,post(body),account);return{status:response.status,...await response.json()};};
 const open=async(generation=1)=>{const reply=await call('open',{path:'a.txt',generation});assert.equal(reply.status,200,JSON.stringify(reply));return reply;};
 const exchange=(opened,doc,from=opened.vector)=>call('exchange',{path:'a.txt',lineage:opened.lineage,from,update:b64(Y.encodeStateAsUpdate(doc,bytes(from)))});
 const stop=async()=>{if(!stopped){stopped=true;await host.mf.dispose();}};
 const restart=async()=>{await stop();host=await create();stopped=false;};
 return {base,root,id,api,push,open,call,exchange,restart,stop};
}

test('independent clients exchange concurrent Unicode edits and deletion-only updates exactly once',async t=>{
 const w=await setup(t),one=await w.open(),two=await w.open();assert.equal(one.lineage,two.lineage);
 const a=replica(one),b=replica(two);a.getText('text').insert(0,'A ');b.getText('text').insert(10,' B');
 const first=await w.exchange(one,a);assert.equal(first.status,200,JSON.stringify(first));
 const merged=await w.exchange(two,b);assert.equal(merged.status,200,JSON.stringify(merged));
 for(const doc of[a,b])Y.applyUpdate(doc,bytes(merged.update));assert.equal(text(a),'A one 🦀 two B');assert.equal(text(b),text(a));
 const retry=await w.exchange(two,b);assert.equal(retry.sequence,merged.sequence,'lost replies can be retried without appending another journal segment');
 const opened=await w.open(),client=replica(opened);client.getText('text').delete(0,2);
 const deleted=await w.exchange(opened,client);assert.deepEqual(Y.decodeStateVector(bytes(deleted.vector)),Y.decodeStateVector(bytes(opened.vector)),'a deletion does not advance the state vector');assert.ok(deleted.sequence>opened.sequence);
 const caught=replica(await w.open());assert.equal(text(caught),'one 🦀 two B');
});

test('missing dependencies, forged lineage, other accounts and malformed updates cannot change a head',async t=>{
 const w=await setup(t),opened=await w.open(),client=replica(opened);
 client.getText('text').insert(0,'first');const before=Y.encodeStateVector(client);client.getText('text').insert(0,'second');
 const missing=await w.call('exchange',{path:'a.txt',lineage:opened.lineage,from:opened.vector,update:b64(Y.encodeStateAsUpdate(client,before))});assert.equal(missing.status,409);
 assert.equal((await w.call('exchange',{path:'a.txt',lineage:'wrong',from:opened.vector,update:b64(new Uint8Array([0,0]))})).status,409);
 assert.equal((await w.call('exchange',{path:'a.txt',lineage:opened.lineage,from:opened.vector,update:'%%%'})).status,422);
 assert.equal((await w.call('open',{path:'a.txt',generation:1},'bob')).status,404);
 assert.equal((await w.call('open',{path:'../a.txt',generation:1})).status,400);
 assert.equal((await w.open()).sequence,opened.sequence);assert.equal(text(replica(await w.open())),'one 🦀 two');
 const native=spawnSync(documentCli,[w.base,'alice',w.id,'a.txt',' (Rust)'],{encoding:'utf8'});assert.equal(native.status,0,native.stderr);assert.equal(JSON.parse(native.stdout).text,'one 🦀 two (Rust)');
});

test('snapshot publication preserves pending heads, refuses overwrite, and keeps lineage when shared text is integrated',async t=>{
 const w=await setup(t),opened=await w.open(),client=replica(opened);client.getText('text').insert(0,'live ');
 assert.equal((await w.exchange(opened,client)).status,200);
 assert.equal(w.push().generation,2,'publishing unchanged files keeps the pending shared head');assert.equal((await w.open(2)).lineage,opened.lineage);
 await writeFile(join(w.root,'a.txt'),'overwrite');const refused=w.push();assert.equal(refused.event,'error',JSON.stringify(refused));assert.equal(refused.code,'conflict');
 assert.equal((await(await w.api(`/workspaces/${w.id}`)).json()).generation,2);
 await writeFile(join(w.root,'a.txt'),text(client));assert.equal(w.push().generation,3);assert.equal((await w.open(3)).lineage,opened.lineage);
 await rm(join(w.root,'a.txt'));assert.equal(w.push().generation,4);
 await writeFile(join(w.root,'a.txt'),text(client));assert.equal(w.push().generation,5);
 const fresh=await w.open(5);assert.notEqual(fresh.lineage,opened.lineage,'recreating a path allocates another lineage, even with identical text');
 assert.equal((await w.exchange(opened,client)).status,409);
});

test('incremental journals compact and recover through a fresh gateway instance',async t=>{
 const persist=await mkdtemp(join(tmpdir(),'rayde-live-state-'));t.after(()=>rm(persist,{recursive:true,force:true}));
 const w=await setup(t,{persist});let opened=await w.open();const client=replica(opened);
 for(let i=0;i<68;i++){client.getText('text').insert(client.getText('text').length,String(i%10));const reply=await w.exchange(opened,client);assert.equal(reply.status,200,JSON.stringify(reply));Y.applyUpdate(client,bytes(reply.update));opened=reply;}
 const expected=text(client),sequence=opened.sequence;await w.restart();const restored=await w.open();assert.equal(restored.sequence,sequence);assert.equal(text(replica(restored)),expected);
 client.getText('text').insert(0,'after restart ');assert.equal((await w.exchange(opened,client)).status,200);
});

test('history quota refusal preserves the acknowledged head and usage',async t=>{
 const w=await setup(t,{allocation:1000}),opened=await w.open(),client=replica(opened);
 const status=await(await w.api(`/workspaces/${w.id}`)).json();assert.ok(status.usage.documents>0);
 client.getText('text').insert(0,'x'.repeat(1500));assert.equal((await w.exchange(opened,client)).status,413);
 const after=await w.open();assert.equal(after.sequence,opened.sequence);assert.equal(text(replica(after)),'one 🦀 two');
 assert.equal((await(await w.api(`/workspaces/${w.id}`)).json()).usage.documents,status.usage.documents);
});

test('a publish capability exchanges only its own workspace and never opens another workspace',async t=>{
 const capture=[],w=await setup(t,{capture});assert.equal((await w.api(`/workspaces/${w.id}/open`,{method:'POST'})).status,200);
 for(let i=0;i<100&&!capture.length;i++)await new Promise(r=>setTimeout(r,20));const token=capture[0].publish.token;
 const response=await w.api(`/workspaces/${w.id}/documents/open`,{...post({path:'a.txt',generation:1}),headers:{Authorization:'Bearer '+token}});assert.equal(response.status,200);
 const other=await(await w.api('/workspaces',post({}))).json();const refused=await w.api(`/workspaces/${other.id}/documents/open`,{...post({path:'a.txt',generation:1}),headers:{Authorization:'Bearer '+token}});assert.equal(refused.status,403);
});

// Faults are injected only after the local Worker releases its private SQLite database.
function fault(persist,action){
 const run=spawnSync('python3',['-c',`import sqlite3, pathlib, sys
for file in pathlib.Path(sys.argv[1]).rglob('*.sqlite'):
 if 'SyncWorkspaceSession' not in str(file): continue
 db=sqlite3.connect(file)
 if not db.execute("SELECT name FROM sqlite_master WHERE name='_cf_KV'").fetchone(): continue
 row=db.execute("SELECT key,value FROM _cf_KV WHERE key LIKE 'sync-document-data:%' LIMIT 1").fetchone()
 if not row: continue
 mode=sys.argv[2]
 if mode=='corrupt':
  db.execute('CREATE TABLE rayde_test_backup(key TEXT PRIMARY KEY,value BLOB)')
  db.execute('INSERT INTO rayde_test_backup VALUES(?,?)',row)
  value=bytearray(row[1]);value[-1]^=1
  db.execute('UPDATE _cf_KV SET value=? WHERE key=?',(bytes(value),row[0]))
 elif mode=='restore':
  saved=db.execute('SELECT key,value FROM rayde_test_backup').fetchone()
  db.execute('UPDATE _cf_KV SET value=? WHERE key=?',(saved[1],saved[0]))
  db.execute('DROP TABLE rayde_test_backup')
 elif mode=='fail':
  db.execute("CREATE TRIGGER rayde_test_abort BEFORE INSERT ON _cf_KV WHEN NEW.key='sync-documents:v1' BEGIN SELECT RAISE(ABORT,'fixture unavailable'); END")
 elif mode=='clear': db.execute('DROP TRIGGER rayde_test_abort')
 db.commit();break
else: raise RuntimeError('No shared history storage was found')
`,persist,action],{encoding:'utf8'});
 assert.equal(run.status,0,run.stderr);
}

test('corrupt journal data pauses exchange and never replaces its acknowledged head',async t=>{
 const persist=await mkdtemp(join(tmpdir(),'rayde-live-corrupt-'));t.after(()=>rm(persist,{recursive:true,force:true}));
 const w=await setup(t,{persist}),opened=await w.open(),client=replica(opened);client.getText('text').insert(0,'kept ');
 const confirmed=await w.exchange(opened,client);assert.equal(confirmed.status,200);
 await w.stop();fault(persist,'corrupt');await w.restart();
 assert.equal((await w.call('open',{path:'a.txt',generation:1})).status,503);assert.equal((await w.exchange(opened,client)).status,503);
 await w.stop();fault(persist,'restore');await w.restart();
 const restored=await w.open();assert.equal(restored.sequence,confirmed.sequence);assert.equal(text(replica(restored)),'kept one 🦀 two');
});

test('a failed journal commit keeps the previous graph, sequence and quota',async t=>{
 const persist=await mkdtemp(join(tmpdir(),'rayde-live-fail-'));t.after(()=>rm(persist,{recursive:true,force:true}));
 const w=await setup(t,{persist}),opened=await w.open(),client=replica(opened);client.getText('text').insert(0,'not committed ');
 const usage=(await(await w.api(`/workspaces/${w.id}`)).json()).usage.documents;
 await w.stop();fault(persist,'fail');await w.restart();assert.equal((await w.exchange(opened,client)).status,503);
 await w.stop();fault(persist,'clear');await w.restart();
 const restored=await w.open();assert.equal(restored.sequence,opened.sequence);assert.equal(text(replica(restored)),'one 🦀 two');
 assert.equal((await(await w.api(`/workspaces/${w.id}`)).json()).usage.documents,usage);
 assert.equal((await w.exchange(opened,client)).status,200,'a failed commit can be retried after storage recovers');
});
