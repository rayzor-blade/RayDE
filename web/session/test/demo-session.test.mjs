// Browser storage and session protocol tests; no browser process is launched.
import 'fake-indexeddb/auto';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as Y from 'yjs';
import {DemoSource} from '../src/demo-seed.js';
import {DemoStore} from '../src/demo-store.js';
import {DemoSession} from '../src/demo-session.js';
import {EditorDocuments} from '../src/editor.js';
import {DemoAdmission,afterEditorReady} from '../src/demo-admission.js';

const encode=bytes=>Buffer.from(bytes).toString('base64'),decode=text=>new Uint8Array(Buffer.from(text,'base64'));
async function source(){return DemoSource.read(new TextEncoder().encode(JSON.stringify({version:1,name:'Pocket Studio',root:'/work/pocket-studio',project:'pocket-studio/build.hxml',entries:[
 {path:'/work/pocket-studio',directory:true},{path:'/work/pocket-studio/build.hxml',directory:false,data:encode(Buffer.from('-main Main\n'))},
 {path:'/work/pocket-studio/src/a.txt',directory:false,data:encode(Buffer.from('base'))}
]})));}
async function fixture(t){
 const seed=await source(),origin='https://'+crypto.randomUUID()+'.example',store=new DemoStore(origin,seed.release),binding=await store.open();
 const client=new DemoSession({source:seed,store,binding,url:'wss://demo.example/api/demo/socket',reconnect:false});
 t.after(async()=>{for(const doc of client.docs.values())await doc.close();client.close();});
 return {client,seed,origin,store,binding};
}
function backend(seed,lease){
 const doc=new Y.Doc();Y.applyUpdate(doc,seed.graph('src/a.txt'));doc.getText('text').insert(0,'remote ');
 const calls=[],identity={version:1,authority:'native-private',workspace:'workspace-private',principal:'demo:'+lease};
 class Socket {
  static OPEN=1;
  constructor(){this.readyState=1;queueMicrotask(()=>this.onopen?.());}
  send(raw){const request=JSON.parse(raw);calls.push(request);queueMicrotask(()=>{
   let reply={};
   if(request.op==='hello')reply={root:'/workspace/project',exec:true,syntax:true,demoSeed:{version:1,release:seed.release},cacheIdentity:{...identity}};
   if(request.op==='doc.open')reply={update:encode(Y.encodeStateAsUpdate(doc,decode(request.vector))),vector:encode(Y.encodeStateVector(doc))};
   if(request.op==='doc.update')Y.applyUpdate(doc,decode(request.update));
   this.onmessage?.({data:JSON.stringify({id:request.id,ok:true,...reply})});
  });}
  close(){if(this.readyState===3)return;this.readyState=3;queueMicrotask(()=>this.onclose?.());}
 }
 return {Socket,doc,calls,identity};
}

test('draft bindings are atomic and cannot be rebound to another lease or native history',async()=>{
 const key='https://'+crypto.randomUUID()+'.example',one=new DemoStore(key,'a'.repeat(64)),two=new DemoStore(key,'a'.repeat(64));
 try{
  const [a,b]=await Promise.all([one.open(),two.open()]);assert.equal(a.draft,b.draft);
  await one.bind(a.draft,'x'.repeat(43),'native-one');
  await assert.rejects(two.bind(b.draft,'y'.repeat(43)),/binding changed/);
  await assert.rejects(two.bind(b.draft,'x'.repeat(43),'native-two'),/binding changed/);
  assert.equal((await two.open()).context,'native-one');
 }finally{one.close();two.close();}
});

test('local reads and edits survive admission and reload with the same projection and undo owner',async t=>{
 const f=await fixture(t),events=[],views=new EditorDocuments(f.client,event=>events.push(event));
 t.after(()=>views.close());
 assert.equal((await f.client.list('src'))[0].name,'a.txt');assert.equal(await f.client.read('src/a.txt'),'base');
 await views.request('view.open',{handle:'left-pane',path:'src/a.txt'});await views.request('view.ready',{handle:'left-pane'});
 const view=views.documents.get('left-pane'),graph=view.doc.ydoc,scope=f.client.workspace;
 await views.request('view.edit',{handle:'left-pane',epoch:0,serial:1,parts:[{from:4,removed:'',inserted:'!'}]});
 assert.equal(await f.client.read('src/a.txt'),'base!');await view.doc.checkpoint();
 const remote=backend(f.seed,'a'.repeat(43));globalThis.WebSocket=remote.Socket;t.after(()=>remote.doc.destroy());
 await f.client.admit({id:'a'.repeat(43),release:f.seed.release,expires:Date.now()+60000});
 while(events.length){const event=events.shift();if(event.ev==='view.remote')await views.request('view.ack',{handle:'left-pane',epoch:event.epoch,accept:true});}
 assert.equal(views.documents.get('left-pane'),view);assert.equal(view.doc.ydoc,graph);assert.equal(f.client.workspace,scope);
 assert.equal(view.text.toString(),'remote base!');assert.equal(remote.doc.getText('text').toString(),'remote base!');
 const undone=await views.request('view.undo',{handle:'left-pane',epoch:view.epoch,serial:2});assert.equal(undone.text,'remote base');
 const redone=await views.request('view.undo',{handle:'left-pane',epoch:view.epoch,serial:3,redo:true});assert.equal(redone.text,'remote base!');
 await view.doc.checkpoint();await views.request('view.close',{handle:'left-pane'});f.client.close();
 const store=new DemoStore(f.origin,f.seed.release),next=new DemoSession({source:f.seed,store,binding:await store.open(),url:f.client.options.url,reconnect:false});
 t.after(async()=>{for(const doc of next.docs.values())await doc.close();next.close();});
 const restored=await next.openDoc('src/a.txt');assert.equal(restored.text.toString(),'remote base!');
 const before=remote.calls.length;remote.identity.workspace='replaced-disk';
 await assert.rejects(next.admit({id:'a'.repeat(43),release:f.seed.release,expires:Date.now()+60000}),/workspace or account changed/);
 assert.deepEqual(remote.calls.slice(before).map(call=>call.op),['hello']);assert.equal(restored.text.toString(),'remote base!');
});

test('a reloaded draft cannot attach to a different visitor lease',async t=>{
 const f=await fixture(t),doc=await f.client.openDoc('src/a.txt');doc.text.insert(4,' private');await doc.checkpoint();
 await f.store.bind(f.binding.draft,'a'.repeat(43));
 await assert.rejects(f.client.admit({id:'b'.repeat(43),release:f.seed.release,expires:Date.now()+60000}),/workspace or account changed/);
 assert.equal(doc.text.toString(),'base private');assert.equal(f.client.ready,false);
});

test('admission and unavailable compute never hold a local editor operation',async t=>{
 const f=await fixture(t);let release;const waiting=new Promise(resolve=>release=resolve),states=[];
 const admission=new DemoAdmission(f.client,{locks:null,fetch:()=>waiting,changed:state=>states.push(state.status)});t.after(()=>admission.close());
 const start=admission.start(),doc=await f.client.openDoc('src/a.txt');doc.text.insert(4,' offline');await doc.checkpoint();
 assert.equal(doc.text.toString(),'base offline');assert.deepEqual(states,['connecting']);
 release(Response.json({message:'All sessions are busy'},{status:429}));await start;
 assert.equal(admission.state.status,'failed');assert.equal(doc.text.toString(),'base offline');assert.equal(f.client.invalidated,null);
});

test('admission only retries the bound failed lease and stops polling after preparation',async t=>{
 const f=await fixture(t),remote=backend(f.seed,'a'.repeat(43));globalThis.WebSocket=remote.Socket;t.after(()=>remote.doc.destroy());
 const lease={id:'a'.repeat(43),release:f.seed.release,expires:Date.now()+60000},calls=[];
 const admission=new DemoAdmission(f.client,{locks:null,pause:async()=>{},fetch:async path=>{
  calls.push(path);return Response.json({...lease,status:path.endsWith('/open')?'failed':path.endsWith('/retry')?'preparing':'ready'});
 }});t.after(()=>admission.close());await admission.start(true);
 assert.equal(admission.state.status,'ready');assert.deepEqual(calls,['/api/demo/open','/api/demo/retry','/api/demo/status']);
});

test('an unavailable gateway and an expired lease preserve editable local recovery',async t=>{
 const f=await fixture(t),doc=await f.client.openDoc('src/a.txt');
 const admission=new DemoAdmission(f.client,{locks:null,fetch:async()=>new Response('Unavailable',{status:503})});t.after(()=>admission.close());
 await admission.start();assert.equal(admission.state.status,'failed');assert.equal(admission.state.message,'The workspace could not connect.');
 admission.expire();assert.equal(admission.state.status,'expired');assert.equal(f.client.stopped,true);
 doc.text.insert(4,' retained');await doc.checkpoint();assert.equal(await f.client.read('src/a.txt'),'base retained');
});

test('compute admission waits for the editor readiness signal and subsequent paint opportunities',()=>{
 const status={hidden:false},frames=[];let changed,opened=0,disconnected=0;
 class Observer {constructor(fn){changed=fn;}observe(){}disconnect(){disconnected++;}}
 const stop=afterEditorReady(()=>opened++,{document:{getElementById:()=>status},MutationObserver:Observer,later:fn=>frames.push(fn)});
 assert.equal(opened,0);assert.equal(frames.length,0);status.hidden=true;changed();assert.equal(opened,0);
 frames.shift()();assert.equal(opened,0);frames.shift()();assert.equal(opened,1);stop();assert.ok(disconnected>0);
});
