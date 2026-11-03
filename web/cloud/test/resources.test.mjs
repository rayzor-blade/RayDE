import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture,signin,json} from './fixture.mjs';

test('workspace usage is private, bounded, cached and independent of repository checkout credentials',async()=>{
  const calls=[];
  const {mf,fetch}=await fixture({metrics:body=>{calls.push(body);return json({available:true,cpuPercent:12.5,cpuLimit:1,memoryBytes:1000,memoryLimitBytes:3221225472,storageBytes:300,storageLimitBytes:1024,uptimeSeconds:50,durationLimitSeconds:3600,sandbox:'private-guest',token:'must-not-leak',net_rx_bytes:12});}});
  try {
    const alice=await signin(fetch);
    let workspace=await(await fetch('/api/workspaces/open',{method:'POST',headers:alice.headers,body:'{"repository":111}'})).json();
    const end=Date.now()+5000;
    while(workspace.status==='preparing'&&Date.now()<end){await new Promise(r=>setTimeout(r,10));workspace=await(await fetch('/api/workspaces/'+workspace.id,{headers:alice.headers})).json();}
    assert.equal(workspace.status,'ready');const path='/api/workspaces/'+workspace.id+'/resources';
    assert.equal((await fetch(path)).status,401);
    const bob=await signin(fetch,'bob');assert.equal((await fetch(path,{headers:bob.headers})).status,403);assert.equal(calls.length,0);
    const response=await fetch(path,{headers:alice.headers});assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');
    const sample=await response.json();assert.equal(sample.cpuPercent,12.5);assert.equal(sample.memoryLimitBytes,3221225472);assert.equal(sample.uptimeSeconds,50);assert.ok(sample.sampledAt>0);
    assert.doesNotMatch(JSON.stringify(sample),/private-guest|must-not-leak|access-alice|net_rx/);
    await fetch(path,{headers:alice.headers});assert.equal(calls.length,1);assert.equal(calls[0].owner,1);assert.equal(calls[0].id,workspace.id);assert.deepEqual(Object.keys(calls[0]).sort(),['id','owner']);
  }finally{await mf.dispose();}
});

test('failed samples do not become invented zero usage',async()=>{
  const {mf,fetch}=await fixture({metrics:()=>json({},503)});
  try {
    const user=await signin(fetch);let workspace=await(await fetch('/api/workspaces/open',{method:'POST',headers:user.headers,body:'{"repository":111}'})).json();
    for(let n=0;workspace.status==='preparing'&&n<100;n++){await new Promise(r=>setTimeout(r,10));workspace=await(await fetch('/api/workspaces/'+workspace.id,{headers:user.headers})).json();}
    const result=await fetch('/api/workspaces/'+workspace.id+'/resources',{headers:user.headers});assert.equal(result.status,503);assert.match((await result.json()).message,/unavailable/);
  }finally{await mf.dispose();}
});
