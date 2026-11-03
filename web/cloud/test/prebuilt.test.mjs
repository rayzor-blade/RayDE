import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,cp,readFile,writeFile,rm,utimes} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {record,verify,checkConfig} from '../prebuilt.mjs';

const source=fileURLToPath(new URL('../',import.meta.url));
async function project(t){
 const directory=await mkdtemp(join(tmpdir(),'rayde-prebuilt-')),root=join(directory,'web/cloud');t.after(()=>rm(directory,{recursive:true,force:true}));
 await mkdir(root,{recursive:true});
 for(const path of ['Cargo.toml','Cargo.lock','package.json','package-lock.json','build.sh','prebuilt.mjs','src','../../native/session/Cargo.toml','../../native/session/src','../../native/sync/Cargo.toml','../../native/sync/src']){
  const target=resolve(root,path);await mkdir(resolve(target,'..'),{recursive:true});await cp(resolve(source,path),target,{recursive:true});
 }
 await mkdir(join(root,'build'));await writeFile(join(root,'build/index.js'),'export default {};');await writeFile(join(root,'build/index_bg.wasm'),new Uint8Array([0,97,115,109]));
 await writeFile(join(root,'wrangler.jsonc'),'{"name":"test","main":"build/index.js","compatibility_date":"2026-07-30"}');return root;
}

test('prebuilt deployment requires a completed build and rejects changed source or compiled bytes',async t=>{
 const root=await project(t);assert.throws(()=>verify(root),/No verified Worker build/);
 record(root);assert.equal(verify(root).version,1);
 await utimes(join(root,'src/lib.rs'),new Date(0),new Date(0));assert.equal(verify(root).version,1,'checkout timestamps do not invalidate unchanged content');
 await writeFile(join(root,'build/index_bg.wasm'),new Uint8Array([0,97,115,109,1]));assert.throws(()=>verify(root),/artifacts changed/);
 record(root);const code=await readFile(join(root,'src/lib.rs'),'utf8');await writeFile(join(root,'src/lib.rs'),code+'\n');assert.throws(()=>verify(root),/source or build inputs changed/);
});

test('prebuilt deployment prevents an automatic Rust build from being restored through config or CLI overrides',async t=>{
 const root=await project(t);await checkConfig(root);
 await writeFile(join(root,'wrangler.jsonc'),'{"name":"test","main":"build/index.js","build":{"command":"cargo build"}}');
 await assert.rejects(checkConfig(root),/Remove build.command/);await assert.rejects(checkConfig(root,['--config=other.jsonc']),/without an environment override/);
});
