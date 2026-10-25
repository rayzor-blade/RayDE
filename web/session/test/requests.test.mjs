import test from "node:test";
import assert from "node:assert/strict";
import { SessionClient } from "../src/client.js";

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
