import { test } from "node:test";
import assert from "node:assert/strict";
import { pageEntry } from "../src/entry.js";
const entry = href => pageEntry({href});
test("the public site boots a demo and the app root keeps a signed-in workspace entry", () => {
  assert.equal(entry("https://rayde.org/").demo,true);
  assert.equal(entry("https://www.rayde.org/").demo,true);
  assert.equal(entry("https://app.rayde.org/").demo,false);
  assert.equal(entry("http://127.0.0.1:8787/").demo,false);
  assert.equal(entry("http://127.0.0.1:8731/?demo=1").demo,true);
  assert.equal(entry("https://rayde.org/?demo=0").demo,false);
});
test("a workspace path selects its own authenticated socket without exposing credentials in the URL", () => {
  const id="a".repeat(43), route=entry("https://app.rayde.org/"+id);
  assert.equal(route.workspace,id);assert.equal(route.endpoint,`wss://app.rayde.org/api/workspaces/${id}/socket`);assert.equal(route.demo,false);
  assert.equal(entry("http://127.0.0.1:8787/"+id).endpoint,`ws://127.0.0.1:8787/api/workspaces/${id}/socket`);
  assert.equal(entry("https://app.rayde.org/not-a-session").workspace,null);
  assert.equal(entry("https://rayde.org/"+id).workspace,null);
  assert.equal(entry("https://rayde.org/?session=wss://remote.example/session").demo,false);
});
