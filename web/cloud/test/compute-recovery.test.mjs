import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {once} from 'node:events';
import {fixture,signin,json} from './fixture.mjs';
const {WebSocketServer}=createRequire(new URL('../../session/package.json',import.meta.url))('ws');
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(check){const end=Date.now()+10000;while(!await check()){if(Date.now()>end)throw Error('Recovery did not settle');await pause(20);}}
function rpc(socket){let id=0;const waiting=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data);waiting.get(value.id)?.(value);waiting.delete(value.id);});return op=>new Promise((resolve,reject)=>{const key=++id,timer=setTimeout(()=>reject(Error('RPC timeout')),5000);waiting.set(key,value=>{clearTimeout(timer);resolve(value);});socket.send(JSON.stringify({op,id:key}));});}

test('hosted reconnect replaces lost compute once and refreshes private generation credentials',async t=>{
 let lost=false,generation=1,token='a'.repeat(64),recoveries=0,held,entered=false;
 const backend=new WebSocketServer({host:'127.0.0.1',port:0,verifyClient(info,done){
  assert.equal(info.req.headers.authorization,'Bearer test-runner-secret');
  done(!lost,lost?503:200);
 }});
 await once(backend,'listening');
 backend.on('headers',headers=>headers.push('X-RayDE-Token: '+token,'X-RayDE-Generation: '+generation));
 backend.on('connection',socket=>socket.on('message',raw=>{
  const request=JSON.parse(raw);
  assert.equal(request.token,token,'gateway uses the current private credential');
  socket.send(JSON.stringify({id:request.id,ok:true,protocol:1,root:'/workspace/project',exec:false,cacheIdentity:{version:1,authority:'retained-authority',workspace:'retained-workspace',principal:'workspace'},readRoots:[{id:'source',path:'/opt/rayde/extensions'}]}));
 }));
 const endpoint=`ws://127.0.0.1:${backend.address().port}/session`;
 const cloud=await fixture({provision:async(data,count)=>{
  assert.equal(data.checkout.accessToken,'access-alice');
  if(count>1){recoveries++;entered=true;if(held)await held;lost=false;generation++;token=(generation===2?'b':'c').repeat(64);}
  return json({url:endpoint,token,project:'build.hxml',generation,recoverable:true});
 }});
 t.after(async()=>{await cloud.mf.dispose();for(const socket of backend.clients)socket.terminate();await new Promise(r=>backend.close(r));});
 let user=await signin(cloud.fetch);
 const opening=await(await cloud.fetch('/api/workspaces/open',{method:'POST',headers:user.headers,body:'{"repository":111}'})).json();
 const path='/api/workspaces/'+opening.id;
 await until(async()=> (await(await cloud.fetch(path,{headers:user.headers})).json()).status==='ready');
 async function connect(account=user){const response=await cloud.fetch(path+'/socket',{headers:{...account.headers,Upgrade:'websocket'}});assert.equal(response.status,101);assert.equal(response.headers.get('X-RayDE-Token'),null);const socket=response.webSocket;socket.accept();const hello=await rpc(socket)('hello');assert.equal(hello.ok,true);assert.equal(hello.readRoots[0].path,'/opt/rayde/extensions');assert.ok(!JSON.stringify(hello).includes(token));return socket;}
 (await connect()).close();
 lost=true;for(const socket of backend.clients)socket.terminate();
 const clients=await Promise.all(Array.from({length:4},()=>connect()));
 assert.equal(recoveries,1,'concurrent reconnects share one replacement');
 for(const socket of clients)socket.close();
 generation=3;token='c'.repeat(64);
 (await connect()).close();
 assert.equal(recoveries,1,'a completed out-of-band recovery refreshes credentials without provisioning again');
 lost=true;entered=false;let release;held=new Promise(r=>release=r);
 const pending=cloud.fetch(path+'/socket',{headers:{...user.headers,Upgrade:'websocket'}});
 await until(()=>entered);
 assert.equal((await cloud.fetch('/api/logout',{method:'POST',headers:user.headers,body:'{}'})).status,200);
 assert.equal((await pending).status,403);
 release();held=null;
 user=await signin(cloud.fetch);
 (await connect()).close();
});
