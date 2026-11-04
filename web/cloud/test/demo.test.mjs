import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,origin,json} from './fixture.mjs';

const release='a'.repeat(64);
const headers=(cookie,ip='192.0.2.1')=>({Origin:origin,'CF-Connecting-IP':ip,...(cookie?{Cookie:cookie}:{})});
async function opened(fetch,ip){
 const response=await fetch('/api/demo/open',{method:'POST',headers:headers(null,ip),body:'{"release":"ignored","owner":999}'});
 const body=await response.json();
 return {response,body,cookie:response.headers.get('Set-Cookie')?.split(';')[0]};
}
async function ready(fetch,cookie){
 for(let i=0;i<100;i++){
  const response=await fetch('/api/demo/status',{headers:headers(cookie)}),state=await response.json();
  if(state.status==='ready')return state;
  if(state.status==='failed')throw Error(state.message);
  await new Promise(resolve=>setTimeout(resolve,10));
 }
 throw Error('Demo preparation did not finish');
}

test('demo admission is opt-in, same-origin and separate from GitHub authentication',async t=>{
 const disabled=await fixture();t.after(()=>disabled.mf.dispose());
 assert.equal((await disabled.fetch('/api/demo/open',{method:'POST',headers:headers()})).status,404);
 const {mf,fetch,calls}=await fixture({demo:{release}});t.after(()=>mf.dispose());
 assert.equal((await fetch('/api/demo/open',{method:'POST'})).status,403);
 assert.equal((await fetch('/api/demo/open',{method:'POST',headers:{Origin:'https://other.example'}})).status,403);
 assert.equal((await fetch('/api/demo/status')).status,401);
 assert.equal((await fetch('/api/demo/status',{headers:headers('rayde_demo='+'0'.repeat(64))})).status,410);
 const first=await opened(fetch);assert.equal(first.response.status,202);
 assert.match(first.response.headers.get('Set-Cookie'),/HttpOnly/);assert.match(first.response.headers.get('Set-Cookie'),/SameSite=Strict/);
 assert.match(first.response.headers.get('Set-Cookie'),/Path=\/api\/demo/);
 assert.match(first.body.id,/^[\w-]{43}$/);assert.equal(first.body.release,release);
 assert.ok(!JSON.stringify(first.body).includes('compute-secret'));assert.ok(!JSON.stringify(first.body).includes(first.cookie.split('=')[1]));
 const state=await ready(fetch,first.cookie);assert.equal(state.id,first.body.id);
 assert.equal(calls.api.length,0,'anonymous admission queried GitHub');assert.equal(calls.exchanges.length,0);
 assert.equal(calls.runner[0].owner,0);assert.equal(calls.runner[0].repository.demo.release,release);
 assert.equal(calls.runner[0].checkout.accessToken,null);assert.equal(calls.runner[0].publish,null);
 const repeated=await fetch('/api/demo/open',{method:'POST',headers:headers(first.cookie)});assert.equal((await repeated.json()).id,state.id);
 assert.equal(calls.runner.length,1,'reopening reprovisioned the visitor');
 const idle=(await(await fetch('/api/demo/status',{headers:headers(first.cookie)})).json()).idleUntil;
 assert.equal(idle,first.body.idleUntil,'status polling renewed the idle lease');
});

test('visitors have independent bounded leases and cannot choose each other\'s workspace',async t=>{
 const {mf,fetch,calls}=await fixture({demo:{release,maximum:2}});t.after(()=>mf.dispose());
 const [one,two]=await Promise.all([opened(fetch,'192.0.2.1'),opened(fetch,'192.0.2.2')]);
 assert.equal(one.response.status,202);assert.equal(two.response.status,202);assert.notEqual(one.cookie,two.cookie);assert.notEqual(one.body.id,two.body.id);
 await Promise.all([ready(fetch,one.cookie),ready(fetch,two.cookie)]);
 const full=await opened(fetch,'192.0.2.3');assert.equal(full.response.status,429);assert.equal(full.cookie,undefined);
 const response=await fetch('/api/demo/open',{method:'POST',headers:headers(one.cookie),body:JSON.stringify({id:two.body.id,release:'b'.repeat(64)})});
 assert.equal((await response.json()).id,one.body.id);assert.equal(calls.runner.length,2);
 assert.notEqual(calls.runner[0].repository.demo.lease,calls.runner[1].repository.demo.lease);
 assert.equal((await fetch('/api/demo/socket',{headers:headers(one.cookie)})).status,400);
 assert.equal((await fetch('/api/demo/open',{method:'POST',headers:{...headers(one.cookie),Origin:'https://untrusted.example'}})).status,403);
});

test('full admission is rate limited and failed preparation retains its own retryable lease',async t=>{
 const {mf,fetch,calls}=await fixture({demo:{release},provision:()=>json({},503)});t.after(()=>mf.dispose());
 const first=await opened(fetch);assert.equal(first.response.status,202);
 let failure;
 for(let i=0;i<100;i++){
  failure=await(await fetch('/api/demo/status',{headers:headers(first.cookie)})).json();
  if(failure.status==='failed')break;await new Promise(resolve=>setTimeout(resolve,10));
 }
 assert.equal(failure.status,'failed');assert.equal(failure.id,first.body.id);
 assert.equal((await fetch('/api/demo/retry',{method:'POST',headers:headers(first.cookie)})).status,429);
 for(let i=0;i<3;i++)assert.equal((await opened(fetch)).response.status,429);
 assert.equal(calls.runner.length,1);
});

test('ending a demo keeps capacity reserved until compute cleanup is confirmed',async t=>{
 let refuse=true;
 const {mf,fetch,calls}=await fixture({demo:{release},cleanup:()=>refuse?json({},503):json({deleted:true})});t.after(()=>mf.dispose());
 const first=await opened(fetch);await ready(fetch,first.cookie);
 const ended=await fetch('/api/demo/end',{method:'POST',headers:headers(first.cookie)});assert.equal(ended.status,200);assert.match(ended.headers.get('Set-Cookie'),/Max-Age=0/);
 for(let i=0;i<100&&calls.runnerDeletes.length===0;i++)await new Promise(resolve=>setTimeout(resolve,10));
 assert.equal(calls.runnerDeletes.length,1);assert.equal(calls.runnerDeletes[0].id,first.body.id);assert.equal(calls.runnerDeletes[0].owner,0);
 assert.equal((await opened(fetch,'192.0.2.2')).response.status,429);
 assert.equal((await fetch('/api/demo/status',{headers:headers(first.cookie)})).status,410);
 refuse=false;await fetch('/api/demo/end',{method:'POST',headers:headers(first.cookie)});
 let admitted;
 for(let i=0;i<20;i++){
  admitted=await opened(fetch,'192.0.2.'+(10+i));if(admitted.response.status===202)break;
  await new Promise(resolve=>setTimeout(resolve,20));
 }
 assert.equal(admitted.response.status,202);assert.notEqual(admitted.body.id,first.body.id);
});

test('a mismatched demo toolchain cannot become ready',async t=>{
 const {mf,fetch}=await fixture({demo:{release,toolchain:'c'.repeat(64)}});t.after(()=>mf.dispose());
 const first=await opened(fetch);assert.equal(first.response.status,202);
 let state;
 for(let i=0;i<100;i++){
  state=await(await fetch('/api/demo/status',{headers:headers(first.cookie)})).json();
  if(state.status==='failed')break;await new Promise(resolve=>setTimeout(resolve,10));
 }
 assert.equal(state.status,'failed');assert.match(state.message,/toolchain/);
});

test('ending during first boot waits for compute cleanup without blocking the visitor',async t=>{
 let releaseBoot,started=false;
 const boot=new Promise(resolve=>releaseBoot=resolve);
 const {mf,fetch,calls}=await fixture({demo:{release},provision:async()=>{
  started=true;await boot;return json({url:'ws://127.0.0.1:8790/session',token:'compute-secret',project:'build.hxml',toolchain:'b'.repeat(64)});
 }});
 t.after(()=>{releaseBoot();return mf.dispose();});
 const first=await opened(fetch);
 for(let i=0;i<100&&!started;i++)await new Promise(resolve=>setTimeout(resolve,10));
 assert.equal(started,true);
 const response=await Promise.race([
  fetch('/api/demo/end',{method:'POST',headers:headers(first.cookie)}),
  new Promise((_,reject)=>setTimeout(()=>reject(Error('Ending waited for compute')),1000))
 ]);
 assert.equal(response.status,200);assert.equal(calls.runnerDeletes.length,0);
 assert.equal((await opened(fetch,'192.0.2.2')).response.status,429);
 releaseBoot();
 for(let i=0;i<100&&calls.runnerDeletes.length===0;i++)await new Promise(resolve=>setTimeout(resolve,10));
 assert.equal(calls.runnerDeletes.length,1);
 assert.equal((await fetch('/api/demo/status',{headers:headers(first.cookie)})).status,410);
 let next;
 for(let i=0;i<100;i++){
  next=await opened(fetch,'192.0.2.'+(10+i));if(next.response.status===202)break;
  await new Promise(resolve=>setTimeout(resolve,10));
 }
 assert.equal(next.response.status,202);assert.notEqual(next.body.id,first.body.id);
});
