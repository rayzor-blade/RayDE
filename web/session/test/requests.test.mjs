import test from "node:test";
import assert from "node:assert/strict";
import { SessionClient, Doc } from "../src/client.js";

globalThis.WebSocket = { OPEN:1 };

test("an unanswered browser request times out and releases its response slot", async () => {
  const client = new SessionClient({url:"ws://unused", timeout:20});
  client.socket = {readyState:1, send() {}};
  await assert.rejects(client.rawRequest("slow"), /did not answer slow/);
  assert.equal(client.waiting.size, 0);
  client.receive({id:1,ok:true});
  assert.equal(client.waiting.size, 0);
});

test("a failed send rejects and frees its timer; out-of-order answers settle independently", async () => {
  const client = new SessionClient({url:"ws://unused", timeout:100});
  client.socket = {readyState:1, send() { throw new Error("send failed"); }};
  await assert.rejects(client.rawRequest("broken"), /send failed/);
  assert.equal(client.waiting.size, 0);
  client.socket.send = () => {};
  const a = client.rawRequest("a"), b = client.rawRequest("b");
  client.receive({id:3,ok:true,value:"b"});
  client.receive({id:2,ok:true,value:"a"});
  assert.equal((await a).value, "a");
  assert.equal((await b).value, "b");
  assert.equal(client.waiting.size, 0);
});

test("saving a document waits for update acknowledgements and refuses offline saves", async () => {
  const calls = [], updates = [];
  const client = {ready:true, request(op) { calls.push(op); return op === "doc.update" ? new Promise(resolve => updates.push(resolve)) : Promise.resolve({}); }};
  const doc = new Doc(client,"a");
  doc.text.insert(0,"one"); doc.text.insert(3,"two");
  const saving = doc.save();
  assert.deepEqual(calls,["doc.update","doc.update"]);
  updates[1]({}); await Promise.resolve();
  assert.equal(calls.includes("doc.save"),false);
  updates[0]({}); await saving;
  assert.deepEqual(calls,["doc.update","doc.update","doc.save"]);
  client.ready = false; doc.text.insert(0,"offline");
  await assert.rejects(doc.save(),/Reconnect before saving/);
  assert.equal(doc.unsent,true);
  doc.ydoc.destroy();
});

test("a delayed acknowledgement cannot mark a later offline edit as synchronized", async () => {
  let acknowledge;
  const client = {ready:true,request:() => new Promise(resolve => { acknowledge = resolve; })};
  const doc = new Doc(client,"a");
  doc.text.insert(0,"sent");
  client.ready = false; doc.text.insert(4," offline");
  acknowledge({}); await Promise.all([...doc.pending]);
  assert.equal(doc.unsent,true);
  await assert.rejects(doc.save(),/Reconnect before saving/);
  doc.ydoc.destroy();
});

test("a process handle from an earlier connection cannot reach a reused remote PID", async () => {
  const sent = [], client = new SessionClient({url:"ws://unused",timeout:100});
  client.ready = true; client.generation = 2;
  client.socket = {readyState:1,send(text) { sent.push(JSON.parse(text)); }};
  for (const op of ["proc.spawn","proc.write","proc.close-input","proc.kill","term.open","term.write","term.resize","term.close","term.ack"]) {
    await assert.rejects(client.forward(op,{pid:1,sessionGeneration:1}),/disconnected session/);
  }
  assert.equal(sent.length,0);
  const killing = client.forward("proc.kill",{pid:1,signal:"KILL",sessionGeneration:2});
  assert.equal(sent.length,1); assert.equal("sessionGeneration" in sent[0],false);
  client.receive({id:sent[0].id,ok:true}); await killing;
  client.ready = false;
  await assert.rejects(client.forward("proc.kill",{pid:1,sessionGeneration:2}),/Not connected/);
  assert.equal(sent.length,1);
});
