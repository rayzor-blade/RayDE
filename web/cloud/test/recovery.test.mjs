import test from "node:test";
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {createHash} from "node:crypto";
import {createRequire} from "node:module";
import {createServer} from "node:net";
import {mkdtemp,rm} from "node:fs/promises";
import {join,resolve} from "node:path";
import {tmpdir} from "node:os";
import {fixture,signin,origin,listening} from "./fixture.mjs";
const require=createRequire(new URL("../../session/package.json",import.meta.url)),Y=require("yjs"),{WebSocketServer,WebSocket}=require("ws");
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms)),empty="AAA=";
async function until(check){const end=Date.now()+12000;while(!await check()){if(Date.now()>end)throw Error("Recovery test did not settle");await pause(20);}}
const port=()=>new Promise(resolve=>{const server=createServer().listen(0,"127.0.0.1",()=>{const port=server.address().port;server.close(()=>resolve(port));});});
function rpc(socket){
 let next=1;const waiting=new Map();
 socket.addEventListener("message",event=>{const reply=JSON.parse(event.data);waiting.get(reply.id)?.resolve(reply);waiting.delete(reply.id);});
 socket.addEventListener("close",()=>{for(const pending of waiting.values())pending.reject(Error("Workspace disconnected"));waiting.clear();});
 return(op,body={})=>new Promise((resolve,reject)=>{
  const id=next++,timer=setTimeout(()=>{waiting.delete(id);reject(Error("Recovery RPC timeout: "+op));},15000);
  waiting.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});socket.send(JSON.stringify({...body,id,op}));
 });
}
async function setup(t){
 const base=await mkdtemp(join(tmpdir(),"rayde-restore-catalog-")),nativePort=await port(),root=join(base,"workspace");
 const {mkdir}=await import("node:fs/promises");await mkdir(root);
 let native,cloud,blocked=null;const delayed=[],sockets=new Set(),held=new Set();
 const proxy=new WebSocketServer({host:"127.0.0.1",port:0});await once(proxy,"listening");
 proxy.on("connection",client=>{
  const upstream=new WebSocket(`ws://127.0.0.1:${nativePort}/session`,{headers:{Origin:origin}}),pending=[];sockets.add(client);sockets.add(upstream);
  client.on("message",data=>{const text=data.toString(),request=JSON.parse(text);if(request.op==="fs.write"&&request.path===blocked)held.add(JSON.stringify(request.id));if(upstream.readyState===WebSocket.OPEN)upstream.send(text);else pending.push(text);});
  upstream.on("open",()=>{for(const value of pending)upstream.send(value);pending.length=0;});
  upstream.on("message",data=>{const text=data.toString(),reply=JSON.parse(text),send=()=>{if(client.readyState===WebSocket.OPEN)client.send(text);};if(held.delete(JSON.stringify(reply.id)))delayed.push(send);else send();});
  for(const [socket,other]of[[client,upstream],[upstream,client]]){socket.on("error",()=>{});socket.on("close",()=>{sockets.delete(socket);if(other.readyState===WebSocket.OPEN)other.close();});}
 });
 const endpoint=`ws://127.0.0.1:${proxy.address().port}/session`,persist=join(base,"objects");
 async function stop(){if(native?.exitCode===null&&native.signalCode===null){const exited=once(native,"exit");native.kill("SIGKILL");await exited;}}
 async function start(state="state"){native=spawn(resolve("../../native/session/target/debug/rayde-session"),["--root",root,"--state-root",join(base,state),"--port",String(nativePort),"--token","compute-secret","--origin",origin],{stdio:"ignore"});await listening(nativePort,native);}
 async function restartCloud(){await cloud?.mf.dispose();cloud=await fixture({persist,endpoint});}
 await start();await restartCloud();
 t.after(async()=>{for(const send of delayed.splice(0))send();await cloud?.mf.dispose();await stop();for(const socket of sockets)socket.terminate();await new Promise(resolve=>proxy.close(resolve));await rm(base,{recursive:true,force:true});});
 async function workspace(user){
  const opening=await(await cloud.fetch("/api/workspaces/open",{method:"POST",headers:user.headers,body:'{"repository":111}'})).json(),path="/api/workspaces/"+opening.id;
  await until(async()=> (await(await cloud.fetch(path,{headers:user.headers})).json()).status==="ready");
  const control=async(op,body={})=>{const ns=await cloud.mf.getDurableObjectNamespace("WORKSPACES"),response=await ns.get(ns.idFromName(opening.id)).fetch("https://internal/"+op,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner:user.session.user.id,...body})});return {status:response.status,body:await response.json()};};
  const connect=async()=>{const response=await cloud.fetch(path+"/socket",{headers:{...user.headers,Upgrade:"websocket"}});assert.equal(response.status,101);const socket=response.webSocket;socket.accept();const request=rpc(socket),hello=await request("hello");assert.equal(hello.fileMutations,1);return {socket,request};};
  return{path,control,connect};
 }
 return{get cloud(){return cloud;},workspace,start,stop,restartCloud,block(path){blocked=path;},release(){blocked=null;for(const send of delayed.splice(0))send();},get delayed(){return delayed.length;}};
}
async function seed(client,workspace,path,data){
 assert.equal((await client.request("fs.write",{path,data})).ok,true);
 assert.equal((await client.request("doc.open",{path})).ok,true);
 const update=await client.request("doc.update",{path,update:empty});assert.equal(update.ok,true,JSON.stringify(update));
 return(await workspace.control("journal",{id:update.durableUpdate.id})).body;
}
function content(record){const doc=new Y.Doc();Y.applyUpdate(doc,Buffer.from(record.checkpoint.update,"base64"));const value=doc.getText("text").toString();doc.destroy();return value;}

test("restore catalog excludes overwritten, moved, deleted and uncertain documents across restart",async t=>{
 const host=await setup(t),user=await signin(host.cloud.fetch),workspace=await host.workspace(user),a=await workspace.connect();
 const first=await seed(a,workspace,"src/a.hx","one");await seed(a,workspace,"src/b.hx","two");await seed(a,workspace,"src-other/c.hx","three");
 const source=first.manifest.source,plan=async(body={})=>{const response=await workspace.control("recovery/plan",{source,...body});assert.equal(response.status,200,JSON.stringify(response.body));return response.body;};
 let state=await plan();assert.equal(state.documents.length,3);assert.equal(state.automaticRestore,false);assert.equal(state.scope,"confirmed-document-heads");
 assert.equal((await workspace.control("recovery/plan",{source,owner:2})).status,403);
 assert.equal((await workspace.control("recovery/plan",{source,revision:"invalid"})).status,400);
 assert.equal((await host.cloud.fetch(workspace.path+"/recovery/plan",{headers:user.headers})).status,404);
 assert.equal((await plan({source:"x".repeat(43)})).documents.length,0);
 const revision=state.revision;await a.request("fs.write",{path:"src/a.hx",data:"new"});
 state=await plan();assert.ok(state.invalidated.some(row=>row.document.path==="src/a.hx"&&row.operation==="fs.write"));
 assert.equal((await workspace.control("recovery/plan",{source,revision})).status,409);
 const updated=await a.request("doc.update",{path:"src/a.hx",update:empty});assert.equal(updated.ok,true);
 assert.equal(content((await workspace.control("journal",{id:updated.durableUpdate.id})).body),"new");
 await a.request("doc.update",{path:"src/a.hx",update:empty});const repeat=await a.request("doc.update",{path:"src/a.hx",update:empty});
 await a.request("fs.write",{path:"src/a.hx",data:"new"});assert.ok((await plan()).invalidated.some(row=>row.document.path==="src/a.hx"));
 const same=await a.request("doc.update",{path:"src/a.hx",update:empty});assert.equal(same.durableUpdate.sequence,repeat.durableUpdate.sequence);assert.ok((await plan()).documents.some(row=>row.path==="src/a.hx"));
 const refused=await a.request("fs.remove",{path:"src",recursive:true});assert.equal(refused.code,"document-open");state=await plan();assert.equal(state.mutations.at(-1).outcome,"refused");assert.equal(state.documents.length,3);
 for(const path of["src/a.hx","src/b.hx","src-other/c.hx"])await a.request("doc.close",{path});
 await seed(a,workspace,"destination.hx","previous");await a.request("doc.close",{path:"destination.hx"});
 assert.equal((await a.request("fs.remove",{path:"destination.hx"})).ok,true);
 assert.equal((await a.request("fs.rename",{from:"src/a.hx",to:"destination.hx"})).ok,true);
 state=await plan();for(const path of["src/a.hx","destination.hx"])assert.ok(state.invalidated.some(row=>row.document.path===path&&row.operation==="fs.rename"));
 assert.ok(state.documents.some(row=>row.path==="src-other/c.hx"),"prefix matching must respect directory boundaries");
 assert.equal((await a.request("fs.remove",{path:"src",recursive:true})).ok,true);await a.request("fs.mkdir",{path:"src"});
 assert.ok((await plan()).invalidated.some(row=>row.document.path==="src/b.hx"),"recreating a directory cannot revive its older child snapshots");
 await seed(a,workspace,"src/a.hx","reborn");state=await plan();assert.ok(state.documents.some(row=>row.path==="src/a.hx"));assert.ok(state.invalidated.some(row=>row.document.path==="src/b.hx"));
 await seed(a,workspace,"history.hx","history");const saved=await a.request("doc.save",{path:"history.hx"});assert.equal(saved.ok,true,JSON.stringify(saved));
 const beforeImport=await plan(),snapshot=(await workspace.control("checkpoint",{id:saved.durable.id})).body.checkpoint;
 const doc=new Y.Doc();Y.applyUpdate(doc,Buffer.from(snapshot.update,"base64"));const vector=Y.encodeStateVector(doc);doc.getText("text").delete(0,1);
 const bytes=Buffer.from(Y.encodeStateAsUpdate(doc)),checkpoint={version:1,update:bytes.toString("base64"),sha256:createHash("sha256").update(bytes).digest("hex")};
 assert.equal((await workspace.control("checkpoint/import",{path:"history.hx",source,checkpoint})).status,200);
 state=await plan();assert.ok(state.invalidated.some(row=>row.document.path==="history.hx"&&row.outcome==="unconfirmed-record-change"));
 assert.equal((await workspace.control("recovery/plan",{source,revision:beforeImport.revision})).status,409);
 assert.equal((await a.request("doc.save",{path:"history.hx"})).ok,false,"Save cannot promote an imported deletion missing in compute, even with the same vector");
 const deletion=Buffer.from(Y.encodeStateAsUpdate(doc,vector)).toString("base64");assert.equal((await a.request("doc.update",{path:"history.hx",update:deletion})).ok,true);
 assert.equal((await a.request("doc.save",{path:"history.hx"})).ok,true);doc.destroy();
 assert.ok((await plan()).documents.some(row=>row.path==="history.hx"&&row.kind==="checkpoint"));
 host.block("src-other/c.hx");const lost=a.request("fs.write",{path:"src-other/c.hx",data:"uncertain"}).catch(()=>null);await until(()=>host.delayed===1);
 state=await plan();assert.ok(state.invalidated.some(row=>row.document.path==="src-other/c.hx"&&row.outcome==="pending"));
 await host.stop();await lost;await until(async()=> (await plan()).mutations.at(-1).outcome==="uncertain");host.release();await host.start();
 const b=await workspace.connect();await b.request("doc.open",{path:"src-other/c.hx"});assert.equal((await b.request("doc.update",{path:"src-other/c.hx",update:empty})).ok,true);
 assert.ok((await plan()).invalidated.some(row=>row.document.path==="src-other/c.hx"&&row.outcome==="uncertain"),"a later snapshot cannot erase an unresolved file-operation fence");
 b.socket.close();const retained=await plan();await host.restartCloud();assert.deepEqual(await plan(),retained);
 const c=await workspace.connect();let limited=false;
 for(let i=retained.mutations.length;i<=1024;i++){const reply=await c.request("fs.mkdir",{path:"budget"});if(reply.code==="filesystem-recovery-failed"){assert.match(reply.message,/mutation limit/);limited=true;break;}assert.equal(reply.ok,true);}
 assert.ok(limited);const full=await plan();assert.equal(full.mutations.length,1024);
 assert.equal((await c.request("fs.write",{path:"overflow.hx",data:"no"})).ok,false);assert.equal((await c.request("fs.stat",{path:"overflow.hx"})).entry,null);assert.equal((await plan()).revision,full.revision);
});

test("filesystem metadata and queued file payloads are bounded before compute side effects",async t=>{
 const host=await setup(t),user=await signin(host.cloud.fetch),workspace=await host.workspace(user),a=await workspace.connect();
 const initial=await seed(a,workspace,"keep.hx","keep"),source=initial.manifest.source;
 host.block("large.bin");const first=a.request("fs.write",{path:"large.bin",data:"z".repeat(9*1024*1024)});await until(()=>host.delayed===1);
 const overflow=await a.request("fs.write",{path:"overflow.bin",data:"z".repeat(9*1024*1024)});assert.equal(overflow.code,"filesystem-recovery-failed");assert.match(overflow.message,/queue/);
 host.release();assert.equal((await first).ok,true);assert.equal((await a.request("fs.stat",{path:"large.bin"})).entry.size,9*1024*1024);assert.equal((await a.request("fs.stat",{path:"overflow.bin"})).entry,null);
 let full=false;
 for(let i=0;i<1024;i++){const reply=await a.request("fs.remove",{path:"long-"+"x".repeat(3500)+i});if(reply.code==="filesystem-recovery-failed"){assert.match(reply.message,/metadata limit/);full=true;break;}assert.equal(reply.ok,false);}
 assert.ok(full);const plan=await workspace.control("recovery/plan",{source});assert.equal(plan.status,200);assert.ok(plan.body.mutations.length<1024);assert.ok(plan.body.documents.some(row=>row.path==="keep.hx"));
 const blockedPath="never-created/"+Array.from({length:35},()=>"p".repeat(100)).join("/")+"/file.hx";
 assert.equal((await a.request("fs.write",{path:blockedPath,data:"no"})).ok,false);assert.equal((await a.request("fs.stat",{path:"never-created"})).entry,null);
});
