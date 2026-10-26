import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {createRequire} from "node:module";
import {createServer} from "node:net";
import {mkdtemp,rm} from "node:fs/promises";
import {join,resolve} from "node:path";
import {tmpdir} from "node:os";
import {fixture,signin,origin,listening} from "./fixture.mjs";
const require=createRequire(new URL("../../session/package.json",import.meta.url)),{WebSocketServer,WebSocket}=require("ws");
export const empty="AAA=";
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export async function until(check){const end=Date.now()+12000;while(!await check()){if(Date.now()>end)throw Error("Recovery test did not settle");await pause(20);}}
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
export async function setup(t,settings={}){
 const base=await mkdtemp(join(tmpdir(),"rayde-restore-catalog-")),nativePort=await port(),root=join(base,"workspace");
 const {mkdir}=await import("node:fs/promises");await mkdir(root);
 let native,cloud,blocked=null,observer=null;const delayed=[],sockets=new Set(),held=new Set();
 const proxy=new WebSocketServer({host:"127.0.0.1",port:0});await once(proxy,"listening");
 proxy.on("connection",client=>{
  const upstream=new WebSocket(`ws://127.0.0.1:${nativePort}/session`,{headers:{Origin:origin}}),pending=[];sockets.add(client);sockets.add(upstream);
  client.on("message",data=>{const text=data.toString(),request=JSON.parse(text);if(request.op==="fs.write"&&request.path===blocked)held.add(JSON.stringify(request.id));const send=()=>{if(upstream.readyState===WebSocket.OPEN)upstream.send(text);else pending.push(text);};if(observer&&request.op==="fs.write")Promise.resolve().then(()=>observer(request)).then(send,()=>client.close());else send();});
  upstream.on("open",()=>{for(const value of pending)upstream.send(value);pending.length=0;});
  upstream.on("message",data=>{const text=data.toString(),reply=JSON.parse(text),send=()=>{if(client.readyState===WebSocket.OPEN)client.send(text);};if(held.delete(JSON.stringify(reply.id)))delayed.push(send);else send();});
  for(const [socket,other]of[[client,upstream],[upstream,client]]){socket.on("error",()=>{});socket.on("close",()=>{sockets.delete(socket);if(other.readyState===WebSocket.OPEN)other.close();});}
 });
 const endpoint=`ws://127.0.0.1:${proxy.address().port}/session`,persist=join(base,"objects");
 async function stop(){if(native?.exitCode===null&&native.signalCode===null){const exited=once(native,"exit");native.kill("SIGKILL");await exited;}}
 async function start(state="state"){native=spawn(resolve("../../native/session/target/debug/rayde-session"),["--root",root,"--state-root",join(base,state),"--port",String(nativePort),"--token","compute-secret","--origin",origin],{stdio:"ignore"});await listening(nativePort,native);}
 async function restartCloud(next={}){Object.assign(settings,next);await cloud?.mf.dispose();cloud=await fixture({persist,endpoint,...settings});}
 await start();await restartCloud();
 t.after(async()=>{for(const send of delayed.splice(0))send();await cloud?.mf.dispose();await stop();for(const socket of sockets)socket.terminate();await new Promise(resolve=>proxy.close(resolve));await rm(base,{recursive:true,force:true});});
 async function workspace(user){
  const opening=await(await cloud.fetch("/api/workspaces/open",{method:"POST",headers:user.headers,body:'{"repository":111}'})).json(),path="/api/workspaces/"+opening.id;
  await until(async()=> (await(await cloud.fetch(path,{headers:user.headers})).json()).status==="ready");
  const control=async(op,body={})=>{const ns=await cloud.mf.getDurableObjectNamespace("WORKSPACES"),response=await ns.get(ns.idFromName(opening.id)).fetch("https://internal/"+op,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({owner:user.session.user.id,...body})});return {status:response.status,body:await response.json()};};
  const connect=async()=>{const response=await cloud.fetch(path+"/socket",{headers:{...user.headers,Upgrade:"websocket"}});assert.equal(response.status,101);const socket=response.webSocket;socket.accept();const request=rpc(socket),hello=await request("hello");assert.equal(hello.fileMutations,1);return {socket,request};};
  return{path,control,connect};
 }
 return{root,get cloud(){return cloud;},workspace,start,stop,restartCloud,observeWrites(callback){observer=callback;},block(path){blocked=path;},release(){blocked=null;for(const send of delayed.splice(0))send();},get delayed(){return delayed.length;}};
}
export async function seed(client,workspace,path,data){
 assert.equal((await client.request("fs.write",{path,data})).ok,true);
 assert.equal((await client.request("doc.open",{path})).ok,true);
 const update=await client.request("doc.update",{path,update:empty});assert.equal(update.ok,true,JSON.stringify(update));
 return(await workspace.control("journal",{id:update.durableUpdate.id})).body;
}
