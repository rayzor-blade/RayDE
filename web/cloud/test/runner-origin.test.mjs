import {test} from "node:test";
import assert from "node:assert/strict";
import {fixture,signin} from "./fixture.mjs";

test("an explicit runner origin accepts its secure session endpoint and rejects a credential destination change",async()=>{
  for(const [endpoint,expected] of [["wss://runner.example.test/workspaces/fixture/session","ready"],["wss://elsewhere.example.test/session","failed"]]){
    const {mf,fetch}=await fixture({endpoint,runnerSessionOrigin:"https://runner.example.test"});
    try{
      const user=await signin(fetch);
      const response=await fetch("/api/workspaces/open",{method:"POST",headers:user.headers,body:'{"repository":111}'});
      assert.equal(response.status,200);let workspace=await response.json();
      const end=Date.now()+5000;
      while(workspace.status==="preparing"&&Date.now()<end){await new Promise(resolve=>setTimeout(resolve,10));workspace=await(await fetch("/api/workspaces/"+workspace.id,{headers:user.headers})).json();}
      assert.equal(workspace.status,expected);
      if(expected==="failed")assert.match(workspace.message,/does not match the configured runner/);
      assert.doesNotMatch(JSON.stringify(workspace),/test-runner-secret|compute-secret/);
    }finally{await mf.dispose();}
  }
});
