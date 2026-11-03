import test from 'node:test';
import assert from 'node:assert/strict';
import {TreeCache} from '../src/tree-cache.js';

const file=name=>({name,kind:'file',size:1,mtime:10});
const defer=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
function setup({rows=new Map(),workspace='owner/workspace',root='/work',source='/deps/lib'}={}) {
  const handlers=new Map(),calls=[],saved=[];let time=100000;
  const client={workspace,ready:true,cacheable:true,options:{},hello:{root,readRoots:[{id:'lib',path:source}]},
    on(event,fn){if(!handlers.has(event))handlers.set(event,new Set());handlers.get(event).add(fn);return ()=>handlers.get(event).delete(fn);},
    emit(event,value){handlers.get(event)?.forEach(fn=>fn(value));},
    async request(op,params){calls.push({op,...params});return {entries:[file('one.hx')]};}};
  const storage={async get(key){return structuredClone(rows.get(key));},async put(row){saved.push(row);rows.set(row.key,structuredClone(row));},close(){}};
  let changes=0;
  const cache=new TreeCache(client,{storage,changed:()=>changes++,now:()=>time});
  return {cache,client,calls,rows,saved,advance:amount=>time+=amount,changes:()=>changes};
}

test('visited directories are local and concurrent cold reads share one request',async()=>{
  const {cache,calls}=setup();
  const results=await Promise.all([cache.list({path:'src'}),cache.list({path:'src'})]);
  assert.equal(calls.length,1);assert.equal(calls[0].op,'fs.list');
  results[0].entries[0].name='mutated';
  for(let i=0;i<100;i++)assert.equal((await cache.list({path:'src'})).entries[0].name,'one.hx');
  assert.equal(calls.length,1);cache.close();
});
test('stale metadata renders immediately while a single background refresh updates it',async()=>{
  const s=setup();await s.cache.list({path:'src'});s.advance(16000);
  const pending=defer();s.client.request=()=>{s.calls.push('refresh');return pending.promise;};
  assert.equal((await s.cache.list({path:'src'})).entries[0].name,'one.hx');
  await s.cache.list({path:'src'});assert.equal(s.calls.length,2);
  pending.resolve({entries:[file('two.hx')]});await flush();
  assert.equal((await s.cache.list({path:'src'})).entries[0].name,'two.hx');assert.equal(s.changes(),1);s.cache.close();
});
test('browser recovery is immediate and isolated by workspace, account, root and dependency mount',async()=>{
  const first=setup();await first.cache.list({path:'src'});await first.cache.list({path:'',mount:'lib'});first.cache.close();
  const next=setup({rows:first.rows}),pending=defer();next.client.request=()=>pending.promise;
  assert.equal((await next.cache.list({path:'src'})).entries[0].name,'one.hx');
  for(const options of [{workspace:'other/workspace'},{root:'/replacement'},{source:'/deps/new-version'}]) {
    const isolated=setup({rows:first.rows,...options});
    isolated.client.request=async()=>{isolated.calls.push('remote');return {entries:[file('new.hx')]};};
    const reply=await isolated.cache.list(options.source ? {path:'',mount:'lib'} : {path:'src'});
    assert.equal(reply.entries[0].name,'new.hx');assert.equal(isolated.calls.length,1);isolated.cache.close();
  }
  pending.resolve({entries:[file('current.hx')]});await flush();next.cache.close();
});
test('changes invalidate only related directories and late responses cannot repopulate them',async()=>{
  const s=setup();await s.cache.list({path:'src'});await s.cache.list({path:'docs'});
  const old=defer(),fresh=defer();let calls=0;s.client.request=()=>++calls===1?old.promise:fresh.promise;
  s.advance(16000);await s.cache.list({path:'src'});
  s.client.emit('fs.changed',{path:'src/one.hx',kind:'remove'});
  assert.equal((await s.cache.list({path:'src'})).entries[0].name,'one.hx');
  fresh.resolve({entries:[]});await flush();old.resolve({entries:[file('old.hx')]});await flush();
  assert.deepEqual((await s.cache.list({path:'src'})).entries,[]);
  // A recent unaffected listing does not generate another request.
  s.cache.rows.get(s.cache.address({path:'docs'}).key).checked=116000;
  await s.cache.list({path:'docs'});assert.equal(calls,2);s.cache.close();
});
test('metadata failures do not poison retry or bypass sign-out and context fences',async()=>{
  const s=setup();s.client.request=async()=>{throw Error('offline');};
  await assert.rejects(s.cache.list({path:'src'}),/offline/);
  s.client.request=async()=>({entries:[file('live.hx')]});await s.cache.list({path:'src'});
  s.client.ready=false;assert.equal((await s.cache.list({path:'src'})).entries[0].name,'live.hx');
  s.client.accountPaused=true;await assert.rejects(s.cache.list({path:'src'}),/stopped/);
  s.client.accountPaused=false;s.client.invalidated=Error('account changed');s.client.emit('context-changed');
  await assert.rejects(s.cache.list({path:'src'}),/account changed/);assert.equal(s.cache.rows.size,0);s.cache.close();
});
test('CRDT file edits do not reload the tree; membership and ignore-rule changes update it',async()=>{
  const s=setup();await s.cache.list({path:'src'});
  s.client.emit('fs.changed',{path:'src/one.hx',kind:'change'});await flush();
  assert.equal(s.calls.length,1);assert.equal(s.changes(),0);
  s.client.request=async()=>{s.calls.push('revalidate');return {entries:[{...file('one.hx'),mtime:30}]};};
  s.client.emit('fs.changed',{path:'src/one.hx',kind:'rename'});await flush();
  assert.equal(s.calls.length,2);assert.equal(s.changes(),0);
  s.client.emit('fs.changed',{path:'src/.gitignore',kind:'change'});await flush();assert.equal(s.changes(),1);
  s.client.request=async()=>({entries:[file('new.hx')]});s.client.emit('fs.changed',{path:'src/one.hx',kind:'remove'});await flush();
  assert.equal(s.changes(),2);assert.equal((await s.cache.list({path:'src'})).entries[0].name,'new.hx');s.cache.close();
});
test('evicting a directory cannot remove the fence on its older in-flight response',async()=>{
  const s=setup();await s.cache.list({path:'src'});s.advance(16000);
  const old=defer();let calls=0;
  s.client.request=async(_,{path})=>path==='src'&&++calls===1?old.promise:{entries:[file('current.hx')]};
  await s.cache.list({path:'src'});s.cache.invalidate('src/main.hx');await s.cache.list({path:'src'});await flush();
  for(let i=0;i<300;i++)await s.cache.list({path:'other'+i});
  const key=s.cache.address({path:'src'}).key;assert.equal(s.cache.rows.has(key),false);
  old.resolve({entries:[file('obsolete.hx')]});await flush();
  assert.equal(s.cache.rows.has(key),false);assert.equal(s.cache.pending.size,0);s.cache.close();
});
test('the cache is bounded and disposal rejects late network completions',async()=>{
  const s=setup();for(let i=0;i<300;i++)await s.cache.list({path:'dir'+i});
  assert.equal(s.cache.rows.size,256);assert.ok(s.cache.bytes<=4*1024*1024);
  for(const path of ['../private','/absolute','src/../secret','src\\file','a\0b'])await assert.rejects(s.cache.list({path}),/Invalid directory/);
  await assert.rejects(s.cache.list({mount:'unknown'}),/Unknown installed/);
  const pending=defer();s.client.request=()=>pending.promise;const request=s.cache.list({path:'pending'});await flush();s.cache.close();pending.resolve({entries:[]});
  await assert.rejects(request,/stopped/);assert.equal(s.cache.rows.size,0);
});
