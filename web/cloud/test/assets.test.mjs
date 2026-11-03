import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {fixture,signin} from './fixture.mjs';

const asset='https://assets.example.test';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

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
