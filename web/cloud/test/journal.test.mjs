import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer } from "node:net";
import { createRequire } from "node:module";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fixture, signin, origin, listening } from "./fixture.mjs";
const require = createRequire(new URL("../../session/package.json",import.meta.url)), Y = require("yjs");
const {WebSocketServer,WebSocket:ProxySocket} = require("ws");
const encode = bytes => Buffer.from(bytes).toString("base64");
const decode = text => Buffer.from(text,"base64");
const empty = encode(Y.encodeStateAsUpdate(new Y.Doc()));
const pause = ms => new Promise(resolve=>setTimeout(resolve,ms));
const freePort = () => new Promise(resolve=>{const server=createServer().listen(0,"127.0.0.1",()=>{const port=server.address().port;server.close(()=>resolve(port));});});
async function until(check) {const end=Date.now()+10000;while(!await check()){if(Date.now()>end)throw Error("Journal test did not settle");await pause(20);}}
function rpc(socket) {
  let next=1;const waiting=new Map();
  socket.addEventListener("message",event=>{const reply=JSON.parse(event.data);waiting.get(reply.id)?.(reply);waiting.delete(reply.id);});
  return (op,body={})=>new Promise((resolve,reject)=>{
    const id=next++,timer=setTimeout(()=>{waiting.delete(id);reject(Error("Journal RPC timed out: "+op));},15000);
    waiting.set(id,reply=>{clearTimeout(timer);resolve(reply);});socket.send(JSON.stringify({...body,id,op}));
  });
}
async function project(cloud,user) {
  const record=await(await cloud.fetch("/api/workspaces/open",{method:"POST",headers:user.headers,body:'{"repository":111}'})).json();
  const path="/api/workspaces/"+record.id;
  await until(async()=> (await(await cloud.fetch(path,{headers:user.headers})).json()).status==="ready");
  const namespace=await cloud.mf.getDurableObjectNamespace("WORKSPACES"),stub=namespace.get(namespace.idFromName(record.id));
  const control=async(op,body={})=>{const response=await stub.fetch("https://internal/"+op,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner:user.session.user.id,...body})});return {status:response.status,body:await response.json()};};
  const connect=async()=>{const response=await cloud.fetch(path+"/socket",{headers:{...user.headers,Upgrade:"websocket"}});assert.equal(response.status,101);const socket=response.webSocket;socket.accept();const request=rpc(socket),hello=await request("hello");assert.equal(hello.durableUpdates,true);return {socket,request};};
  return {path,control,connect};
}
function peer(opened) {const doc=new Y.Doc();Y.applyUpdate(doc,decode(opened.update));return doc;}
function edit(doc,work) {const vector=Y.encodeStateVector(doc);doc.transact(()=>work(doc.getText("text")));return encode(Y.encodeStateAsUpdate(doc,vector));}
function text(record) {const doc=new Y.Doc();Y.applyUpdate(doc,decode(record.checkpoint.update));const value=doc.getText("text").toString();doc.destroy();return value;}

test("acknowledged unsaved edits survive object and compute destruction with bounded incremental compaction",async t=>{
  const base=await mkdtemp(join(tmpdir(),"rayde-journal-")),root=join(base,"workspace"),persist=join(base,"objects"),port=await freePort();
  await mkdir(root);await writeFile(join(root,"main.hx"),"x".repeat(200000));let server,cloud;
  let blocked=false;const delayed=[],sockets=new Set();
  const proxy=new WebSocketServer({host:"127.0.0.1",port:0});await once(proxy,"listening");
  proxy.on("connection",client=>{
    const upstream=new ProxySocket(`ws://127.0.0.1:${port}/session`,{headers:{Origin:origin}}),pending=[];
    sockets.add(client);sockets.add(upstream);
    client.on("message",data=>{if(upstream.readyState===ProxySocket.OPEN)upstream.send(data.toString());else pending.push(data.toString());});
    upstream.on("open",()=>{for(const message of pending)upstream.send(message);pending.length=0;});
    upstream.on("message",data=>{
      const text=data.toString(),reply=JSON.parse(text),send=()=>{if(client.readyState===ProxySocket.OPEN)client.send(text);};
      if(blocked&&Array.isArray(reply.id)&&reply.id[0]==="recovery")delayed.push(send);else send();
    });
    for(const [socket,other] of [[client,upstream],[upstream,client]]) {
      socket.on("error",()=>{});socket.on("close",()=>{sockets.delete(socket);if(other.readyState===ProxySocket.OPEN)other.close();});
    }
  });
  const endpoint=`ws://127.0.0.1:${proxy.address().port}/session`;
  async function stop() {if(server?.exitCode===null&&server.signalCode===null){const exited=once(server,"exit");server.kill("SIGKILL");await exited;}}
  async function start(state) {server=spawn(resolve("../../native/session/target/debug/rayde-session"),["--root",root,"--state-root",join(base,state),"--port",String(port),"--token","compute-secret","--origin",origin],{stdio:"ignore"});await listening(port,server);}
  t.after(async()=>{await cloud?.mf.dispose();await stop();for(const socket of sockets)socket.terminate();await new Promise(resolve=>proxy.close(resolve));await rm(base,{recursive:true,force:true});});
  await start("state");cloud=await fixture({persist,endpoint});
  const user=await signin(cloud.fetch),workspace=await project(cloud,user),a=await workspace.connect(),b=await workspace.connect();
  const pa=peer(await a.request("doc.open",{path:"main.hx"})),pb=peer(await b.request("doc.open",{path:"main.hx"}));
  assert.equal((await workspace.control("journals")).body.ids.length,0,"file reads alone do not create cloud recovery journals");
  const initial=await a.request("doc.update",{path:"main.hx",update:empty});assert.ok(initial.durableUpdate?.id);assert.equal(initial.journal,undefined);
  const ua=edit(pa,t=>t.insert(0,"A")),ub=edit(pb,t=>t.insert(0,"B"));
  const merged=new Y.Doc();Y.applyUpdate(merged,Y.encodeStateAsUpdate(pa));Y.applyUpdate(merged,decode(ub));
  const replies=await Promise.all([a.request("doc.update",{path:"main.hx",update:ua,journal:false,vector:"spoof"}),b.request("doc.update",{path:"main.hx",update:ub})]);
  assert.ok(replies.every(reply=>reply.ok&&reply.durableUpdate.id===initial.durableUpdate.id));
  const id=initial.durableUpdate.id,get=()=>workspace.control("journal",{id});
  let record=(await get()).body;assert.equal(text(record),merged.getText("text").toString(),"receipt must follow the durable write");
  const before=record.manifest.vector;
  const current=peer(await a.request("doc.open",{path:"main.hx"}));
  const deletion=await a.request("doc.update",{path:"main.hx",update:edit(current,t=>t.delete(0,1))});assert.equal(deletion.ok,true);
  record=(await get()).body;assert.equal(record.manifest.vector,before);assert.equal(text(record),current.getText("text").toString());
  const invalid=await a.request("doc.update",{path:"main.hx",update:"not base64"});assert.equal(invalid.ok,false);
  assert.equal((await get()).body.manifest.sequence,record.manifest.sequence);
  for(let i=0;i<140;i++)assert.equal((await a.request("doc.update",{path:"main.hx",update:edit(current,t=>t.insert(0,String(i%10)))})).ok,true);
  const burst=Array.from({length:80},()=>edit(current,t=>t.insert(0,"q")));
  assert.ok((await Promise.all(burst.map(update=>a.request("doc.update",{path:"main.hx",update})))).every(reply=>reply.ok),"dependent updates retain FIFO order while storage yields");
  record=(await get()).body;assert.equal(text(record),current.getText("text").toString());
  assert.ok(record.manifest.segments.length<64);assert.ok(record.manifest.allocated<170,"compaction reuses a bounded set of chunk slots");
  const retry=edit(current,t=>t.insert(0,"retry"));
  for(let i=0;i<3;i++)assert.equal((await a.request("doc.update",{path:"main.hx",update:retry})).ok,true);
  const repeated=(await get()).body.manifest.sequence;
  await a.request("doc.update",{path:"main.hx",update:retry});assert.equal((await get()).body.manifest.sequence,repeated,"duplicate barriers must not grow the journal indefinitely");
  const largeCheckpoint=(await get()).body.checkpoint;
  const outside="outside dependency 🦊";await a.request("fs.write",{path:"main.hx",data:outside});
  await until(async()=> (await a.request("doc.open",{path:"main.hx"})).text===outside);
  assert.equal((await a.request("doc.update",{path:"main.hx",update:empty})).ok,true);
  record=(await get()).body;assert.equal(text(record),outside);
  assert.equal((await workspace.control("checkpoints")).body.ids.length,0,"unsaved recovery is separate from Save checkpoints");
  blocked=true;let overflow=false;
  const pendingPressure=Array.from({length:5},()=>a.request("doc.update",{path:"main.hx",update:"!".repeat(3*1024*1024)}).then(reply=>{if(reply.code==="journal-failed"&&reply.message.includes("queue"))overflow=true;return reply;}));
  await until(()=>overflow&&delayed.length>0);blocked=false;for(const send of delayed.splice(0))send();
  const pressure=await Promise.all(pendingPressure);
  assert.ok(pressure.every(reply=>reply.ok===false));
  assert.ok(pressure.some(reply=>reply.code==="journal-failed"&&reply.message.includes("queue")),"queued payload bytes are bounded before native allocation");
  assert.equal((await a.request("doc.update",{path:"main.hx",update:empty})).ok,true,"failed updates release queue byte reservations");
  assert.equal((await workspace.control("journal",{id,owner:2})).status,403);
  assert.equal((await cloud.fetch(workspace.path+"/journal",{headers:user.headers})).status,404);
  await stop();await cloud.mf.dispose();await rm(root,{recursive:true});await rm(join(base,"state"),{recursive:true});
  cloud=await fixture({persist,endpoint});
  const restored=await project(cloud,user),retained=await restored.control("journal",{id});assert.equal(retained.status,200);assert.equal(text(retained.body),outside);
  await mkdir(root);await start("fresh-state");
  const direct=new WebSocket(`ws://127.0.0.1:${port}/session`);await once(direct,"open");const request=rpc(direct);await request("hello",{token:"compute-secret"});
  assert.equal((await request("doc.restore",{path:"main.hx",checkpoint:retained.body.checkpoint})).ok,true);
  assert.equal((await request("doc.open",{path:"main.hx"})).text,outside);direct.close();
  const next=await restored.connect();await next.request("doc.open",{path:"main.hx"});
  const newGeneration=await next.request("doc.update",{path:"main.hx",update:empty});assert.equal(newGeneration.ok,true);assert.notEqual(newGeneration.durableUpdate.id,id);
  assert.equal((await restored.control("journals")).body.ids.length,2,"fresh compute generations remain fenced");
  const bob=await signin(cloud.fetch,"bob"),quota=await project(cloud,bob),writer=await quota.connect();
  await writer.request("fs.write",{path:"quota.hx",data:"quota"});await writer.request("doc.open",{path:"quota.hx"});
  const old=await writer.request("doc.update",{path:"quota.hx",update:empty});assert.equal(old.ok,true);
  const previous=(await quota.control("journal",{id:old.durableUpdate.id})).body;
  let full=false;
  for(let i=0;i<512;i++) {
    const imported=await quota.control("checkpoint/import",{path:`fill-${i}.hx`,source:previous.manifest.source,checkpoint:largeCheckpoint});
    if(imported.status===507){full=true;break;}assert.equal(imported.status,200);
  }
  assert.ok(full);const oldUsage=(await quota.control("journals")).body.totalBytes;
  const pq=peer(await writer.request("doc.open",{path:"quota.hx"}));
  const refused=await writer.request("doc.update",{path:"quota.hx",update:edit(pq,t=>t.insert(0,"z".repeat(600000)))});
  assert.equal(refused.ok,false);assert.equal(refused.code,"journal-failed");
  assert.equal(text((await quota.control("journal",{id:old.durableUpdate.id})).body),"quota");
  assert.equal((await quota.control("journals")).body.totalBytes,oldUsage,"quota failure must leave payload, manifest and accounting unchanged");
  next.socket.close();writer.socket.close();for(const doc of [pa,pb,current,merged,pq])doc.destroy();
});
