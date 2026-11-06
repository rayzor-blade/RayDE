// HTTP/WebSocket protocol integration only; this test does not launch a browser.
import {test} from 'node:test';
import {fetch as portFetch} from 'miniflare';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {once} from 'node:events';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {fixture,json,origin,listening,signin} from './fixture.mjs';

const {WebSocketServer}=createRequire(new URL('../../session/package.json',import.meta.url))('ws');
const build='-cp src\n-main Main\n--interp\n';
const bundle=Buffer.from(JSON.stringify({version:1,root:'/work/pocket-studio',project:'pocket-studio/build.hxml',entries:[
 {path:'/work/pocket-studio',directory:true},
 {path:'/work/pocket-studio/build.hxml',directory:false,data:Buffer.from(build).toString('base64')},
 {path:'/work/pocket-studio/live.txt',directory:false,data:Buffer.from('base').toString('base64')}
]}));
const release=createHash('sha256').update(bundle).digest('hex'),toolchain='b'.repeat(64);
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function port(){const server=createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const port=server.address().port;await new Promise(resolve=>server.close(resolve));return port;}
async function peer(fetch,cookie,claimedId){
 const response=await fetch('/api/demo/socket'+(claimedId?'?id='+claimedId:''),{headers:{Cookie:cookie,Origin:origin,Upgrade:'websocket','CF-Connecting-IP':'192.0.2.1'}});
 assert.equal(response.status,101);const socket=response.webSocket;socket.accept();
 let serial=0;const pending=new Map();
 socket.addEventListener('message',event=>{const reply=JSON.parse(event.data);pending.get(reply.id)?.(reply);pending.delete(reply.id);});
 return {socket,rpc:(op,body={})=>new Promise((resolve,reject)=>{
  const id=++serial,timer=setTimeout(()=>{pending.delete(id);reject(Error('Demo RPC timeout: '+op));},5000);
  pending.set(id,reply=>{clearTimeout(timer);resolve(reply);});socket.send(JSON.stringify({id,op,...body}));
 })};
}

for(const compute of ['runner','containers'])test(`${compute}: two admitted demo sessions keep private identity/files and release only their own recovery payloads`,async t=>{
 const root=await mkdtemp(join(tmpdir(),'rayde-demo-session-')),hosts=new Map();
 const seed=join(root,'demo.json');await writeFile(seed,bundle);
 let allow;const admitted=new Promise(resolve=>allow=resolve);
 async function stop(id){const host=hosts.get(id);if(host&&host.process.exitCode===null&&host.process.signalCode===null){const exited=once(host.process,'exit');host.process.kill();await exited;}}
 t.after(async()=>{allow();for(const id of hosts.keys())await stop(id);await rm(root,{recursive:true,force:true});});
 const provision=async data=>{
  await admitted;
  assert.equal(data.owner,0);assert.equal(data.repository.demo.release,release);
  const path=join(root,data.id),number=await port();await mkdir(path);await writeFile(join(path,'build.hxml'),build);await writeFile(join(path,'live.txt'),'base');
  const process=spawn(resolve('../../native/session/target/release/rayde-session'),['--root',path,'--state-root',join(path,'state'),'--port',String(number),'--token',data.token??'compute-secret','--origin',origin,'--exec','--demo-seed',seed,'--demo-release',release],{stdio:'ignore'});
  hosts.set(data.id,{path,process,port:number});await listening(number,process);
  return json({url:`ws://127.0.0.1:${number}/session`,token:'compute-secret',project:'build.hxml',toolchain});
 };
 const instances=new Map();
 const container=async request=>{
  const [,id,operation]=new URL(request.url).pathname.split('/');
  if(operation==='running')return json({running:instances.has(id)});
  if(operation==='start'){
   const data=await request.json(),env=data.env;
   await provision({id,owner:0,token:env.RAYDE_DEMO_TOKEN,repository:{demo:{release:env.RAYDE_DEMO_RELEASE}}});
   instances.set(id,env);return json({});
  }
  if(operation==='health'){
   const env=instances.get(id);if(!env)return json({},503);
   return json({version:1,id,release:env.RAYDE_DEMO_RELEASE,toolchain:env.RAYDE_DEMO_TOOLCHAIN,expires:Number(env.RAYDE_DEMO_EXPIRES),generation:1});
  }
  if(operation==='destroy'){await stop(id);instances.delete(id);return json({});}
  if(operation==='session')return portFetch(`http://127.0.0.1:${hosts.get(id).port}/session`,{headers:{Upgrade:'websocket',Origin:origin}});
  return json({},404);
 };
 const cloud=await fixture({demo:{release,maximum:2,...(compute==='containers'?{compute}:{})},provision,
  ...(compute==='containers'?{container}:{}),cleanup:async data=>{await stop(data.id);return json({deleted:true});}});
 t.after(()=>cloud.mf.dispose());const {fetch,mf}=cloud;
 async function open(ip){const response=await fetch('/api/demo/open',{method:'POST',headers:{Origin:origin,'CF-Connecting-IP':ip}});assert.equal(response.status,202);return {state:await response.json(),cookie:response.headers.get('Set-Cookie').split(';')[0]};}
 const [a,b]=await Promise.race([Promise.all([open('192.0.2.1'),open('192.0.2.2')]),pause(2000).then(()=>{throw Error('Admission waited for compute instead of returning preparing');})]);
 assert.equal(hosts.size,0);allow();
 async function ready(visitor){for(let i=0;i<200;i++){const response=await fetch('/api/demo/status',{headers:{Cookie:visitor.cookie}}),state=await response.json();if(state.status==='ready')return;if(state.status==='failed')throw Error(state.message);await pause(10);}throw Error('Demo session not ready');}
 await Promise.all([ready(a),ready(b)]);
 const one=await peer(fetch,a.cookie,b.state.id),two=await peer(fetch,b.cookie,a.state.id);t.after(()=>{one.socket.close();two.socket.close();});
 const helloA=await one.rpc('hello',{token:'client-does-not-know-runner-token'}),helloB=await two.rpc('hello');
 assert.equal(helloA.cacheIdentity.principal,'demo:'+a.state.id);assert.equal(helloB.cacheIdentity.principal,'demo:'+b.state.id);
 assert.deepEqual(helloA.demoSeed,{version:1,release});
 assert.notDeepEqual(helloA.cacheIdentity,helloB.cacheIdentity);
 assert.equal((await one.rpc('fs.write',{path:'private-a.txt',data:'only A'})).ok,true);
 assert.equal((await two.rpc('fs.stat',{path:'private-a.txt'})).entry,null);
 assert.equal((await two.rpc('fs.write',{path:'private-b.txt',data:'only B'})).ok,true);
 const files=await mf.getR2Bucket('WORKSPACE_FILES');assert.equal((await files.list()).objects.length,2);
 const account=await signin(fetch);assert.equal((await fetch('/api/logout',{method:'POST',headers:account.headers,body:'{}'})).status,200);
 assert.equal((await two.rpc('fs.read',{path:'private-b.txt'})).data,'only B','account logout ended the anonymous lease');
 assert.equal((await one.rpc('doc.restore',{path:'live.txt'})).code,'denied');
 assert.equal((await fetch('/api/demo/end',{method:'POST',headers:{Cookie:a.cookie,Origin:origin}})).status,200);
 for(let i=0;i<200;i++){if((await files.list()).objects.length===1)break;await pause(10);}
 assert.equal((await files.list()).objects.length,1,'ending A left its recovery blobs or deleted B\'s');
 assert.equal((await fetch('/api/demo/status',{headers:{Cookie:a.cookie}})).status,410);
 assert.equal((await two.rpc('fs.read',{path:'private-b.txt'})).data,'only B');
 await fetch('/api/demo/end',{method:'POST',headers:{Cookie:b.cookie,Origin:origin}});
 for(let i=0;i<200;i++){if((await files.list()).objects.length===0)break;await pause(10);}
 assert.equal((await files.list()).objects.length,0);
});

test('a runtime without the pinned demo graph cannot attach a browser replica',async t=>{
 const backend=new WebSocketServer({host:'127.0.0.1',port:0});await once(backend,'listening');
 backend.on('connection',socket=>socket.on('message',raw=>{
  const request=JSON.parse(raw);socket.send(JSON.stringify({id:request.id,ok:true,cacheIdentity:{version:1,authority:'unseeded',workspace:'unseeded'}}));
 }));
 const {mf,fetch}=await fixture({demo:{release},endpoint:`ws://127.0.0.1:${backend.address().port}/session`});
 t.after(async()=>{await mf.dispose();for(const socket of backend.clients)socket.terminate();await new Promise(resolve=>backend.close(resolve));});
 const response=await fetch('/api/demo/open',{method:'POST',headers:{Origin:origin,'CF-Connecting-IP':'192.0.2.1'}}),cookie=response.headers.get('Set-Cookie').split(';')[0];
 for(let i=0;i<100;i++){
  const state=await(await fetch('/api/demo/status',{headers:{Cookie:cookie}})).json();if(state.status==='ready')break;await pause(10);
 }
 const client=await peer(fetch,cookie);t.after(()=>client.socket.close());
 const hello=await client.rpc('hello');assert.equal(hello.ok,false);assert.equal(hello.code,'demo-source');assert.equal(hello.cacheIdentity,undefined);
});
