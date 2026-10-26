import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdir,readFile,rm} from "node:fs/promises";
import {dirname,join} from "node:path";
import {signin} from "./fixture.mjs";
import {setup,seed,until} from "./recovery-fixture.mjs";

const digest=bytes=>createHash("sha256").update(bytes).digest("hex");
async function context(t){
 const host=await setup(t),user=await signin(host.cloud.fetch),workspace=await host.workspace(user),client=await workspace.connect();
 const initial=await seed(client,workspace,"scope.hx","scope"),source=initial.manifest.source;
 await client.request("doc.close",{path:"scope.hx"});
 const plan=async()=>{const result=await workspace.control("recovery/plan",{source});assert.equal(result.status,200,JSON.stringify(result.body));return result.body;};
 const file=async(mutation,extra={})=>workspace.control("recovery/file",{source,mutation,revision:(await plan()).revision,...extra});
 return{host,user,workspace,client,source,plan,file};
}

test("private file payloads preserve binary, Unicode and empty writes across object and compute loss",async t=>{
 const {host,user,workspace,client,source,plan,file}=await context(t);
 const examples=[
  ["assets/logo.svg",Buffer.from('<svg><text>RayDE 🦊 日本語</text></svg>')],
  ["assets/image.bin",Buffer.from(Array.from({length:200000},(_,i)=>i%256))],
  ["empty.txt",Buffer.alloc(0)],
 ];
 let observed=0;
 host.observeWrites(async request=>{
  const bytes=Buffer.from(request.data,request.encoding==="base64"?"base64":"utf8"),state=await plan(),operation=state.mutations.at(-1);
  assert.equal(operation.outcome,"pending");assert.equal(operation.payload.sha256,digest(bytes));
  const bucket=await host.cloud.mf.getR2Bucket("WORKSPACE_FILES"),key=(await bucket.list()).objects.find(object=>object.key.endsWith(digest(bytes))).key;
  assert.deepEqual(Buffer.from(await(await bucket.get(key)).arrayBuffer()),bytes);observed++;
 });
 const receipts=[];
 for(const[path,bytes]of examples){
  const reply=await client.request("fs.write",{path,data:bytes.toString("base64"),encoding:"base64"});assert.equal(reply.ok,true,JSON.stringify(reply));
  assert.deepEqual(Object.keys(reply.recoveryMutation),["id"]);receipts.push(reply.recoveryMutation.id);
 }
 assert.equal(observed,examples.length,"durable intent and verified bytes precede forwarding to compute");host.observeWrites(null);
 let state=await plan();assert.equal(state.automaticRestore,false);
 for(let i=0;i<examples.length;i++){
  const record=state.mutations.find(row=>row.id===receipts[i]);assert.deepEqual(record.payload,{sha256:digest(examples[i][1]),bytes:examples[i][1].length});
  const exported=await file(receipts[i]);assert.equal(exported.status,200);assert.equal(exported.body.scope,"operation-payload");assert.equal(exported.body.automaticRestore,false);
  assert.deepEqual(Buffer.from(exported.body.data,"base64"),examples[i][1]);
 }
 const before=state.filesystemPayloads;
 assert.equal((await client.request("fs.write",{path:"copy.bin",data:examples[1][1].toString("base64"),encoding:"base64"})).ok,true);
 assert.deepEqual((await plan()).filesystemPayloads,before,"identical bytes reserve one object within a workspace");
 assert.equal((await file(receipts[0],{source:"x".repeat(43)})).status,404);
 assert.equal((await file(receipts[0],{owner:2})).status,403);
 assert.equal((await file(receipts[0],{revision:state.revision})).status,409);
 assert.equal((await file(receipts[0],{revision:null})).status,400);
 assert.equal((await file(receipts[0],{mutation:0})).status,400);
 assert.equal((await host.cloud.fetch(workspace.path+"/recovery/file",{headers:user.headers})).status,404);
 const directory=await client.request("fs.mkdir",{path:"directory"});assert.equal((await file(directory.recoveryMutation.id)).status,409);
 const bob=await signin(host.cloud.fetch,"bob"),other=await host.workspace(bob),guest=await other.connect();
 const otherPlan=(await other.control("recovery/plan",{source})).body;assert.equal(otherPlan.filesystemPayloads.bytes,0);
 assert.equal((await other.control("recovery/file",{source,mutation:receipts[0],revision:otherPlan.revision})).status,404);
 assert.equal((await guest.request("fs.write",{path:"other.svg",data:examples[0][1].toString("base64"),encoding:"base64"})).ok,true);
 const scoped=await host.cloud.mf.getR2Bucket("WORKSPACE_FILES");
 assert.equal((await scoped.list()).objects.filter(object=>object.key.endsWith(digest(examples[0][1]))).length,2,"separate workspaces do not share blob keys or quota");
 guest.socket.close();
 assert.equal((await client.request("fs.rename",{from:"assets",to:"moved"})).ok,true);
 assert.equal((await client.request("fs.remove",{path:"moved",recursive:true})).ok,true);
 assert.equal((await file(receipts[0])).status,200,"historical operation bytes survive a later rename/delete");
 client.socket.close();await host.stop();await rm(host.root,{recursive:true});await rm(join(dirname(host.root),"state"),{recursive:true});
 await host.restartCloud();
 for(let i=0;i<examples.length;i++)assert.deepEqual(Buffer.from((await file(receipts[i])).body.data,"base64"),examples[i][1]);
 await mkdir(host.root);await host.start("replacement");const replacement=await workspace.connect();
 for(let i=0;i<examples.length;i++){
  const recovered=(await file(receipts[i])).body;
  assert.equal((await replacement.request("fs.write",{path:"recovered/"+examples[i][0],data:recovered.data,encoding:recovered.encoding})).ok,true);
  assert.deepEqual(await readFile(join(host.root,"recovered",examples[i][0])),examples[i][1]);
 }
 assert.equal((await workspace.control("recovery/plan",{source})).body.automaticRestore,false,"operation export is not complete workspace restoration");
});

test("missing, corrupt and unavailable payload storage fail closed before compute writes",async t=>{
 const {host,workspace,client,source,plan,file}=await context(t),data="first 🦊",bytes=Buffer.from(data);
 const first=await client.request("fs.write",{path:"file.txt",data});assert.equal(first.ok,true);
 await client.request("fs.write",{path:"file.txt",data:"keep"});
 const bucket=await host.cloud.mf.getR2Bucket("WORKSPACE_FILES"),key=(await bucket.list()).objects.find(object=>object.key.endsWith(digest(bytes))).key;
 await bucket.put(key,Buffer.alloc(bytes.length,120));
 assert.equal((await file(first.recoveryMutation.id)).status,503,"same-sized corruption is rejected by digest");
 const prior=await plan(),refused=await client.request("fs.write",{path:"file.txt",data});assert.equal(refused.ok,false);assert.equal(refused.code,"filesystem-recovery-failed");
 assert.equal(await readFile(join(host.root,"file.txt"),"utf8"),"keep");
 let state=await plan();assert.equal(state.mutations.at(-1).outcome,"refused");assert.equal(state.mutations.at(-1).code,"payload-unavailable");assert.deepEqual(state.filesystemPayloads,prior.filesystemPayloads);
 assert.equal((await file(state.mutations.at(-1).id)).status,409);
 await bucket.delete(key);assert.equal((await file(first.recoveryMutation.id)).status,503);
 assert.equal((await client.request("fs.write",{path:"file.txt",data})).ok,true,"a missing object can be uploaded again within its existing reservation");
 assert.deepEqual((await plan()).filesystemPayloads,prior.filesystemPayloads);
 const revision=(await plan()).revision;
 assert.equal((await client.request("fs.write",{path:"invalid.bin",data:"not base64!",encoding:"base64"})).ok,false);
 assert.equal((await plan()).revision,revision);assert.equal((await client.request("fs.stat",{path:"invalid.bin"})).entry,null);
 host.block("interrupted.txt");const pending=client.request("fs.write",{path:"interrupted.txt",data:"pending"}).catch(()=>null);await until(()=>host.delayed===1);
 state=await plan();const operation=state.mutations.at(-1);assert.equal(operation.outcome,"pending");
 const uploaded=(await bucket.list()).objects.find(object=>object.key.endsWith(digest(Buffer.from("pending"))));assert.ok(uploaded,"payload exists before the compute reply");
 assert.equal((await file(operation.id)).status,409);await host.stop();await pending;
 await until(async()=> (await plan()).mutations.at(-1).outcome==="uncertain");assert.equal((await file(operation.id)).status,409);host.release();await host.start();
 await host.restartCloud({files:false});const offline=await workspace.connect(),before=await plan();
 const missing=await offline.request("fs.write",{path:"unconfigured.txt",data:"no"});assert.equal(missing.ok,false);assert.match(missing.message,/storage is not configured/);
 assert.equal((await plan()).revision,before.revision);assert.equal((await offline.request("fs.stat",{path:"unconfigured.txt"})).entry,null);
 assert.equal((await workspace.control("recovery/file",{source,mutation:first.recoveryMutation.id,revision:before.revision})).status,503);
});

test("payload byte reservations survive overwrite and restart and reject overflow before upload",async t=>{
 const {host,workspace,client,plan}=await context(t);
 for(let i=0;i<6;i++)assert.equal((await client.request("fs.write",{path:"large.bin",data:String(i).repeat(10*1024*1024)})).ok,true);
 const full=await plan(),bucket=await host.cloud.mf.getR2Bucket("WORKSPACE_FILES"),objects=(await bucket.list()).objects.length;
 const limited=await client.request("fs.write",{path:"overflow.bin",data:"overflow".repeat(1024*1024)});assert.equal(limited.ok,false);assert.match(limited.message,/storage limit/);
 assert.equal((await client.request("fs.stat",{path:"overflow.bin"})).entry,null);assert.equal((await bucket.list()).objects.length,objects);
 assert.equal((await plan()).revision,full.revision);assert.ok(full.filesystemPayloads.bytes<=full.filesystemPayloads.maxBytes);
 const oversized=await client.request("fs.write",{path:"oversized.bin",data:"x".repeat(12*1024*1024+1)});assert.equal(oversized.ok,false);assert.match(oversized.message,/payload limit/);
 assert.equal((await client.request("fs.stat",{path:"oversized.bin"})).entry,null);
 client.socket.close();await host.restartCloud();const next=await workspace.connect();
 assert.deepEqual((await plan()).filesystemPayloads,full.filesystemPayloads);
 assert.equal((await next.request("fs.write",{path:"dedup.bin",data:"0".repeat(10*1024*1024)})).ok,true);
 assert.deepEqual((await plan()).filesystemPayloads,full.filesystemPayloads,"reserved bytes count all retained versions, with dedup on retry");
});
