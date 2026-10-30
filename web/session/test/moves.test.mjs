import test from 'node:test';
import assert from 'node:assert/strict';
import * as Y from 'yjs';
import {SessionClient,SessionError} from '../src/client.js';
import {EditorDocuments} from '../src/editor.js';

const encode=bytes=>Buffer.from(bytes).toString('base64');
const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};
const error=code=>new SessionError({code,message:code});
function fixture(){
 const client=new SessionClient({url:'ws://unused',persist:false}),calls=[],files=new Map(),opened=new Set(),events=[],holds=new Map();
 client.ready=true;client.workspace='scope';client.hello={documentIdentities:1,documentLookup:1,closedDocumentMoves:1};
 const add=(path,text,id)=>{const doc=new Y.Doc();doc.getText('text').insert(0,text);files.set(path,{id:id.repeat(64),doc});};
 add('src/a.txt','alpha','a');add('src/b.txt','beta','b');add('taken.txt','destination','c');
 client.request=async(op,params={})=>{
  calls.push({op,...params});
  if(holds.has(op)){const hold=holds.get(op);holds.delete(op);hold.entered.resolve();await hold.release.promise;}
  const file=files.get(params.path);
  if(op==='doc.lookup')return {documentId:file?.id??null};
  if(op==='doc.resolve')return {path:[...files].find(([,file])=>file.id===params.documentId)?.[0]??null};
  if(op==='doc.open'){
   if(!file)throw error('not-found');if(params.documentId&&params.documentId!==file.id)throw error('document-changed');
   opened.add(params.path);return {documentId:file.id,update:encode(Y.encodeStateAsUpdate(file.doc,Buffer.from(params.vector,'base64'))),vector:encode(Y.encodeStateVector(file.doc))};
  }
  if(op==='doc.close'){opened.delete(params.path);return {};}
  if(op==='doc.update'||op==='doc.save'){
   if(!file||params.documentId!==file.id)throw error('document-changed');if(!opened.has(params.path))throw error('not-open');
   if(op==='doc.update')Y.applyUpdate(file.doc,Buffer.from(params.update,'base64'));return {};
  }
  if(op==='fs.rename'){
   assert.equal(params.preserveDocuments,true);
   if(files.has(params.to))throw error('exists');
   if(client.otherPeer)throw error('document-open');
   const rows=[...files].filter(([path])=>path===params.from||path.startsWith(params.from+'/'));
   for(const [path]of rows)assert(!opened.has(path),'subscribers must be released before native mutation');
   const documents=rows.map(([path,file])=>({id:file.id,from:path,to:params.to+path.slice(params.from.length)}));
   for(const [path]of rows)files.delete(path);
   for(const [i,[,file]]of rows.entries())files.set(documents[i].to,file);
   if(client.lostReply)throw Error('connection lost after mutation');
   return {documents,revision:1};
  }
  throw Error('Unexpected request '+op);
 };
 const bridge=new EditorDocuments(client,event=>events.push(event));
 const hold=op=>{const value={entered:deferred(),release:deferred()};holds.set(op,value);return value;};
 const open=async(path='src/a.txt',handle='a')=>{await bridge.request('view.open',{handle,path});await bridge.request('view.ready',{handle});return bridge.documents.get(handle);};
 const close=async()=>{client.ready=false;bridge.close();await Promise.all([...client.docs.values()].map(doc=>doc.close()));for(const file of files.values())file.doc.destroy();};
 return {client,calls,files,opened,events,bridge,hold,open,close};
}

test('a directory move retains replica, projection and undo owners while queued typing follows its new path',async()=>{
 const f=fixture();try{
  const a=await f.open(),b=await f.open('src/b.txt','b'),doc=a.doc,undo=a.undo;
  await f.bridge.request('view.edit',{handle:'a',epoch:0,serial:1,parts:[{from:5,removed:'',inserted:'!'}]});
  const hold=f.hold('fs.rename'),moving=f.bridge.rename('src','destination');await hold.entered.promise;
  const queued=f.bridge.request('view.edit',{handle:'a',epoch:0,serial:2,parts:[{from:6,removed:'',inserted:' later'}]});
  assert.equal(a.text.toString(),'alpha!');assert.equal(f.client.docs.has('src/a.txt'),true);
  hold.release.resolve();await moving;await queued;await Promise.all([...doc.pending]);
  assert.equal(a.doc,doc);assert.equal(a.undo,undo);assert.equal(f.bridge.documents.get('a'),a);
  assert.equal(doc.path,'destination/a.txt');assert.equal(b.doc.path,'destination/b.txt');
  assert.equal(f.client.docs.get(doc.path),doc);assert.equal(f.client.docs.has('src/a.txt'),false);
  assert.deepEqual(f.events.filter(row=>row.ev==='workspace.moved'),[{ev:'workspace.moved',from:'src',to:'destination'}]);
  assert.equal(f.files.get(doc.path).doc.getText('text').toString(),'alpha! later');
  const reversed=await f.bridge.request('view.undo',{handle:'a',epoch:0,serial:3});
  assert.equal(reversed.text,'alpha!');
  await f.bridge.request('view.save',{handle:'a'});
  assert.equal(f.calls.filter(call=>call.op==='doc.save').at(-1).path,'destination/a.txt');
 }finally{await f.close();}
});

test('a move waits for prior saves without making new save or open requests deadlock',async()=>{
 const f=fixture();try{
  const view=await f.open(),hold=f.hold('doc.save');
  const saving=f.bridge.request('view.save',{handle:'a'});await hold.entered.promise;
  const moving=f.bridge.rename('src/a.txt','new.txt');
  const later=f.bridge.request('view.save',{handle:'a'});
  const opening=f.bridge.request('view.open',{handle:'new',path:'taken.txt'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.calls.some(call=>call.op==='fs.rename'),false);
  hold.release.resolve();await Promise.all([saving,moving,later,opening]);
  assert.equal(view.doc.path,'new.txt');assert.equal(f.calls.filter(call=>call.op==='doc.save').at(-1).path,'new.txt');
 }finally{await f.close();}
});

for(const reason of ['exists','document-open'])test('a refused move resumes the original editing and undo state: '+reason,async()=>{
 const f=fixture();try{
  const view=await f.open(),undo=view.undo;
  await f.bridge.request('view.edit',{handle:'a',epoch:0,serial:1,parts:[{from:5,removed:'',inserted:'!'}]});
  if(reason==='document-open')f.client.otherPeer=true;
  const hold=f.hold('fs.rename'),moving=f.bridge.rename('src/a.txt',reason==='exists'?'taken.txt':'new.txt');
  const refused=assert.rejects(moving,error=>error.code===reason);await hold.entered.promise;
  const queued=f.bridge.request('view.edit',{handle:'a',epoch:0,serial:2,parts:[{from:6,removed:'',inserted:' kept'}]});
  hold.release.resolve();await refused;await queued;await Promise.all([...view.doc.pending]);
  assert.equal(view.undo,undo);assert.equal(view.doc.path,'src/a.txt');assert.equal(view.doc.blocked,undefined);
  assert.equal(f.files.get('src/a.txt').doc.getText('text').toString(),'alpha! kept');
  assert(f.opened.has('src/a.txt'));assert.equal(f.events.length,0);
 }finally{await f.close();}
});

test('an unconfirmed mutation pauses the old projection and retains its replica without replaying into the old path',async()=>{
 const f=fixture();try{
  const view=await f.open();f.client.lostReply=true;
  await assert.rejects(f.bridge.rename('src/a.txt','new.txt'),/connection lost/);
  assert.equal(view.doc.path,'src/a.txt');assert.equal(view.text.toString(),'alpha');
  assert.equal(view.doc.blocked.code,'document-changed');assert.equal(view.ready,false);
  assert.equal(f.events.at(-1).code,'document-changed');assert(f.files.has('new.txt'));
  assert.equal(f.calls.filter(call=>call.op==='doc.open'&&call.path==='src/a.txt').length,2,'only initial open and pre-move sync can use the old path');
  await assert.rejects(f.bridge.request('view.edit',{handle:'a',epoch:0,serial:1,parts:[]}),/could not be confirmed/);
 }finally{await f.close();}
});

test('closing a raw document during the filesystem step cannot recreate its binding afterwards',async()=>{
 const f=fixture();try{
  const doc=await f.client.openDoc('src/a.txt'),hold=f.hold('fs.rename');
  const moving=f.client.rename('src/a.txt','new.txt');await hold.entered.promise;await doc.close();
  hold.release.resolve();await moving;
  assert.equal(f.client.docs.size,0);assert.equal(f.client.documentIds.size,0);
  assert.equal(f.calls.some(call=>call.op==='doc.open'&&call.path==='new.txt'),false);
 }finally{await f.close();}
});

test('opens deferred by sign-in recheck moves scheduled by the same authentication completion',async()=>{
 const f=fixture();try{
  const auth=deferred();f.client.authentication=auth.promise;
  auth.promise.then(()=>{f.client.authentication=null;});
  const moving=f.client.rename('src/a.txt','new.txt'),opening=f.client.openDoc('new.txt');
  auth.resolve();await moving;const doc=await opening;
  assert.equal(doc.path,'new.txt');assert.equal(doc.text.toString(),'alpha');
 }finally{await f.close();}
});

test('successive moves serialize without trapping pending saves behind a later move',async()=>{
 const f=fixture();try{
  const view=await f.open(),a=f.client.rename('src/a.txt','first.txt'),b=f.client.rename('first.txt','second.txt'),saving=view.doc.save();
  await Promise.all([a,b,saving]);assert.equal(view.doc.path,'second.txt');
  assert.equal(f.calls.filter(call=>call.op==='doc.save').at(-1).path,'second.txt');
 }finally{await f.close();}
});
