import * as Y from 'yjs';
import {SessionClient,Doc,cacheNamespace} from './client.js';
import {legacyName} from './recovery.js';

const pending=()=>Object.assign(Error('The workspace is connecting. Your edits are kept in this browser.'),{code:'connecting'});
const changed=()=>Object.assign(Error('This demo session changed. Your previous edits are kept in this browser.'),{code:'workspace-changed'});
const clean=path=>typeof path==='string'&&!path.startsWith('/')&&!/[\\\0]/.test(path)&&(path===''||path.split('/').every(part=>part&&part!=='.'&&part!=='..'));
const decode=data=>Uint8Array.from(atob(data),char=>char.charCodeAt(0));
const encode=bytes=>{let text='';for(let at=0;at<bytes.length;at+=32768)text+=String.fromCharCode(...bytes.subarray(at,at+32768));return btoa(text);};

class DemoDocument extends Doc {
 async start(){
  if(this.client.ready||this.client.attached)return super.start();
  const graph=this.client.source.graph(this.path);if(!graph)throw pending();
  this.suspended=true;
  await this.recover(legacyName(this.workspace,this.path));this.guard();
  Y.applyUpdate(this.ydoc,graph,'session');await this.checkpointGraph();
  this.restoredDirty=this.text.toString()!==new TextDecoder('utf-8',{ignoreBOM:true}).decode(decode(this.client.source.files.get(this.path)));
 }
}

/** Local document objects and projections survive the first verified remote handshake. */
export class DemoSession extends SessionClient {
 constructor({source,store,binding,root='/workspace/project',...options}){
  super(options);this.source=source;this.store=store;this.binding=binding;this.attached=false;
  this.workspace=JSON.stringify(['demo-draft-v1',store.key,binding.draft]);this.cacheable=true;
  this.expectedRoot=root;this.hello={root,name:source.preset.name,exec:false,syntax:true,deferred:true,documentIdentities:0,readRoots:[]};
  this.seedEntries=new Map([['',{name:'pocket-studio',kind:'dir',size:0,mtime:0}]]);
  for(const entry of source.preset.entries){
   if(entry.path===source.preset.root||!entry.path.startsWith(source.preset.root+'/'))continue;
   const path=entry.path.slice(source.preset.root.length+1);
   for(let at=path.indexOf('/');at>=0;at=path.indexOf('/',at+1)){
    const parent=path.slice(0,at);this.seedEntries.set(parent,{name:parent.split('/').at(-1),kind:'dir',size:0,mtime:0});
   }
   this.seedEntries.set(path,{name:path.split('/').at(-1),kind:entry.directory?'dir':'file',size:entry.directory?0:decode(entry.data).length,mtime:0});
  }
 }
 makeDocument(path){return new DemoDocument(this,path);}
 async acceptHello(hello){
  const context=cacheNamespace(this.options.url,hello.cacheIdentity);
  if(hello.root!==this.expectedRoot||hello.demoSeed?.version!==1||hello.demoSeed.release!==this.source.release||
     !context||!this.binding.lease||hello.cacheIdentity.principal!=='demo:'+this.binding.lease)throw this.invalidate();
  try{this.binding=await this.store.bind(this.binding.draft,this.binding.lease,context);}
  catch{throw this.invalidate();}
 }
 context(identity){
  if(cacheNamespace(this.options.url,identity)!==this.binding.context)throw this.invalidate();
  return {key:this.workspace,cacheable:true};
 }
 async prepareConnected(){
  this.attached=true;
  await Promise.all([...this.docs.values()].map(async doc=>{try{await doc.started;if(!doc.closed)await doc.sync();}catch(error){if(!doc.closed)throw error;}}));
 }
 async admit(lease){
  if(lease.release!==this.source.release||!Number.isSafeInteger(lease.expires)||lease.expires<=Date.now())throw changed();
  try{this.binding=await this.store.bind(this.binding.draft,lease.id);}
  catch{throw this.invalidate();}
  if(this.invalidated)throw this.invalidated;
  this.stopped=false;return this.connect();
 }
 request(op,params={}){
  if(this.ready||this.attached||params.mount!=null)return super.request(op,params);
  if(!op.startsWith('fs.'))return Promise.reject(pending());
  return this.localFile(op,params);
 }
 async localFile(op,{path='',data,encoding,offset=0,length}={}){
  if(!clean(path))throw Error('Invalid workspace path.');
  const entry=this.seedEntries.get(path);
  if(op==='fs.stat')return {entry:entry?structuredClone(entry):null};
  if(op==='fs.list'){
   if(entry?.kind!=='dir')throw Error('No such folder.');
   return {entries:[...this.seedEntries].filter(([name])=>name!==path&&(name.includes('/')?name.slice(0,name.lastIndexOf('/')):'')===path).map(([,entry])=>structuredClone(entry))};
  }
  if(entry?.kind!=='file')throw pending();
  if(op==='fs.read'){
   const doc=this.docs.get(path);if(doc&&!doc.closed)await doc.started;
   let bytes=doc&&!doc.closed?new TextEncoder().encode(doc.text.toString()):decode(this.source.files.get(path));
   if(!Number.isSafeInteger(offset)||offset<0||length!==undefined&&(!Number.isSafeInteger(length)||length<0))throw Error('Invalid file range.');
   bytes=bytes.subarray(offset,length===undefined?undefined:offset+length);
   return {data:encoding==='base64'?encode(bytes):new TextDecoder().decode(bytes)};
  }
  if(op==='fs.write'){
   if(typeof data!=='string')throw Error('Invalid file data.');
   const text=encoding==='base64'?new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(decode(data)):data;
   if(text.length>2*1024*1024)throw Error('The file is too large.');
   const doc=await this.openDoc(path);doc.ydoc.transact(()=>{doc.text.delete(0,doc.text.length);doc.text.insert(0,text);});
   await doc.checkpointGraph();return {};
  }
  throw pending();
 }
 close(error){super.close(error);this.store.close();}
}
