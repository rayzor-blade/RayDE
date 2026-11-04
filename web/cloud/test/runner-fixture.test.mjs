import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {options} from './fixture.mjs';

test('real runner fixtures forward open, metrics and deletion to their matching control routes',async t=>{
 const calls=[];
 const server=createServer(async(req,res)=>{
  let body='';for await(const bytes of req)body+=bytes;
  calls.push({path:req.url,authorization:req.headers.authorization,body:JSON.parse(body)});
  res.writeHead(req.url==='/workspaces/delete'?409:200,{'Content-Type':'application/json'});
  res.end(JSON.stringify({operation:req.url}));
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>server.close(resolve)));
 const {config}=options({runnerUrl:`http://127.0.0.1:${server.address().port}`,runnerSecret:'fixture-private-credential'});
 const runner=config.serviceBindings.RUNNER;
 for(const operation of ['open','metrics','delete']){
  const path='/workspaces/'+operation;
  const response=await runner(new Request('https://runner.test'+path,{method:'POST',headers:{Authorization:'Bearer fixture-private-credential'},body:JSON.stringify({id:'isolated-fixture',owner:0})}));
  assert.equal(response.status,operation==='delete'?409:200);
  assert.equal((await response.json()).operation,path);
 }
 assert.deepEqual(calls.map(call=>call.path),['/workspaces/open','/workspaces/metrics','/workspaces/delete']);
 assert.ok(calls.every(call=>call.authorization==='Bearer fixture-private-credential'&&call.body.id==='isolated-fixture'));
 const refused=await runner(new Request('https://runner.test/workspaces/delete',{method:'POST',headers:{Authorization:'Bearer wrong'},body:'{}'}));
 assert.equal(refused.status,403);assert.equal(calls.length,3);
});
