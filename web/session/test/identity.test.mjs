import test from 'node:test';
import assert from 'node:assert/strict';
import * as Y from 'yjs';
import {cacheNamespace,SessionClient} from '../src/client.js';
import {EditorDocuments} from '../src/editor.js';
const identity=(workspace='one',principal='workspace')=>({version:1,authority:'host',workspace,principal});

test('recovery namespace uses verified identities without credentials or display names',()=>{
 const base=cacheNamespace('ws://server/session?token=private#secret',identity());
 assert.equal(base,cacheNamespace('ws://server/session?token=different',identity()));
 assert(!base.includes('private')&&!base.includes('secret'));
 for(const value of [{...identity(),authority:'other'},identity('two'),identity('one','account:1'),identity('one','account:2')])
  assert.notEqual(base,cacheNamespace('ws://server/session',value));
 assert.notEqual(cacheNamespace('ws://server/session',identity('a:b','c')),cacheNamespace('ws://server/session',identity('a','b:c')));
 for(const value of [null,{}, {...identity(),version:2},{...identity(),workspace:''},{...identity(),principal:'x'.repeat(513)}])
  assert.equal(cacheNamespace('ws://server/session',value),null);
});

class Socket {
 static OPEN=1; static context=identity();
 constructor(){this.readyState=1;queueMicrotask(()=>this.onopen?.());}
 send(text){const request=JSON.parse(text);queueMicrotask(()=>this.onmessage?.({data:JSON.stringify({id:request.id,ok:true,name:'same-name',root:'/workspace',cacheIdentity:Socket.context})}));}
 close(){if(this.readyState===3)return;this.readyState=3;queueMicrotask(()=>this.onclose?.());}
}

test('a replacement workspace fences old documents before synchronization',async()=>{
 globalThis.WebSocket=Socket;Socket.context=identity('one');
 const client=new SessionClient({url:'ws://server/session',reconnect:false}),events=[];
 client.on('context-changed',event=>events.push(event));await client.connect();
 let synced=0;client.docs.set('a',{sync(){synced++;}});
 const old=client.workspace;client.ready=false;Socket.context=identity('two');
 await assert.rejects(client.connect(),/workspace or account changed/);
 assert.equal(synced,0);assert.equal(client.workspace,old);assert.equal(client.ready,false);assert.equal(client.stopped,true);assert.equal(events.length,1);
 await assert.rejects(client.request('doc.update',{}),/workspace or account changed/);
 client.docs.clear();client.close();
});

test('a restart of the same verified workspace resumes existing documents',async()=>{
 globalThis.WebSocket=Socket;Socket.context=identity('same');
 const client=new SessionClient({url:'ws://server/session',reconnect:false});await client.connect();
 const old=client.workspace;let synced=0;client.docs.set('a',{sync:async()=>{synced++;}});
 client.ready=false;await client.connect();assert.equal(client.workspace,old);assert.equal(synced,1);assert.equal(client.invalidated,null);
 client.docs.clear();client.close();
});

test('a legacy server cannot load durable caches or resume an unknown context',async()=>{
 globalThis.WebSocket=Socket;Socket.context=null;
 const client=new SessionClient({url:'ws://server/session',reconnect:false});await client.connect();assert.equal(client.cacheable,false);
 client.docs.set('a',{sync:async()=>{throw Error('must not sync');}});client.ready=false;
 await assert.rejects(client.connect(),/workspace or account changed/);client.docs.clear();client.close();
});

test('a connection lost during credential verification never becomes ready',async()=>{
 class DroppedLogin extends Socket {send(text){if(JSON.parse(text).op==='auth.login')this.close();else super.send(text);}}
 globalThis.WebSocket=DroppedLogin;Socket.context=identity('one','viewer');
 const client=new SessionClient({url:'ws://server/session',credential:'signed-token',reconnect:false,timeout:100});
 await assert.rejects(client.connect(),/Could not connect|connection closed/);
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(client.ready,false);assert.equal(client.workspace,null);client.close();
});

test('documents opened during sign-in wait for the verified account scope',async()=>{
 const client=new SessionClient({url:'ws://server/session',persist:false});
 client.ready=true;client.socket={readyState:1};client.hello={};client.cacheIdentity=identity('one','viewer');
 client.workspace=cacheNamespace(client.options.url,client.cacheIdentity);client.cacheable=true;
 let finish;client.rawRequest=()=>new Promise(resolve=>{finish=resolve;});
 const doc=new Y.Doc(),update=Buffer.from(Y.encodeStateAsUpdate(doc)).toString('base64'),vector=Buffer.from(Y.encodeStateVector(doc)).toString('base64');doc.destroy();
 client.request=async()=>({update,vector});
 const login=client.login('signed-token'),opening=client.openDoc('new.txt');
 assert.equal(client.docs.size,0);
 finish({login:'alice',id:1,cacheIdentity:identity('one','account:1')});
 await login;const opened=await opening;
 assert.equal(opened.workspace,client.workspace);assert.equal(client.cacheIdentity.principal,'account:1');
 client.ready=false;await opened.close();
});

test('editor projections become read-only on replacement and release their event hook',async()=>{
 const callbacks=new Map(),ydoc=new Y.Doc(),events=[];ydoc.getText('text').insert(0,'old workspace');
 const client={on(event,fn){callbacks.set(event,fn);return()=>callbacks.delete(event);},openDoc:async()=>({ydoc,path:'a',close:async()=>{}})};
 const views=new EditorDocuments(client,event=>events.push(event));
 await views.request('view.open',{handle:'a',path:'a'});await views.request('view.ready',{handle:'a'});
 callbacks.get('context-changed')({message:'Reopen this workspace'});
 assert.equal(events.at(-1).ev,'view.error');
 assert.equal(events.at(-1).code,'workspace-changed');
 await assert.rejects(views.request('view.edit',{handle:'a',epoch:0,serial:1,parts:[{from:0,removed:'',inserted:'wrong'}]}),/Reopen/);
 assert.equal(ydoc.getText('text').toString(),'old workspace');
 await views.request('view.close',{handle:'a'});views.close();assert.equal(callbacks.size,0);ydoc.destroy();
});

test('closing during identity lookup cancels opening before subscription or identity ownership',async()=>{
 const client=new SessionClient({url:'ws://server/session',persist:false}),calls=[];
 client.ready=true;client.hello={documentIdentities:1,documentLookup:1};
 let finishLookup;client.request=async(op)=>{calls.push(op);if(op==='doc.lookup')return new Promise(resolve=>{finishLookup=resolve;});return {};};
 const opening=client.openDoc('file.txt'),rejected=assert.rejects(opening,/closed/);
 await client.docs.get('file.txt').close();finishLookup({documentId:'a'.repeat(64)});await rejected;
 assert.equal(calls.includes('doc.open'),false);assert.equal(client.docs.size,0);assert.equal(client.documentIds.size,0);
});

test('identity downgrade fences one projection without disabling another document',async()=>{
 const client=new SessionClient({url:'ws://server/session',persist:false}),events=[];
 client.ready=true;client.hello={documentIdentities:1,documentLookup:1};
 const server=new Y.Doc();server.getText('text').insert(0,'original');
 const b64=bytes=>Buffer.from(bytes).toString('base64'),ids={'a.txt':'a'.repeat(64),'b.txt':'b'.repeat(64)};
 client.request=async(op,params)=>op==='doc.lookup'?{documentId:ids[params.path]}:op==='doc.open'?{documentId:ids[params.path],update:b64(Y.encodeStateAsUpdate(server)),vector:b64(Y.encodeStateVector(server))}:{};
 const views=new EditorDocuments(client,event=>events.push(event));
 await views.request('view.open',{handle:'a',path:'a.txt'});await views.request('view.ready',{handle:'a'});
 await views.request('view.open',{handle:'b',path:'b.txt'});await views.request('view.ready',{handle:'b'});
 client.hello.documentIdentities=0;
 await assert.rejects(client.docs.get('a.txt').sync(),/no longer verifies/);
 assert.equal(events.at(-1).handle,'a');assert.equal(events.at(-1).code,'document-changed');
 await assert.rejects(views.request('view.ready',{handle:'a'}),/no longer verifies/);
 await assert.rejects(views.request('view.edit',{handle:'a',epoch:0,serial:1,parts:[{from:0,removed:'',inserted:'wrong'}]}),/no longer verifies/);
 assert.equal(views.documents.get('b').ready,true);
 assert.equal(views.documents.get('a').shadow.getText('text').toString(),'original');
 client.ready=false;views.close();await Promise.all([...client.docs.values()].map(doc=>doc.close()));server.destroy();
 assert.equal(client.documentIds.size,0);
});

test('failed account recovery migration fences the authenticated connection before resuming documents',async()=>{
 const client=new SessionClient({url:'ws://server/session',persist:false});
 client.ready=true;client.socket={close(){}};client.hello={};client.cacheIdentity=identity('one','viewer');
 client.workspace=cacheNamespace(client.options.url,client.cacheIdentity);client.cacheable=true;
 client.rawRequest=async()=>({login:'alice',id:1,cacheIdentity:identity('one','account:1')});
 let synced=0;
 client.docs.set('a',{workspace:client.workspace,started:Promise.resolve(),moveRecovery:async()=>{throw Error('storage unavailable');},sync:async()=>{synced++;}});
 await assert.rejects(client.login('credential'),/storage unavailable/);
 assert.equal(client.invalidated.code,'workspace-changed');assert.equal(client.ready,false);assert.equal(synced,0);
 await assert.rejects(client.request('doc.update',{}),/workspace or account changed/);
 client.docs.clear();client.close();
});
