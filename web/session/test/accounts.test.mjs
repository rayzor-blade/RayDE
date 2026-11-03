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
  await account.request("account.create",{key:"a".repeat(64),project:{name:"my-project",private:true}});
  assert.equal(calls[2].url,"/api/projects/create/"+"a".repeat(64));
  assert.equal(calls[2].init.headers["X-RayDE-CSRF"],"test-csrf");
  assert.deepEqual(JSON.parse(calls[2].init.body),{name:"my-project",private:true});
  await assert.rejects(account.request("account.create",{key:"../outside"}),/Invalid project request/);
  await account.request("account.connect", { workspace: "a".repeat(43), project: "build.hxml" });
  const url = new URL(navigations[0]);
  assert.equal(url.origin, "https://editor.example");
  assert.equal(url.hash, "");
  assert.equal(url.pathname,"/" + "a".repeat(43));
  assert.equal(url.searchParams.get("session"),null);
  assert.equal(url.searchParams.get("project"),null);
  await assert.rejects(() => account.request("account.connect", { workspace: "https://evil.invalid" }));
});

test("sign-in preserves the editor and verifies the cookie session after a popup notification", async () => {
  const opened=[],navigations=[];let channel,authenticated=false;
  const account=new Accounts({location:{href:"https://editor.example/",assign:url=>navigations.push(url)},
    fetch:async()=>authenticated?Response.json({user:{login:"alice"},csrf:"verified-csrf"}):new Response("",{status:401}),
    open:(url,...rest)=>{opened.push({url,rest});return{closed:true};},
    broadcast:name=>channel={name,closed:false,close(){this.closed=true;}}
  });
  assert.deepEqual(await account.request("account.status",{}),{user:null,installable:false});
  const pending=account.request("account.signin",{});
  assert.equal(opened.length,1);assert.deepEqual(navigations,[]);
  const id=new URL(opened[0].url,"https://editor.example").searchParams.get("popup");
  assert.match(id,/^[a-f0-9]{64}$/);assert.equal(channel.name,"rayde-auth:"+id);
  await channel.onmessage({data:{type:"rayde-auth-complete",channel:"wrong",status:"success"}});
  assert.equal(channel.closed,false);
  authenticated=true;
  await channel.onmessage({data:{type:"rayde-auth-complete",channel:id,status:"success",user:{login:"forged"}}});
  assert.deepEqual(await pending,{user:{login:"alice"},installable:false});
  assert.equal(account.csrf,"verified-csrf");assert.equal(channel.closed,true);assert.deepEqual(navigations,[]);
});

test("blocked and cancelled sign-in windows report errors without navigating the editor",async()=>{
  const channels=[];const broadcast=name=>{const channel={name,close(){this.closed=true;}};channels.push(channel);return channel;};
  const blocked=new Accounts({open:()=>null,broadcast});
  await assert.rejects(blocked.request("account.signin",{}),/Allow the GitHub sign-in window/);assert.equal(channels[0].closed,true);
  const account=new Accounts({open:()=>({close(){}}),broadcast});
  const pending=account.request("account.signin",{});const failure=assert.rejects(pending,/cancelled/);
  await account.request("account.cancel-signin",{});await failure;assert.equal(channels[1].closed,true);
});

test("a popup notification cannot supply account authority and sign-in has a deadline",async()=>{
  let channel;const account=new Accounts({authTimeout:20,open:()=>({}),broadcast:name=>channel={name,close(){}},fetch:async()=>new Response("",{status:401})});
  const pending=account.request("account.signin",{});const denied=assert.rejects(pending,/not completed/);
  await channel.onmessage({data:{type:"rayde-auth-complete",channel:channel.name.slice("rayde-auth:".length),status:"success",user:{login:"forged"}}});await denied;
  await assert.rejects(account.request("account.signin",{}),/timed out/);
});


test("an unresponsive account request aborts and reports a retryable failure", async () => {
  let aborted=false;
  const account=new Accounts({timeout:10,fetch:(_,init)=>new Promise((_,reject)=>{
    init.signal.addEventListener("abort",()=>{aborted=true;reject(new DOMException("Aborted","AbortError"));},{once:true});
  })});
  await assert.rejects(account.request("account.status",{}),/workspace service did not respond/);
  assert.equal(aborted,true);
});


test("the public demo sends sign-in to the app without querying private account APIs", async () => {
  const navigations=[];
  const account=new Accounts({fetch:async()=>{throw new Error("public demo queried an account");},later:fn=>fn(),location:{href:"https://rayde.org/",assign:url=>navigations.push(url)}});
  assert.deepEqual(await account.request("account.status",{}),{user:null,installable:false});
  await account.request("account.signin",{});
  assert.deepEqual(navigations,["https://app.rayde.org/auth/github/start"]);
});

test("Cloud Sync renewal obtains current CSRF authority without handling a publish credential", async () => {
  const calls=[];
  const account=new Accounts({location:{href:"https://app.rayde.org/"},pause:async()=>{},fetch:async(url,init)=>{
    calls.push({url,init});return Response.json(url==="/api/session"?{user:{id:1},csrf:"renew-csrf"}:{id:"a".repeat(43),status:url.endsWith("/open")?"preparing":"ready"});
  }});
  await account.request("account.sync-reopen",{workspace:"a".repeat(43)});
  assert.deepEqual(calls.map(call=>call.url),["/api/session","/api/sync/workspaces/"+"a".repeat(43)+"/open","/api/workspaces/"+"a".repeat(43)]);
  assert.equal(calls[1].init.credentials,"same-origin");
  assert.equal(calls[1].init.headers["X-RayDE-CSRF"],"renew-csrf");
  assert.deepEqual(JSON.parse(calls[1].init.body),{});
  await assert.rejects(account.request("account.sync-reopen",{workspace:"../other"}),/Choose a synced workspace/);
  assert.equal(calls.length,3);
});

test("account changes reach header subscribers without leaking session authority",async()=>{
  const calls=[],changes=[],navigations=[];let loggedOut=false;
  const account=new Accounts({location:{href:"https://app.example/",origin:"https://app.example",assign:url=>navigations.push(url)},later:fn=>fn(),fetch:async(url,init)=>{
    calls.push({url,init});
    if(url==="/api/logout"){loggedOut=true;return Response.json({});}
    return Response.json({user:loggedOut?null:{login:"alice"},csrf:"fresh-csrf",installUrl:"https://github.com/apps/rayde/installations/new"});
  }});
  const stop=account.subscribe(status=>changes.push(status));
  await account.request("account.status",{});
  assert.deepEqual(changes,[{user:{login:"alice"}}]);
  account.csrf="stale-csrf";
  await account.request("account.signout",{});
  assert.deepEqual(calls.map(call=>call.url),["/api/session","/api/session","/api/logout"]);
  assert.equal(calls[2].init.headers["X-RayDE-CSRF"],"fresh-csrf");
  assert.deepEqual(changes.at(-1),{user:null});assert.equal(account.csrf,null);assert.equal(account.installUrl,null);
  assert.deepEqual(navigations,[]);
  stop();const length=changes.length;await account.request("account.status",{});assert.equal(changes.length,length);
});

test("a failed sign-out keeps the account and does not navigate away",async()=>{
  const navigations=[],changes=[];
  const account=new Accounts({location:{href:"https://app.example/",assign:url=>navigations.push(url)},later:fn=>fn(),fetch:async url=>url==="/api/session"?Response.json({user:{login:"alice"},csrf:"csrf"}):Response.json({message:"Sign out failed"},{status:503})});
  account.subscribe(status=>changes.push(status));
  await assert.rejects(account.request("account.signout",{}),/Sign out failed/);
  assert.deepEqual(changes,[{user:{login:"alice"}}]);assert.deepEqual(navigations,[]);assert.equal(account.csrf,"csrf");
});

test("a delayed account check cannot restore the header or CSRF after sign-out",async()=>{
  const changes=[];let release,checks=0;
  const account=new Accounts({fetch:async url=>{
    if(url==="/api/logout")return Response.json({});
    if(++checks===1)return new Promise(resolve=>release=()=>resolve(Response.json({user:{login:"stale"},csrf:"stale-csrf"})));
    return Response.json({user:{login:"alice"},csrf:"fresh-csrf"});
  }});
  account.subscribe(status=>changes.push(status));
  const pending=account.request("account.status",{});
  await account.request("account.signout",{});release();
  assert.deepEqual(await pending,{user:null,installable:false});
  assert.equal(account.csrf,null);assert.deepEqual(changes.at(-1),{user:null});
  assert.equal(changes.some(change=>change.user?.login==="stale"),false);
});

test("Manage access opens the GitHub App separately and preserves the editor",async()=>{
  const opened=[],navigations=[];
  const account=new Accounts({location:{href:"https://app.example/workspace",assign:url=>navigations.push(url)},open:(...args)=>opened.push(args),fetch:async()=>Response.json({user:{login:"alice"},csrf:"csrf",installUrl:"https://github.com/apps/rayde-staging/installations/new"})});
  await account.request("account.status",{});await account.request("account.manage-access",{});
  assert.deepEqual(opened,[["https://github.com/apps/rayde-staging/installations/new","_blank","noopener,noreferrer"]]);assert.deepEqual(navigations,[]);
  account.installUrl="https://evil.invalid/apps/rayde";
  await assert.rejects(account.request("account.manage-access",{}),/not configured/);assert.equal(opened.length,1);
});

test("resource requests stay on the current edge and stale account replies are rejected",async()=>{
  const calls=[];let release;
  const account=new Accounts({location:{href:"https://editor.example/"},fetch:(url,init)=>{calls.push({url,init});return new Promise(resolve=>release=()=>resolve(Response.json({available:true,memoryBytes:1234})));}});
  assert.deepEqual(await account.request("account.resources",{}),{available:false,status:"unprovisioned"});assert.equal(calls.length,0);
  const pending=account.request("account.resources",{workspace:"a".repeat(43)});
  assert.equal(calls[0].url,"/api/workspaces/"+"a".repeat(43)+"/resources");assert.equal(calls[0].init.credentials,"same-origin");assert.equal(calls[0].init.method,"GET");
  account.revision++;release();await assert.rejects(pending,/account changed/);
});
