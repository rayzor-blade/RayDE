import { test } from "node:test";
import assert from "node:assert/strict";
import { Accounts } from "../src/accounts.js";

test("the browser keeps credentials in same-origin cookies and sends CSRF only to its edge", async () => {
  const calls = [], navigations = [];
  const account = new Accounts({
    location: { href: "https://editor.example/?old=1#token=old", origin: "https://editor.example", assign: url => navigations.push(url) },
    later: fn => fn(),
    fetch: async (url, init) => {
      calls.push({ url, init });
      return Response.json(url === "/api/session" ? { user: { id: 1, login: "alice" }, csrf: "test-csrf", installUrl: "https://github.com/apps/rayde/installations/new" } : {});
    },
  });
  const status = await account.request("account.status", {});
  assert.equal(status.user.login, "alice");
  assert.equal(status.csrf, undefined);
  await account.request("account.open", { repository: 111 });
  assert.equal(calls[1].init.credentials, "same-origin");
  assert.equal(calls[1].init.headers["X-RayDE-CSRF"], "test-csrf");
  assert.equal(JSON.parse(calls[1].init.body).repository, 111);
  await account.request("account.connect", { workspace: "a".repeat(43), project: "build.hxml" });
  const url = new URL(navigations[0]);
  assert.equal(url.origin, "https://editor.example");
  assert.equal(url.hash, "");
  assert.equal(url.pathname,"/" + "a".repeat(43));
  assert.equal(url.searchParams.get("session"),null);
  assert.equal(url.searchParams.get("project"),null);
  await assert.rejects(() => account.request("account.connect", { workspace: "https://evil.invalid" }));
});

test("a browser without an account can show sign-in without fabricating a local workspace", async () => {
  const navigations = [];
  const account = new Accounts({ fetch: async () => new Response("", { status: 401 }), later: fn => fn(), location: { assign: url => navigations.push(url) } });
  assert.deepEqual(await account.request("account.status", {}), { user: null, installable: false });
  await account.request("account.signin", {});
  assert.deepEqual(navigations, ["/auth/github/start"]);
});


test("the public demo sends sign-in to the app without querying private account APIs", async () => {
  const navigations=[];
  const account=new Accounts({fetch:async()=>{throw new Error("public demo queried an account");},later:fn=>fn(),location:{href:"https://rayde.org/",assign:url=>navigations.push(url)}});
  assert.deepEqual(await account.request("account.status",{}),{user:null,installable:false});
  await account.request("account.signin",{});
  assert.deepEqual(navigations,["https://app.rayde.org/auth/github/start"]);
});
