import {test} from "node:test";
import assert from "node:assert/strict";
import {fixture,signin,json,repo} from "./fixture.mjs";

const base="1".repeat(40),baseTree="2".repeat(40),tree="3".repeat(40),commit="4".repeat(40);
const key="a".repeat(64);
const starter=()=>({name:"my-project",description:"Starter fixture",private:true,entry:"build.hxml",files:[
  {path:"README.md",text:"# My project\n"},{path:"build.hxml",text:"-cp src\n-main Main\n"},
  {path:"src/Main.hx",text:'class Main { static function main() trace("Hello"); }'},
]});
function github({failTree=false,conflict=false,permission=false,unknownCreate=false,denied}={}) {
  const calls=[];let head=base,failed=false;
  return {calls,handle:async request=>{
    const path=new URL(request.url).pathname;
    if(!path.startsWith("/repos/alice/my-project/")&&path!=="/user/repos")return;
    const body=request.method==="GET"?null:await request.json();calls.push({path,method:request.method,body});
    if(denied?.path===path){const response=json({message:denied.message,ignored:"do-not-expose"},denied.status);for(const [key,value] of Object.entries(denied.headers??{}))response.headers.set(key,value);return response;}
    if(path==="/user/repos")return unknownCreate?json({},503):permission?json({},403):json({...repo,name:"my-project",full_name:"alice/my-project",owner:{id:1}},201);
    if(path.endsWith("/contents/README.md"))return json({commit:{sha:base,tree:{sha:baseTree},parents:[]}},201);
    if(path.endsWith("/git/ref/heads/main"))return json({object:{sha:conflict?"f".repeat(40):head}});
    if(path.endsWith("/git/trees")){
      if(failTree&&!failed){failed=true;return json({},503);}return json({sha:tree},201);
    }
    if(path.endsWith("/git/commits"))return json({sha:commit},201);
    if(path.endsWith("/git/refs/heads/main")){assert.equal(body.force,false);head=body.sha;return json({object:{sha:head}});}
    throw Error("Unexpected GitHub project operation: "+request.method+" "+path);
  }};
}

test("a template initializes one private repository and retries without duplicate writes",async t=>{
  const mock=github(),{mf,fetch}=await fixture({github:mock.handle});t.after(()=>mf.dispose());
  const user=await signin(fetch);
  const create=(data=starter(),headers=user.headers)=>fetch("/api/projects/create/"+key,{method:"POST",headers,body:JSON.stringify(data)});
  assert.equal((await create(starter(),{Cookie:user.cookie})).status,403);
  assert.equal((await fetch("/api/projects/create/"+key,{headers:user.headers})).status,405);
  const result=await (await create()).json();
  assert.equal(result.status,"ready");assert.equal(result.repository.fullName,"alice/my-project");assert.equal(result.entry,"build.hxml");
  const write=mock.calls.find(call=>call.path==="/user/repos");assert.equal(write.body.private,true);assert.equal(write.body.auto_init,false);
  const content=mock.calls.find(call=>call.path.includes("/contents/"));assert.equal(Buffer.from(content.body.content,"base64").toString(),starter().files[0].text);
  const batch=mock.calls.find(call=>call.path.endsWith("/git/trees"));assert.equal(batch.body.base_tree,baseTree);
  assert.deepEqual(batch.body.tree.map(file=>({path:file.path,text:file.content})),starter().files.sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0));
  assert.ok(batch.body.tree.every(file=>file.mode==="100644"&&file.type==="blob"));
  const length=mock.calls.length;assert.deepEqual(await(await create()).json(),result);assert.equal(mock.calls.length,length);
  assert.equal((await create({...starter(),description:"different"})).status,409);
  assert.ok(!JSON.stringify(result).includes("access-alice"));
});

test("a partial starter resumes from durable progress without recreating its repository",async t=>{
  const mock=github({failTree:true}),{mf,fetch}=await fixture({github:mock.handle});t.after(()=>mf.dispose());const user=await signin(fetch);
  const create=()=>fetch("/api/projects/create/"+key,{method:"POST",headers:user.headers,body:JSON.stringify(starter())}).then(r=>r.json());
  const failed=await create();assert.equal(failed.status,"incomplete");assert.equal(failed.repository.fullName,"alice/my-project");
  assert.equal((await create()).status,"ready");
  assert.equal(mock.calls.filter(c=>c.path==="/user/repos").length,1);assert.equal(mock.calls.filter(c=>c.path.includes("/contents/")).length,1);
});

test("concurrent repository changes and uncertain creation results are never overwritten",async t=>{
  for(const settings of [{conflict:true},{unknownCreate:true}]){
    const mock=github(settings),{mf,fetch}=await fixture({github:mock.handle});t.after(()=>mf.dispose());const user=await signin(fetch);
    const create=()=>fetch("/api/projects/create/"+key,{method:"POST",headers:user.headers,body:JSON.stringify(starter())});
    const response=await create();const result=await response.json();
    if(settings.conflict){assert.equal(result.status,"incomplete");assert.match(result.message,/changed/);}
    else {assert.equal(response.status,502);assert.equal((await create()).status,409);}
    assert.equal(mock.calls.filter(c=>c.path==="/user/repos").length,1);assert.ok(!mock.calls.some(c=>c.path.includes("/git/trees")||c.method==="PATCH"));
  }
});

test("project input and GitHub App permissions are checked before starter publication",async t=>{
  const mock=github({permission:true}),{mf,fetch}=await fixture({github:mock.handle});t.after(()=>mf.dispose());const user=await signin(fetch);
  const create=data=>fetch("/api/projects/create/"+key,{method:"POST",headers:user.headers,body:JSON.stringify(data)});
  for(const files of [[{path:"../outside",text:"unsafe"}],[{path:".git/config",text:"unsafe"}],[{path:"a",text:"one"},{path:"a/file",text:"two"}],[{path:"A",text:"one"},{path:"a",text:"two"}]]){
    assert.equal((await create({...starter(),entry:"",files})).status,400);
  }
  assert.equal((await create({...starter(),files:[{path:"README.md",text:"a".repeat(1024*1024+1)}]})).status,413);
  assert.equal(mock.calls.length,0);
  const denied=await create(starter());assert.equal(denied.status,403);assert.match((await denied.json()).message,/Repository creation failed \(403\)/);
});

test("GitHub failures identify the rejected starter operation and preserve its reference",async t=>{
  const mock=github({denied:{path:"/repos/alice/my-project/contents/README.md",status:404,message:"Not Found",headers:{"X-GitHub-Request-Id":"fixture-reference","X-Accepted-GitHub-Permissions":"contents=write"}}});
  const {mf,fetch}=await fixture({github:mock.handle});t.after(()=>mf.dispose());const user=await signin(fetch);
  const response=await fetch("/api/projects/create/"+key,{method:"POST",headers:user.headers,body:JSON.stringify(starter())});
  const result=await response.json();
  assert.equal(result.status,"incomplete");assert.equal(result.repository.fullName,"alice/my-project");
  assert.match(result.message,/Starter file creation failed \(404\): Not Found/);assert.match(result.message,/included in the App installation/);
  assert.match(result.message,/Reference: fixture-reference/);assert.doesNotMatch(result.message,/Repository creation write|access-alice|do-not-expose/);
});

test("rate limiting is distinguished from permission denial and can retry creation",async t=>{
  const denied={path:"/user/repos",status:403,message:"API rate limit exceeded",headers:{"X-RateLimit-Remaining":"0"}};
  const mock=github({denied}),{mf,fetch}=await fixture({github:mock.handle});t.after(()=>mf.dispose());const user=await signin(fetch);
  const create=()=>fetch("/api/projects/create/"+key,{method:"POST",headers:user.headers,body:JSON.stringify(starter())});
  const response=await create();assert.equal(response.status,429);assert.match((await response.json()).message,/rate limiting/);
  denied.path="disabled";assert.equal((await(await create()).json()).status,"ready");
});
