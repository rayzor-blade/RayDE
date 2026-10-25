import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fixture, signin, challenge, origin } from "./fixture.mjs";

test("Rust edge binds GitHub PKCE/state to the browser and consumes it once", async t => {
  const { mf, fetch, calls } = await fixture(); t.after(() => mf.dispose());
  assert.equal((await fetch("/api/session")).status, 401);
  const user = await signin(fetch);
  assert.equal(user.authorize.origin, "https://github.com");
  assert.equal(user.authorize.searchParams.get("code_challenge_method"), "S256");
  assert.equal(challenge(calls.exchanges[0].code_verifier), user.authorize.searchParams.get("code_challenge"));
  assert.match(user.cookie, /HttpOnly; SameSite=Lax/);
  assert.equal(user.session.user.login, "alice");
  assert.ok(!JSON.stringify(user.session).includes("access-alice"));
  assert.ok(!user.response.headers.get("Location").includes("access-"));
  assert.equal((await fetch(user.callback, { headers: { Cookie: user.oauthCookie } })).status, 401);
  const start = await fetch("/auth/github/start", { redirect: "manual" });
  const callback = `/auth/github/callback?state=${new URL(start.headers.get("Location")).searchParams.get("state")}&code=alice`;
  assert.equal((await fetch(callback)).status, 403);
});

test("repository access, pagination, CSRF, and workspace ownership are enforced at the Rust edge", async t => {
  const { mf, fetch, calls } = await fixture(); t.after(() => mf.dispose());
  const alice = await signin(fetch), bob = await signin(fetch, "bob");
  const first = await (await fetch("/api/repositories", { headers: alice.headers })).json();
  assert.equal(first.repositories.length, 100);
  assert.ok(first.cursor);
  const second = await (await fetch("/api/repositories?cursor=" + encodeURIComponent(first.cursor), { headers: alice.headers })).json();
  assert.equal(second.repositories[0].id, 999); assert.equal(second.cursor, null);
  const open = headers => fetch("/api/workspaces/open", { method: "POST", headers, body: JSON.stringify({ repository: 111 }) });
  assert.equal((await open({ Cookie: alice.cookie })).status, 403);
  assert.equal((await open({ ...alice.headers, Origin: "https://evil.invalid" })).status, 403);
  assert.equal((await fetch("/api/workspaces/open", { method: "POST", headers: alice.headers, body: '{"repository":666}' })).status, 403);
  const opening = await (await open(alice.headers)).json();
  assert.equal(opening.status, "preparing");
  assert.match(opening.id, /^[\w-]{43}$/);
  let state;
  for (let i = 0; i < 100; i++) {
    state = await (await fetch("/api/workspaces/" + opening.id, { headers: alice.headers })).json();
    if (state.status !== "preparing") break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal(state.status, "ready", JSON.stringify(state));
  assert.equal(state.project, "build.hxml");
  assert.ok(!JSON.stringify(state).includes("compute-secret"));
  assert.ok(!JSON.stringify(state).includes("access-alice"));
  assert.equal(calls.runner.length, 1);
  assert.equal(calls.runner[0].checkout.accessToken, "access-alice");
  assert.equal((await fetch("/api/workspaces/" + opening.id, { headers: bob.headers })).status, 403);
  assert.equal((await (await open(alice.headers)).json()).id, opening.id);
  assert.equal(calls.runner.length, 1);
  assert.equal((await fetch("/api/logout", { method: "POST", headers: alice.headers, body: "{}" })).status, 200);
  assert.equal((await fetch("/api/session", { headers: alice.headers })).status, 401);
  assert.equal((await fetch("/api/session", { headers: bob.headers })).status, 200);
});

test("account and workspace records survive a local Durable Object restart", async t => {
  const persist = await mkdtemp(join(tmpdir(), "rayde-cloud-"));
  t.after(() => rm(persist, { recursive: true, force: true }));
  let first = await fixture({ persist });
  const user = await signin(first.fetch);
  const opening = await (await first.fetch("/api/workspaces/open", { method: "POST", headers: user.headers, body: '{"repository":111}' })).json();
  await new Promise(resolve => setTimeout(resolve, 150));
  await first.mf.dispose();
  const second = await fixture({ persist }); t.after(() => second.mf.dispose());
  const saved = await (await second.fetch("/api/session", { headers: user.headers })).json();
  assert.equal(saved.user.id, user.session.user.id);
  assert.equal(saved.csrf, user.session.csrf);
  const state = await (await second.fetch("/api/workspaces/" + opening.id, { headers: user.headers })).json();
  assert.equal(state.status, "ready");
  assert.equal(second.calls.runner.length, 0);
});

test("expired GitHub access tokens are refreshed before repository access", async t => {
  const { mf, fetch, calls } = await fixture(); t.after(() => mf.dispose());
  const user = await signin(fetch, "refresh");
  assert.equal((await fetch("/api/repositories", { headers: user.headers })).status, 200);
  assert.equal(calls.exchanges[1].grant_type, "refresh_token");
  assert.equal(calls.api.at(-1).token, "Bearer access-alice-refreshed");
});


test("a failed compute start can retry without allocating another workspace", async t => {
  const { mf, fetch, calls } = await fixture({failProvisionOnce:true}); t.after(() => mf.dispose());
  const user=await signin(fetch);
  const open=()=>fetch("/api/workspaces/open",{method:"POST",headers:user.headers,body:'{"repository":111}'}).then(r=>r.json());
  const first=await open();
  async function settled() {for(let i=0;i<100;i++) {const state=await (await fetch("/api/workspaces/"+first.id,{headers:user.headers})).json();if(state.status!=="preparing")return state;await new Promise(resolve=>setTimeout(resolve,10));}throw new Error("provisioning did not settle");}
  assert.equal((await settled()).status,"failed");
  const retry=await open();assert.equal(retry.id,first.id);assert.equal(retry.status,"preparing");
  assert.equal((await settled()).status,"ready");
  assert.equal(calls.runner.length,2);assert.equal(calls.runner[0].id,calls.runner[1].id);
});


test("workspace pages keep their short URL through sign-in and enforce ownership", async t => {
  const {mf,fetch}=await fixture();t.after(()=>mf.dispose());
  const alice=await signin(fetch), bob=await signin(fetch,"bob");
  const workspace=await (await fetch("/api/workspaces/open",{method:"POST",headers:alice.headers,body:'{"repository":111}'})).json();
  const page=await fetch("/"+workspace.id,{redirect:"manual"});
  assert.equal(page.status,302);
  assert.equal(new URL(page.headers.get("Location")).searchParams.get("workspace"),workspace.id);
  const again=await signin(fetch,"alice",workspace.id);
  assert.equal(again.response.headers.get("Location"),origin+"/"+workspace.id);
  assert.equal((await fetch("/"+workspace.id,{headers:again.headers})).status,200);
  assert.equal((await fetch("/"+workspace.id,{headers:bob.headers})).status,403);
  assert.equal((await fetch("/auth/github/start?workspace=https://evil.invalid")).status,400);
  const fromLanding=await mf.dispatchFetch("https://rayde.org/auth/github/start",{redirect:"manual"});
  assert.equal(fromLanding.status,302);assert.equal(fromLanding.headers.get("Location"),origin+"/auth/github/start");
});
