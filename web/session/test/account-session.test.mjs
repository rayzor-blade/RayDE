import test from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import {Accounts} from "../src/accounts.js";
import {followAccount} from "../src/account-session.js";
import {SessionClient} from "../src/client.js";

const encode = bytes => Buffer.from(bytes).toString("base64");
const identity = principal => ({version:1,authority:"cloud:fixture",workspace:"fixture",principal});
function workspace() {
  const server = new Y.Doc(), sockets = [], requests = [];
  server.getText("text").insert(0,"saved");
  let principal = "account:1";
  class Socket {
    static OPEN = 1;
    constructor() { this.readyState=1; sockets.push(this); queueMicrotask(()=>this.onopen?.()); }
    send(text) {
      const req=JSON.parse(text); requests.push(req);
      if(req.op==="waiting") return;
      let data={};
      if(req.op==="hello") data={cacheIdentity:identity(principal)};
      if(req.op==="doc.open") data={update:encode(Y.encodeStateAsUpdate(server,Buffer.from(req.vector,"base64"))),vector:encode(Y.encodeStateVector(server))};
      if(req.op==="doc.update") Y.applyUpdate(server,Buffer.from(req.update,"base64"));
      queueMicrotask(()=>this.onmessage?.({data:JSON.stringify({id:req.id,ok:true,...data})}));
    }
    close() { if(this.readyState===3)return; this.readyState=3; queueMicrotask(()=>this.onclose?.()); }
  }
  globalThis.WebSocket=Socket;
  const client=new SessionClient({url:"wss://editor.example/api/workspaces/fixture/socket",persist:false,timeout:1000});
  return {client,server,sockets,requests,as:account=>principal=account,async close(){client.close();await Promise.all([...client.docs.values()].map(doc=>doc.close()));server.destroy();}};
}

test("sign-out retains the running editor graph and offline edits, then resumes the same verified account",async()=>{
  const f=workspace(),events=[];let directoryClosed=false;
  f.client.recoveryDirectory.close=()=>directoryClosed=true;
  f.client.on("disconnected",event=>events.push(event));
  try {
    await f.client.connect();const doc=await f.client.openDoc("Main.hx"),graph=doc.ydoc,scope=f.client.workspace;
    const pending=assert.rejects(f.client.request("waiting"),/Signed out/);
    f.client.pauseAccount();await pending;
    assert.equal(f.client.ready,false);assert.equal(f.client.socket,null);assert.equal(f.client.waiting.size,0);
    assert.equal(events.at(-1).code,"signed-out");assert.equal(directoryClosed,false);
    const sent=f.requests.length;
    doc.text.insert(doc.text.length," + local draft");
    assert.equal(doc.unsent,true);assert.equal(f.requests.length,sent);assert.equal(f.server.getText("text").toString(),"saved");
    await assert.rejects(f.client.request("fs.read",{path:"private"}),/Not connected/);
    await f.client.resumeAccount();
    assert.equal(f.client.docs.get("Main.hx").ydoc,graph);assert.equal(f.client.workspace,scope);
    assert.equal(doc.text.toString(),"saved + local draft");assert.equal(f.server.getText("text").toString(),doc.text.toString());
    assert.equal(f.client.accountPaused,false);assert.equal(doc.unsent,false);
    await assert.rejects(f.client.forward("proc.kill",{pid:1,sessionGeneration:0}),/disconnected session/);
  } finally { await f.close(); }
});

test("signing in as another account fences the old graph before publishing any document state",async()=>{
  const f=workspace();
  try {
    await f.client.connect();const doc=await f.client.openDoc("Main.hx");
    f.client.pauseAccount();doc.text.insert(0,"private draft: ");
    const sent=f.requests.length;f.as("account:2");
    await assert.rejects(f.client.resumeAccount(),/workspace or account changed/);
    assert.equal(f.client.invalidated.code,"workspace-changed");assert.equal(f.client.ready,false);
    assert.deepEqual(f.requests.slice(sent).map(req=>req.op),["hello"]);
    assert.equal(doc.text.toString(),"private draft: saved");assert.equal(f.server.getText("text").toString(),"saved");
  } finally { await f.close(); }
});

test("queued reconnects cannot replace the socket after sign-out and sign-in",async()=>{
  const f=workspace();
  try {
    await f.client.connect();f.sockets[0].close();await new Promise(resolve=>setImmediate(resolve));
    f.client.pauseAccount();await f.client.resumeAccount();
    const socket=f.client.socket;await new Promise(resolve=>setTimeout(resolve,300));
    assert.equal(f.sockets.length,2);assert.equal(f.client.socket,socket);assert.equal(f.client.ready,true);
  } finally { await f.close(); }
});

test("sign-out cancels an unfinished connection without a later timeout or handshake restoring it",async()=>{
  const f=workspace();
  try {
    const pending=assert.rejects(f.client.connect(),/Signed out/);
    f.client.pauseAccount();await pending;await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.client.cancelConnection,null);assert.equal(f.client.waiting.size,0);assert.equal(f.client.ready,false);
    assert.equal(f.requests.length,0);await f.client.resumeAccount();assert.equal(f.client.ready,true);
  } finally { await f.close(); }
});

test("hosted account notifications pause and resume in place; unrelated local sessions are left alone",async()=>{
  const account=new Accounts(),changes=[],f=workspace();
  try {
    await f.client.connect();
    const stop=followAccount(account,f.client,status=>changes.push(status));
    account.changed(null);assert.equal(f.client.accountPaused,true);
    account.changed({id:1});await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.client.ready,true);assert.equal(f.sockets.length,2);
    stop();account.changed(null);assert.equal(f.client.ready,true);assert.equal(changes.length,2);
    const local=followAccount(account,null,status=>changes.push(status));
    account.changed(null);assert.equal(f.client.ready,true);local();
  } finally { await f.close(); }
});
