import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as Y from 'yjs';
import {Doc,SessionClient} from '../src/client.js';
import {EditorDocuments} from '../src/editor.js';
const b64=value=>Buffer.from(value).toString('base64');
function fixture(){
 const server=new Y.Doc();server.clientID=0;server.getText('text').insert(0,'shared');
 const client=new SessionClient({url:'ws://unused',persist:false});client.ready=true;client.workspace='cloud';client.hello={documentIdentities:1,cloudDocuments:1};let lineage='b'.repeat(64);const calls=[];
 client.request=async(op,params)=>{calls.push(op);if(op==='doc.open')return{documentId:'a'.repeat(64),cloudLineage:lineage,update:b64(Y.encodeStateAsUpdate(server,Buffer.from(params.vector,'base64'))),vector:b64(Y.encodeStateVector(server)),buffered:true,dirty:false};
 if(op==='doc.update')Y.applyUpdate(server,Buffer.from(params.update,'base64'));return{};};
 return{client,server,calls,setLineage:value=>{lineage=value;}};
}

test('a fresh cloud binding uses the shared seed, sends an empty durability barrier, and retains its undo owner',async()=>{
 const f=fixture(),events=[],views=new EditorDocuments(f.client,event=>events.push(event));
 const opened=await views.request('view.open',{path:'a',handle:'one'});assert.equal(opened.text,'shared');assert.ok(f.calls.includes('doc.update'),'an unchanged vector still sends the cloud barrier');
 await views.request('view.ready',{handle:'one'});await views.request('view.edit',{handle:'one',epoch:0,serial:1,parts:[{from:0,removed:'',inserted:'mine '}]});
 const doc=f.client.docs.get('a');await Promise.all([...doc.pending]);f.server.getText('text').insert(f.server.getText('text').length,' remote');await doc.sync();
 const offer=events.findLast(e=>e.ev==='view.remote');assert.ok(offer);await views.request('view.ack',{handle:'one',epoch:offer.epoch,accept:true});
 const undone=await views.request('view.undo',{handle:'one',epoch:offer.epoch,serial:2,redo:false});assert.equal(undone.text,'shared remote');assert.equal(f.server.getText('text').toString().includes('sharedshared'),false);
 await views.request('view.close',{handle:'one'});views.close();f.client.ready=false;f.client.close();f.server.destroy();
});

test('an unbound browser graph cannot merge into a fresh cloud seed',async()=>{
 const f=fixture();f.client.ready=false;const doc=new Doc(f.client,'a');doc.text.insert(0,'private legacy draft');f.client.ready=true;
 await assert.rejects(doc.sync(),error=>error.code==='document-lineage');assert.equal(doc.text.toString(),'private legacy draft');assert.equal(f.server.getText('text').toString(),'shared');assert.equal(f.calls.includes('doc.update'),false);
 await doc.close();f.client.ready=false;f.client.close();f.server.destroy();
});

test('a changed cloud lineage pauses a bound replica before applying its replacement',async()=>{
 const f=fixture(),doc=await f.client.openDoc('a');const before=Y.encodeStateAsUpdate(doc.ydoc);f.setLineage('c'.repeat(64));
 await assert.rejects(doc.sync(),error=>error.code==='document-lineage');assert.deepEqual(Y.encodeStateAsUpdate(doc.ydoc),before);assert.equal(doc.blocked.code,'document-lineage');
 await doc.close();f.client.ready=false;f.client.close();f.server.destroy();
});

test('incoming buffered changes mark the editor projection as needing Save',async()=>{
 const f=fixture(),events=[],views=new EditorDocuments(f.client,event=>events.push(event));
 await views.request('view.open',{path:'a',handle:'one'});await views.request('view.ready',{handle:'one'});
 const doc=f.client.docs.get('a'),peer=new Y.Doc();Y.applyUpdate(peer,Y.encodeStateAsUpdate(f.server));peer.getText('text').insert(0,'peer ');
 f.client.receive({ev:'doc.update',path:'a',update:b64(Y.encodeStateAsUpdate(peer,Y.encodeStateVector(doc.ydoc)))});
 const offered=events.findLast(event=>event.ev==='view.remote');assert.equal(offered.text,'peer shared');assert.equal(offered.dirty,true);
 await views.request('view.close',{handle:'one'});views.close();peer.destroy();f.client.ready=false;f.client.close();f.server.destroy();
});

test('expired cloud acknowledgement keeps edits available locally and refuses Save',async()=>{
 const f=fixture(),doc=await f.client.openDoc('a'),request=f.client.request;
 f.client.request=async(op,params)=>{if(op==='doc.update')throw Object.assign(Error('expired'),{code:'sync-auth'});return request(op,params);};
 doc.text.insert(0,'kept ');await Promise.all([...doc.pending]);assert.equal(doc.unsent,true);assert.match(doc.cloudMessage,/expired/);assert.equal(doc.blocked,undefined);
 await assert.rejects(doc.save(),/Reconnect/);assert.equal(doc.text.toString(),'kept shared');assert.equal(f.server.getText('text').toString(),'shared');assert.equal(f.calls.includes('doc.save'),false);
 await doc.close();f.client.ready=false;f.client.close();f.server.destroy();
});

test('pushed transport status preserves local edits and fences only a changed document history',async()=>{
 const f=fixture(),events=[],views=new EditorDocuments(f.client,event=>events.push(event));await views.request('view.open',{path:'a',handle:'one'});
 const doc=f.client.docs.get('a');f.client.ready=false;doc.text.insert(0,'private ');const before=Y.encodeStateAsUpdate(doc.ydoc);
 f.client.receive({ev:'doc.status',path:'a',code:'cloud-offline',message:'Cloud updates disconnected'});assert.equal(doc.blocked,undefined);assert.equal(doc.unsent,true);assert.ok(events.some(event=>event.ev==='view.status'));
 f.client.receive({ev:'doc.status',path:'a',code:null,message:''});assert.equal(doc.cloudMessage,'');
 f.client.receive({ev:'doc.status',path:'a',code:'document-lineage',message:'History changed'});assert.equal(doc.blocked.code,'document-lineage');assert.deepEqual(Y.encodeStateAsUpdate(doc.ydoc),before);
 views.close();f.client.close();f.server.destroy();
});
