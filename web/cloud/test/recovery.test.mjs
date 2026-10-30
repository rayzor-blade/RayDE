import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {createRequire} from "node:module";
import {signin} from "./fixture.mjs";
import {setup,seed,until,empty} from "./recovery-fixture.mjs";
const require=createRequire(new URL("../../session/package.json",import.meta.url)),Y=require("yjs");
function content(record){const doc=new Y.Doc();Y.applyUpdate(doc,Buffer.from(record.checkpoint.update,"base64"));const value=doc.getText("text").toString();doc.destroy();return value;}

test("restore catalog excludes overwritten, moved, deleted and uncertain documents across restart",async t=>{
 const host=await setup(t),user=await signin(host.cloud.fetch),workspace=await host.workspace(user),a=await workspace.connect();
 assert.equal((await a.request("doc.lookup",{path:"src/a.hx"})).code,"unsupported");
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
 const beforeImport=await plan(),savedRecord=(await workspace.control("checkpoint",{id:saved.durable.id})).body,snapshot=savedRecord.checkpoint;
 const doc=new Y.Doc();Y.applyUpdate(doc,Buffer.from(snapshot.update,"base64"));const vector=Y.encodeStateVector(doc);doc.getText("text").delete(0,1);
 const bytes=Buffer.from(Y.encodeStateAsUpdate(doc)),checkpoint={version:1,update:bytes.toString("base64"),sha256:createHash("sha256").update(bytes).digest("hex")};
 assert.equal((await workspace.control("checkpoint/import",{path:"history.hx",source,documentId:savedRecord.manifest.documentId,checkpoint})).status,200);
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
