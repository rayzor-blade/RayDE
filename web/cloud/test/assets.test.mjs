import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {fixture,signin} from './fixture.mjs';

const asset='https://assets.example.test';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

test('public demo artifacts use the isolated preview origin without account access',async t=>{
 const {mf}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS'),release='a'.repeat(64);
 await bucket.put(`demo/${release}/index.html`,'<html>public app</html>');
 for(const path of [`/demo/${release}/index.html`,`/dist/demo/${release}/index.html`]){
  const response=await mf.dispatchFetch('http://localhost:8787'+path);
  assert.equal(response.status,200);assert.equal(await response.text(),'<html>public app</html>');
  assert.match(response.headers.get('Cache-Control'),/immutable/);
  assert.equal(response.headers.get('Cross-Origin-Embedder-Policy'),'require-corp');
 }
 for(const path of ['/demo/not-a-release/index.html','/api/session','/auth/github/start'])
  assert.equal((await mf.dispatchFetch('http://localhost:8787'+path)).status,404,path);
});

test('concurrent thread agents receive the complete compilable WASM host on either asset route',async t=>{
 const {mf,fetch}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const bytes=await readFile(new URL('../../../site/dist/ash_browser_bg.wasm',import.meta.url));
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS');await bucket.put('ash_browser_bg.wasm',bytes);
 await Promise.all(Array.from({length:8},async(_,index)=>{
  const response=index%2?await fetch('/ash_browser_bg.wasm'):await mf.dispatchFetch(asset+'/ash_browser_bg.wasm');
  assert.equal(response.status,200);assert.equal(response.headers.get('Content-Type'),'application/wasm');
  const received=await response.arrayBuffer();assert.equal(received.byteLength,bytes.length);assert.equal(sha(new Uint8Array(received)),sha(bytes));
  await WebAssembly.compile(received);
 }));
});

test('R2 editor assets stream files above the static asset limit on both configured hosts',async t=>{
 const {mf,fetch}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS');
 const bytes=new Uint8Array(26*1024*1024+4);bytes.set([0,97,115,109]);bytes[bytes.length-1]=42;
 await bucket.put('rayde.wasm',bytes,{httpMetadata:{contentType:'application/octet-stream'}});
 const head=await mf.dispatchFetch(asset+'/rayde.wasm',{method:'HEAD'});
 assert.equal(head.status,200);assert.equal(head.headers.get('Content-Type'),'application/wasm');assert.equal(head.headers.get('Content-Length'),String(bytes.length));assert.equal((await head.arrayBuffer()).byteLength,0);
 const response=await fetch('/rayde.wasm');assert.equal(response.status,200);
 assert.equal(response.headers.get('Cross-Origin-Opener-Policy'),'same-origin');assert.equal(response.headers.get('Cross-Origin-Embedder-Policy'),'require-corp');
 const hash=createHash('sha256');let size=0;for await(const chunk of response.body){hash.update(chunk);size+=chunk.length;}
 assert.equal(size,bytes.length);assert.equal(hash.digest('hex'),sha(bytes));
 const unchanged=await mf.dispatchFetch(asset+'/rayde.wasm',{headers:{'If-None-Match':head.headers.get('ETag')}});
 assert.equal(unchanged.status,304);assert.equal((await unchanged.arrayBuffer()).byteLength,0);
 await bucket.put('rayde.wasm',new Uint8Array([0,97,115,109]));
 const changed=await mf.dispatchFetch(asset+'/rayde.wasm',{headers:{'If-None-Match':head.headers.get('ETag')}});assert.equal(changed.status,200);assert.notEqual(changed.headers.get('ETag'),head.headers.get('ETag'));await changed.arrayBuffer();
});

test('the assets host cannot expose account routes, workspace payloads or hidden files',async t=>{
 const {mf}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const editor=await mf.getR2Bucket('EDITOR_ASSETS'),files=await mf.getR2Bucket('WORKSPACE_FILES');
 await editor.put('worker.js','export const ready=true;');await editor.put('.dev.vars','private');await files.put('private.txt','workspace data');
 const script=await mf.dispatchFetch(asset+'/worker.js');assert.equal(script.headers.get('Content-Type'),'text/javascript; charset=utf-8');assert.equal(await script.text(),'export const ready=true;');
 for(const path of ['/api/session','/auth/github/start','/private.txt','/.dev.vars','/missing.wasm'])assert.equal((await mf.dispatchFetch(asset+path)).status,404,path);
 assert.equal((await mf.dispatchFetch(asset+'/worker.js',{method:'POST',body:'replace'})).status,405);
 assert.equal(await(await editor.get('worker.js')).text(),'export const ready=true;');
});

test('workspace pages use the R2 editor index after owner authorization and never cache its short URL',async t=>{
 const {mf,fetch}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS');await bucket.put('index.html','<html>editor</html>');
 assert.equal(await(await fetch('/')).text(),'<html>editor</html>');
 const alice=await signin(fetch),bob=await signin(fetch,'bob');
 const workspace=await(await fetch('/api/workspaces/open',{method:'POST',headers:alice.headers,body:JSON.stringify({repository:111})})).json();
 const page=await fetch('/'+workspace.id,{headers:{Cookie:alice.cookie}});assert.equal(page.status,200);assert.equal(await page.text(),'<html>editor</html>');assert.equal(page.headers.get('Cache-Control'),'no-store');
 assert.equal((await fetch('/'+workspace.id,{headers:{Cookie:bob.cookie}})).status,403);
});

test('an assets hostname without its bucket fails closed instead of fetching itself',async t=>{
 const {mf}=await fixture({asset});t.after(()=>mf.dispose());assert.equal((await mf.dispatchFetch(asset+'/rayde.wasm')).status,503);
});

test('local development can retain its asset origin when the staging R2 binding is present',async t=>{
 const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end('<html>local editor</html>');});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>server.close(resolve)));
 const {mf,fetch}=await fixture({asset:`http://127.0.0.1:${server.address().port}`,editorAssets:true,assetSource:'origin'});t.after(()=>mf.dispose());
 assert.equal(await(await fetch('/')).text(),'<html>local editor</html>');
});

async function release(bucket,label){
 const files={'index.html':'<html><head></head><a href="#features">Features</a><script type="module" src="./landing.mjs"></script>landing '+label+'</html>',
  'dist/index.html':'<html><meta charset="utf-8"><script type="module" src="./ashui-host.mjs"></script>editor '+label+'</html>',
  'dist/thread.js':'export const release="'+label+'";', 'dist/rayde.wasm':new Uint8Array([0,97,115,109,1,0,0,0]),
  ['dist/demo/'+ 'a'.repeat(64)+'/index.html']:'<html>isolated app '+label+'</html>'};
 const entries=Object.entries(files).sort(([a],[b])=>a.localeCompare(b));
 const manifest=JSON.stringify({version:1,files:Object.fromEntries(entries.map(([name,data])=>[name,{bytes:Buffer.byteLength(data),sha256:sha(data)}]))})+'\n';
 const id=sha(manifest);
 for(const [name,data]of entries)await bucket.put(`releases/${id}/${name}`,data);
 await bucket.put(`releases/${id}/manifest.json`,manifest);
 return {id,files,promote:()=>bucket.put('editor-release.json',JSON.stringify({version:1,release:id}))};
}

test('promoted editor pages pin all modules to one immutable release across promotion and rollback',async t=>{
 const {mf,fetch}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS'),first=await release(bucket,'first'),second=await release(bucket,'second');
 await first.promote();
 const page=await fetch('/');assert.equal(page.status,200);const html=await page.text();
 assert.match(html,new RegExp(`src="/releases/${first.id}/dist/ashui-host.mjs"`));
 assert.doesNotMatch(html,/<base/);
 assert.match(html,/editor first/);assert.equal(page.headers.get('Cache-Control'),'no-store');
 assert.match(html,/name="rayde-preview-origin" content="http:\/\/localhost:8787"/);
 const head=await fetch('/',{method:'HEAD'});assert.equal(head.headers.get('Content-Length'),String(Buffer.byteLength(html)));assert.equal((await head.text()).length,0);
 await second.promote();
 const next=await fetch('/');assert.equal(next.headers.get('X-RayDE-Release'),second.id);assert.match(await next.text(),/editor second/);
 const old=await fetch(`/releases/${first.id}/dist/thread.js`);assert.match(old.headers.get('Cache-Control'),/immutable/);assert.equal(await old.text(),first.files['dist/thread.js']);
 const redirect=await fetch('/thread.js',{redirect:'manual'});assert.equal(redirect.status,307);assert.equal(new URL(redirect.headers.get('Location')).pathname,`/releases/${second.id}/dist/thread.js`);
 const wasm=await mf.dispatchFetch(`${asset}/releases/${first.id}/dist/rayde.wasm`);assert.equal(wasm.headers.get('Content-Type'),'application/wasm');await WebAssembly.compile(await wasm.arrayBuffer());
 await first.promote();assert.match(await(await fetch('/')).text(),/editor first/);
 const alice=await signin(fetch),bob=await signin(fetch,'bob');
 const workspace=await(await fetch('/api/workspaces/open',{method:'POST',headers:alice.headers,body:JSON.stringify({repository:111})})).json();
 const owned=await fetch('/'+workspace.id,{headers:{Cookie:alice.cookie}});assert.match(await owned.text(),new RegExp(first.id));assert.equal(owned.headers.get('Cache-Control'),'no-store');
 assert.equal((await fetch('/'+workspace.id,{headers:{Cookie:bob.cookie}})).status,403);
});

test('landing releases retain isolation and cannot expose account or workspace routes',async t=>{
 const landing='https://landing.example.test';
 const {mf}=await fixture({asset,landingOrigin:landing,editorAssets:true});t.after(()=>mf.dispose());
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS'),current=await release(bucket,'site');await current.promote();
 const page=await mf.dispatchFetch(landing+'/');assert.equal(page.status,200);const html=await page.text();
 assert.match(html,new RegExp(`src="/releases/${current.id}/landing.mjs"`));assert.match(html,/href="#features"/);assert.doesNotMatch(html,/<base/);
 for(const name of ['Cross-Origin-Opener-Policy','Cross-Origin-Embedder-Policy'])assert.ok(page.headers.get(name));
 const script=await mf.dispatchFetch(landing+'/landing.mjs',{redirect:'manual'});assert.equal(script.status,307);assert.equal(new URL(script.headers.get('Location')).pathname,`/releases/${current.id}/landing.mjs`);
 for(const path of ['/api/session','/auth/github/start','/.dev.vars'])assert.equal((await mf.dispatchFetch(landing+path)).status,404,path);
 const preview=await mf.dispatchFetch(`http://localhost:8787/releases/${current.id}/dist/demo/${'a'.repeat(64)}/index.html`);assert.equal(preview.status,200);assert.match(await preview.text(),/isolated app/);
 assert.equal((await mf.dispatchFetch(`http://localhost:8787/releases/${current.id}/dist/rayde.wasm`)).status,404,'preview host never serves the editor');
});

test('invalid or incomplete promotion fails closed instead of reverting to mutable assets',async t=>{
 const {mf,fetch}=await fixture({asset,editorAssets:true});t.after(()=>mf.dispose());
 const bucket=await mf.getR2Bucket('EDITOR_ASSETS');await bucket.put('index.html','<html>legacy fallback</html>');
 await bucket.put('editor-release.json',JSON.stringify({version:1,release:'../../private'}));assert.equal((await fetch('/')).status,503);
 const current=await release(bucket,'valid');await current.promote();
 await bucket.put(`releases/${current.id}/manifest.json`,'changed');assert.equal((await fetch('/')).status,503);
 assert.equal((await fetch('/releases/not-a-release/dist/thread.js')).status,404);
});
