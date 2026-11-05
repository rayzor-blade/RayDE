import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm,symlink} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {stageEditorRelease} from '../dev/editor-assets.mjs';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

async function release(t){
 const temporary=await mkdtemp(join(tmpdir(),'rayde-editor-assets-'));t.after(()=>rm(temporary,{recursive:true,force:true}));
 const files={'index.html':'<html>site</html>','dist/index.html':'<html>editor</html>','dist/demo/app.wasm':'public wasm'};
 const manifest=JSON.stringify({version:1,files:Object.fromEntries(Object.entries(files).map(([name,bytes])=>[name,{bytes:Buffer.byteLength(bytes),sha256:sha(bytes)}]))});
 const id=sha(manifest),root=join(temporary,id);await mkdir(join(root,'dist/demo'),{recursive:true});
 for(const [name,bytes]of Object.entries(files))await writeFile(join(root,name),bytes);
 await writeFile(join(root,'manifest.json'),manifest);return {id,root,files};
}
test('local R2 promotion retains cached previews and waits for complete verified assets',async t=>{
 const f=await release(t),puts=[];
 const bucket={put:async(key,data)=>puts.push([key,Buffer.from(data).toString()])};
 assert.equal(await stageEditorRelease(bucket,f.root),f.id);
 assert.ok(puts.some(([key,data])=>key===`releases/${f.id}/dist/demo/app.wasm`&&data==='public wasm'));
 assert.deepEqual(JSON.parse(puts.at(-1)[1]),{version:1,release:f.id});assert.equal(puts.at(-1)[0],'editor-release.json');
 puts.length=0;await writeFile(join(f.root,'dist/demo/app.wasm'),'changed');
 await assert.rejects(stageEditorRelease(bucket,f.root),/asset changed/);assert.ok(!puts.some(([key])=>key==='editor-release.json'));
});
test('local R2 staging refuses links and never promotes partial uploads',async t=>{
 const f=await release(t),puts=[],bucket={put:async key=>puts.push(key)};
 await rm(join(f.root,'dist/demo/app.wasm'));await symlink('../index.html',join(f.root,'dist/demo/app.wasm'));
 await assert.rejects(stageEditorRelease(bucket,f.root),/non-regular asset/);assert.ok(!puts.includes('editor-release.json'));
 await rm(join(f.root,'dist/demo/app.wasm'));await writeFile(join(f.root,'dist/demo/app.wasm'),f.files['dist/demo/app.wasm']);
 await assert.rejects(stageEditorRelease({put:async()=>{throw Error('R2 unavailable');}},f.root),/R2 unavailable/);
});
