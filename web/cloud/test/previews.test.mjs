import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,dirname,resolve} from 'node:path';
import {fixture,signin,origin,listening} from './fixture.mjs';

test('app artifacts stream from compute on an isolated origin and revoke with their session',async t=>{
 const root=await mkdtemp(join(tmpdir(),'rayde-preview-gateway-'));
 const tools=join(root,'tools'),output=join(root,'.rayde/previews/demo');await mkdir(output,{recursive:true});
 for(const name of ['haxe/rayde/preview/Files.hx','ash_channel.wasm','channel-agent.mjs','rayde_preview_files.mjs','preview-frames.mjs']){const path=join(tools,name);await mkdir(dirname(path),{recursive:true});await writeFile(path,'fixture');}
 await writeFile(join(output,'index.html'),'<html>App preview</html>');
 const bytes=Buffer.alloc(1400000,37);await writeFile(join(output,'app.wasm'),bytes);
 const port=await new Promise(resolve=>{const listener=createServer().listen(0,'127.0.0.1',()=>{const port=listener.address().port;listener.close(()=>resolve(port));});});
 const server=spawn(resolve('../../native/session/target/debug/rayde-session'),['--root',root,'--state-root',join(root,'state'),'--port',String(port),'--token','compute-secret','--origin',origin,'--exec','--preview-tools',tools],{stdio:'ignore'});
 t.after(async()=>{server.kill();await rm(root,{recursive:true,force:true});});await listening(port,server);
 const {mf,fetch}=await fixture({endpoint:`ws://127.0.0.1:${port}/session`});t.after(()=>mf.dispose());
 const user=await signin(fetch);
 const workspace=await(await fetch('/api/workspaces/open',{method:'POST',headers:user.headers,body:'{"repository":111}'})).json();
 const path='/api/workspaces/'+workspace.id;
 for(let i=0;i<100;i++){if((await(await fetch(path,{headers:user.headers})).json()).status==='ready')break;await new Promise(r=>setTimeout(r,10));}
 const response=await fetch(path+'/socket',{headers:{...user.headers,Upgrade:'websocket'}});assert.equal(response.status,101);
 const socket=response.webSocket;socket.accept();let next=0;const waiting=new Map();
 socket.addEventListener('message',event=>{const reply=JSON.parse(event.data);waiting.get(reply.id)?.(reply);waiting.delete(reply.id);});
 function rpc(op,params={}){return new Promise((resolve,reject)=>{const id=++next,timer=setTimeout(()=>reject(Error('Preview RPC timeout: '+op)),5000);waiting.set(id,reply=>{clearTimeout(timer);resolve(reply);});socket.send(JSON.stringify({id,op,...params}));});}
 assert.equal((await rpc('hello')).appPreviews,true);
 const opened=await rpc('preview.open',{path:'.rayde/previews/demo'});assert.equal(opened.ok,true,JSON.stringify(opened));
 const url=new URL(opened.url);assert.equal(url.origin,'http://localhost:8787');assert.ok(!opened.url.includes('compute-secret'));
 const page=await mf.dispatchFetch(opened.url);assert.equal(page.status,200);assert.equal(await page.text(),'<html>App preview</html>\n<script type="module" data-rayde-preview-metadata src="./rayde-preview-metadata.mjs"></script>\n');
 assert.equal(page.headers.get('cross-origin-embedder-policy'),'require-corp');assert.equal(page.headers.get('cross-origin-resource-policy'),'cross-origin');
 const wasm=await mf.dispatchFetch(new URL('app.wasm',opened.url));assert.equal(wasm.headers.get('content-type'),'application/wasm');assert.deepEqual(Buffer.from(await wasm.arrayBuffer()),bytes);
 for(const path of ['/api/session','/auth/github/start','/'])assert.equal((await mf.dispatchFetch(url.origin+path)).status,404);
 assert.equal((await fetch(url.pathname)).status,404);
 assert.equal((await mf.dispatchFetch(opened.url.replace(opened.preview,'0'.repeat(64)))).status,404);
 assert.equal((await rpc('preview.close',{preview:opened.preview})).ok,true);
 assert.equal((await mf.dispatchFetch(opened.url)).status,404);
 const again=await rpc('preview.open',{path:'.rayde/previews/demo'});socket.close();
 for(let i=0;i<100;i++){const reply=await mf.dispatchFetch(again.url);if(reply.status===404)return;await new Promise(r=>setTimeout(r,10));}
 assert.fail('Disconnected session retained its preview capability');
});
