// Lifecycle emulation, not a Docker/Cloudflare deployment test. Production orchestration is Rust.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,origin,json} from './fixture.mjs';

const release='a'.repeat(64),toolchain='b'.repeat(64);
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const headers=(cookie,ip='192.0.2.1')=>({Origin:origin,'CF-Connecting-IP':ip,...(cookie?{Cookie:cookie}:{})});
async function open(fetch,ip){
 const response=await fetch('/api/demo/open',{method:'POST',headers:headers(null,ip)});
 return {response,state:await response.json(),cookie:response.headers.get('Set-Cookie')?.split(';')[0]};
}
async function state(fetch,visitor,expected='ready'){
 for(let i=0;i<250;i++){
  const result=await(await fetch('/api/demo/status',{headers:headers(visitor.cookie)})).json();
  if(result.status===expected)return result;
  if(result.status==='failed'&&expected!=='failed')throw Error(result.message);
  await pause(10);
 }
 throw Error('Container preparation did not finish');
}
function runtime({startGate,health,stop}={}){
 const instances=new Map(),starts=[],stops=[];
 return {instances,starts,stops,fetch:async request=>{
  const [,id,operation]=new URL(request.url).pathname.split('/');
  if(operation==='start'){
   const data=await request.json();starts.push({id,...data});
   if(startGate)await startGate;
   instances.set(id,data.env);return json({});
  }
  if(operation==='running')return json({running:instances.has(id)});
  if(operation==='destroy'){
   stops.push(id);if(stop){const response=await stop(id);if(response)return response;}
   instances.delete(id);return json({});
  }
  if(operation==='health'){
   const env=instances.get(id);if(!env)return json({},503);
   return json(health??{version:1,id,release:env.RAYDE_DEMO_RELEASE,toolchain:env.RAYDE_DEMO_TOOLCHAIN,expires:Number(env.RAYDE_DEMO_EXPIRES),generation:1});
  }
  return json({},404);
 }};
}

test('container admission returns preparing immediately and gives each visitor private bounded compute',async t=>{
 let allow;const startGate=new Promise(resolve=>allow=resolve);t.after(()=>allow());
 const host=runtime({startGate});
 const {mf,fetch,calls}=await fixture({demo:{release,compute:'containers',maximum:2},container:host.fetch});t.after(()=>mf.dispose());
 const [a,b]=await Promise.race([Promise.all([open(fetch),open(fetch,'192.0.2.2')]),pause(2000).then(()=>{throw Error('Admission blocked on compute');})]);
 assert.equal(a.response.status,202);assert.equal(b.response.status,202);assert.equal(a.state.status,'preparing');
 assert.notEqual(a.state.id,b.state.id);allow();
 await Promise.all([state(fetch,a),state(fetch,b)]);
 assert.equal(host.starts.length,2);assert.equal(calls.runner.length,0);
 const [one,two]=host.starts;assert.equal(one.enableInternet,false);assert.notEqual(one.env.RAYDE_DEMO_TOKEN,two.env.RAYDE_DEMO_TOKEN);
 for(const item of host.starts){
  assert.equal(item.env.RAYDE_DEMO_ID,item.id);assert.equal(item.env.RAYDE_DEMO_RELEASE,release);assert.equal(item.env.RAYDE_DEMO_TOOLCHAIN,toolchain);
  assert.match(item.env.RAYDE_DEMO_TOKEN,/^[a-f0-9]{64}$/);assert.equal(item.env.RAYDE_DEMO_GENERATION,'1');
  assert.ok(Number(item.env.RAYDE_DEMO_EXPIRES)*1000<=Date.now()+900000);
  assert.deepEqual(Object.keys(item.env).sort(),['EXPIRES','GENERATION','ID','LEASE','ORIGIN','RELEASE','TOKEN','TOOLCHAIN'].map(v=>'RAYDE_DEMO_'+v).sort());
  assert.ok(!JSON.stringify(await state(fetch,a)).includes(item.env.RAYDE_DEMO_TOKEN));
 }
 await fetch('/api/demo/open',{method:'POST',headers:headers(a.cookie)});await state(fetch,a);
 assert.equal(host.starts.length,2,'reopening replaced a running visitor container');
 assert.equal((await open(fetch,'192.0.2.3')).response.status,429);
 await fetch('/api/demo/end',{method:'POST',headers:headers(a.cookie)});
 for(let i=0;i<100&&host.stops.length===0;i++)await pause(10);
 assert.deepEqual(host.stops,[a.state.id]);assert.equal(host.instances.has(b.state.id),true);assert.equal(calls.runnerDeletes.length,0);
});

test('a mismatched container is destroyed before readiness or visitor attachment',async t=>{
 const host=runtime({health:{version:1,id:'foreign'}});
 const {mf,fetch}=await fixture({demo:{release,compute:'containers'},container:host.fetch});t.after(()=>mf.dispose());
 const visitor=await open(fetch);const result=await state(fetch,visitor,'failed');
 assert.match(result.message,/pinned image and lease/);assert.deepEqual(host.stops,[visitor.state.id]);
 assert.equal(host.instances.size,0);
});

test('cleanup failure retains capacity and end during boot waits for destruction',async t=>{
 let allow;const startGate=new Promise(resolve=>allow=resolve);t.after(()=>allow());let refuse=true;
 const host=runtime({startGate,stop:()=>refuse?json({},503):undefined});
 const {mf,fetch,calls}=await fixture({demo:{release,compute:'containers'},container:host.fetch});t.after(()=>mf.dispose());
 const visitor=await open(fetch);
 for(let i=0;i<100&&host.starts.length===0;i++)await pause(10);
 assert.equal(host.starts.length,1);
 const ended=await fetch('/api/demo/end',{method:'POST',headers:headers(visitor.cookie)});
 assert.equal(ended.status,200);allow();
 for(let i=0;i<100&&host.stops.length===0;i++)await pause(10);
 assert.equal(host.stops.length,1);assert.equal((await open(fetch,'192.0.2.2')).response.status,429);
 refuse=false;await fetch('/api/demo/end',{method:'POST',headers:headers(visitor.cookie)});
 for(let i=0;i<100&&host.instances.size;i++)await pause(10);
 assert.equal(host.instances.size,0);assert.equal(calls.runnerDeletes.length,0);
});

test('container identity is fenced and a lost used filesystem cannot silently reset visitor edits',async t=>{
 const host=runtime();
 const {mf,fetch}=await fixture({demo:{release,compute:'containers'},container:host.fetch});t.after(()=>mf.dispose());
 const visitor=await open(fetch);await state(fetch,visitor);
 const {id,env}=host.starts[0];
 const namespace=await mf.getDurableObjectNamespace('DEMO_CONTAINERS'),stub=namespace.get(namespace.idFromName(id));
 const data={id,owner:'demo:'+id,repository:{id:0,demo:{release,lease:env.RAYDE_DEMO_LEASE,expires:Number(env.RAYDE_DEMO_EXPIRES),compute:'containers'}}};
 const post=body=>({method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 const result=await stub.fetch('https://internal/open',post(data));assert.equal(result.status,200);
 const connection=await result.json();assert.equal(connection.recoverable,false);assert.equal(host.starts.length,1);
 const foreign=namespace.get(namespace.idFromName('x'.repeat(43)));
 assert.equal((await foreign.fetch('https://internal/open',post(data))).status,403);
 assert.equal((await stub.fetch('https://internal/open',post({...data,owner:'demo:foreign'}))).status,403);
 assert.equal((await stub.fetch('https://internal/open',post({...data,repository:{id:0,demo:{...data.repository.demo,expires:1}}}))).status,410);
 const badSocket=await stub.fetch('https://internal/socket',{headers:{Upgrade:'websocket','X-RayDE-Container':JSON.stringify({id,token:'foreign',origin})}});
 assert.equal(badSocket.status,403);
 host.instances.delete(id);
 const lost=await stub.fetch('https://internal/open',post(data));assert.equal(lost.status,409);assert.match((await lost.json()).message,/retained for recovery/);
 assert.equal(host.starts.length,1,'a used session was replaced with the public starter');
 assert.equal((await stub.fetch('https://internal/end',post({id}))).status,200);
 assert.equal((await stub.fetch('https://internal/open',post(data))).status,410,'ended compute was revived');
});

test('disabling container starts leaves the destruction path available',async t=>{
 const host=runtime(),id='x'.repeat(43);
 const {mf}=await fixture({demo:{release},container:host.fetch});t.after(()=>mf.dispose());
 const namespace=await mf.getDurableObjectNamespace('DEMO_CONTAINERS'),stub=namespace.get(namespace.idFromName(id));
 const post={method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})};
 assert.equal((await stub.fetch('https://internal/open',post)).status,503);
 assert.equal((await stub.fetch('https://internal/end',post)).status,200);
 assert.deepEqual(host.stops,[id]);assert.equal(host.starts.length,0);
});
