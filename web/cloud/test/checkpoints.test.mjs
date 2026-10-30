import test from "node:test";
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {createHash} from "node:crypto";
import {mkdtemp,mkdir,writeFile,readFile,rm} from "node:fs/promises";
import {createServer} from "node:net";
import {tmpdir} from "node:os";
import {join,resolve} from "node:path";
import {fixture,signin,origin,listening} from "./fixture.mjs";

const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const freePort=()=>new Promise(resolve=>{const server=createServer().listen(0,"127.0.0.1",()=>{const port=server.address().port;server.close(()=>resolve(port));});});
async function ready(check){const end=Date.now()+10000;while(!await check()){if(Date.now()>end)throw Error("Timed out waiting for workspace");await pause(20);}}
function rpc(socket){
 let next=1;const waiting=new Map();
 socket.addEventListener("message",event=>{const reply=JSON.parse(event.data);waiting.get(reply.id)?.(reply);waiting.delete(reply.id);});
 return (op,params={})=>new Promise((resolve,reject)=>{
  const id=next++,timer=setTimeout(()=>{waiting.delete(id);reject(Error("Workspace timeout: "+op));},10000);
  waiting.set(id,reply=>{clearTimeout(timer);resolve(reply);});socket.send(JSON.stringify({...params,id,op}));
 });
}
async function hosted(fetch,user,path){
 const response=await fetch(path+"/socket",{headers:{...user.headers,Upgrade:"websocket"}});assert.equal(response.status,101);
 const socket=response.webSocket;socket.accept();const request=rpc(socket);
 const hello=await request("hello");assert.equal(hello.durableCheckpoints,true);
 return {socket,request,hello};
}
async function workspace(fetch,user){
 const opening=await(await fetch("/api/workspaces/open",{method:"POST",headers:user.headers,body:'{"repository":111}'})).json();
 const path="/api/workspaces/"+opening.id;
 await ready(async()=> (await(await fetch(path,{headers:user.headers})).json()).status==="ready");
 return {id:opening.id,path};
}
async function internal(mf,id,owner=1){
 const namespace=await mf.getDurableObjectNamespace("WORKSPACES"),stub=namespace.get(namespace.idFromName(id));
 return async(op,body={})=>{const response=await stub.fetch("https://internal/"+op,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner,...body})});return {status:response.status,body:await response.json()};};
}

test("hosted Save commits chunked recovery before acknowledgement and survives object/compute replacement",async t=>{
 const base=await mkdtemp(join(tmpdir(),"rayde-checkpoints-")),root=join(base,"workspace"),persist=join(base,"objects"),port=await freePort();
 await mkdir(root);await writeFile(join(root,"main.hx"),"before\n");let server,cloud;
 async function stop(){if(server?.exitCode===null && server.signalCode===null){const exited=once(server,"exit");server.kill();await exited;}}
 async function start(state){server=spawn(resolve("../../native/session/target/debug/rayde-session"),["--root",root,"--state-root",join(base,state),"--port",String(port),"--token","compute-secret","--origin",origin],{stdio:"ignore"});await listening(port,server);}
 t.after(async()=>{await cloud?.mf.dispose();await stop();await rm(base,{recursive:true,force:true});});
 await start("state");cloud=await fixture({persist,endpoint:`ws://127.0.0.1:${port}/session`});
 const user=await signin(cloud.fetch),project=await workspace(cloud.fetch,user),client=await hosted(cloud.fetch,user,project.path);
 const control=await internal(cloud.mf,project.id);
 assert.equal((await control("checkpoints")).body.ids.length,0);
 assert.equal((await client.request("doc.open",{path:"main.hx"})).ok,true);
 assert.equal((await client.request("doc.restore",{path:"main.hx",checkpoint:{}})).code,"denied");
 const content="saved 🦊\n"+"a line of Haxe source\n".repeat(12000);
 await client.request("fs.write",{path:"main.hx",data:content});
 await ready(async()=> (await client.request("doc.open",{path:"main.hx"})).text===content);
 const first=await client.request("doc.save",{path:"main.hx",checkpoint:false});
 assert.equal(first.ok,true,JSON.stringify(first));assert.ok(first.durable?.id);assert.equal(first.checkpoint,undefined);
 const saved=await control("checkpoint",{id:first.durable.id});
 assert.equal(saved.status,200,JSON.stringify(saved.body));assert.equal(saved.body.manifest.sha256,first.durable.sha256);assert.ok(saved.body.manifest.chunks>1);
 assert.equal((await control("checkpoint",{id:first.durable.id,owner:2})).status,403);
 assert.equal((await cloud.fetch(project.path+"/checkpoint",{headers:user.headers})).status,404);
 const saves=await Promise.all(Array.from({length:65},()=>client.request("doc.save",{path:"main.hx"})));
 assert.ok(saves.every(reply=>reply.ok && reply.durable.id===first.durable.id),"queued saves confirm durability without parallel snapshot allocation");
 const shorter="newer saved text\n";
 await client.request("fs.write",{path:"main.hx",data:shorter});
 await ready(async()=> (await client.request("doc.open",{path:"main.hx"})).text===shorter);
 const second=await client.request("doc.save",{path:"main.hx"});assert.equal(second.ok,true);assert.equal(second.durable.id,first.durable.id);
 assert.notEqual(second.durable.sha256,first.durable.sha256);
 const replay=await control("checkpoint/import",{path:"main.hx",source:saved.body.manifest.source,documentId:saved.body.manifest.documentId,checkpoint:saved.body.checkpoint});
 assert.equal(replay.status,200);assert.equal(replay.body.sha256,second.durable.sha256,"an older snapshot cannot undo newer deletions");
 const current=await control("checkpoint",{id:first.durable.id});
 assert.equal(current.body.manifest.chunks,1);
 const corrupt={...current.body.checkpoint,sha256:"corrupt"};
 assert.equal((await control("checkpoint/import",{path:"main.hx",source:saved.body.manifest.source,documentId:saved.body.manifest.documentId,checkpoint:corrupt})).status,422);
 assert.equal((await control("checkpoint",{id:first.durable.id})).body.manifest.sha256,second.durable.sha256);
 client.socket.close();await stop();await cloud.mf.dispose();
 await rm(root,{recursive:true});await rm(join(base,"state"),{recursive:true});
 cloud=await fixture({persist,endpoint:`ws://127.0.0.1:${port}/session`});
 const restoredControl=await internal(cloud.mf,project.id),retained=await restoredControl("checkpoint",{id:first.durable.id});
 assert.equal(retained.status,200);assert.deepEqual(retained.body.checkpoint,current.body.checkpoint);
 await mkdir(root);await writeFile(join(root,"main.hx"),"fresh checkout\n");await start("fresh-state");
 const direct=new WebSocket(`ws://127.0.0.1:${port}/session`);await new Promise((resolve,reject)=>{direct.addEventListener("open",resolve,{once:true});direct.addEventListener("error",reject,{once:true});});
 const request=rpc(direct);await request("hello",{token:"compute-secret"});
 assert.equal((await request("doc.restore",{path:"main.hx",checkpoint:retained.body.checkpoint})).ok,true);
 assert.equal((await request("doc.open",{path:"main.hx"})).text,shorter);direct.close();
 const reopened=await hosted(cloud.fetch,user,project.path);
 assert.notDeepEqual(reopened.hello.cacheIdentity,client.hello.cacheIdentity,"saved checkpoints alone do not claim full recovery-context continuity");
 assert.equal((await reopened.request("doc.open",{path:"main.hx"})).text,shorter);
 const newGeneration=await reopened.request("doc.save",{path:"main.hx"});assert.equal(newGeneration.ok,true);assert.notEqual(newGeneration.durable.id,first.durable.id);
 assert.equal((await restoredControl("checkpoints")).body.ids.length,2);
 assert.equal(await readFile(join(root,"main.hx"),"utf8"),shorter);
 const empty={version:1,update:"AAA=",sha256:createHash("sha256").update(Buffer.from([0,0])).digest("hex")};
 for(let index=2;index<512;index++)assert.equal((await restoredControl("checkpoint/import",{path:`record-${index}.hx`,source:retained.body.manifest.source,checkpoint:empty})).status,200);
 const limit=await restoredControl("checkpoint/import",{path:"overflow.hx",source:retained.body.manifest.source,checkpoint:empty});
 assert.equal(limit.status,507);assert.equal((await restoredControl("checkpoints")).body.ids.length,512);
 await reopened.request("fs.write",{path:"overflow.hx",data:"not durably saved\n"});
 assert.equal((await reopened.request("doc.open",{path:"overflow.hx"})).ok,true);
 const refused=await reopened.request("doc.save",{path:"overflow.hx"});
 assert.equal(refused.ok,false);assert.equal(refused.code,"checkpoint-failed");
 assert.ok(refused.message.includes("file was saved"));
 assert.equal((await restoredControl("checkpoint",{id:first.durable.id})).body.manifest.sha256,second.durable.sha256);
 const bob=await signin(cloud.fetch,"bob"),byteProject=await workspace(cloud.fetch,bob),byteControl=await internal(cloud.mf,byteProject.id,2);
 let prior,limited=false;
 for(let index=0;index<512;index++) {
  const imported=await byteControl("checkpoint/import",{path:`bytes-${index}.hx`,source:saved.body.manifest.source,checkpoint:saved.body.checkpoint});
  if(imported.status===507){assert.ok(imported.body.message.includes("storage limit"));limited=true;break;}
  assert.equal(imported.status,200);prior=imported.body;
 }
 assert.ok(limited,"aggregate byte limits apply before record-count limits");
 const usage=(await byteControl("checkpoints")).body;assert.ok(usage.bytes<=64*1024*1024 && usage.ids.length<512);
 assert.equal((await byteControl("checkpoint",{id:prior.id})).body.manifest.sha256,prior.sha256);
 reopened.socket.close();
});
