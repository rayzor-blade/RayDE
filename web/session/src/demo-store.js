const invalid=()=>Object.assign(Error('The demo recovery binding changed. Your previous edits are kept in this browser.'),{code:'workspace-changed'});
const valid=row=>row?.version===1&&typeof row.draft==='string'&&/^[\w-]{36}$/.test(row.draft)&&
 (row.lease===null||/^[\w-]{43}$/.test(row.lease))&&(row.context===null||typeof row.context==='string'&&row.context.length<=4096);

/** A draft keeps its storage identity when its exact lease acquires compute. */
export class DemoStore {
 constructor(origin,release){this.key=JSON.stringify([1,origin,release]);this.opening=null;}
 async database(){return this.opening??=new Promise((resolve,reject)=>{
  const request=indexedDB.open('rayde-demo-bindings-v1',1);
  request.onupgradeneeded=()=>request.result.createObjectStore('bindings');
  request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
 });}
 async change(update){
  const database=await this.database();
  return new Promise((resolve,reject)=>{
   const tx=database.transaction('bindings','readwrite'),store=tx.objectStore('bindings'),get=store.get(this.key);let result,error;
   get.onsuccess=()=>{try{
    if(get.result!==undefined&&!valid(get.result))throw invalid();
    result=update(get.result??{version:1,draft:crypto.randomUUID(),lease:null,context:null});
    if(!valid(result))throw invalid();store.put(result,this.key);
   }catch(failure){error=failure;tx.abort();}};
   tx.oncomplete=()=>resolve(result);tx.onerror=tx.onabort=()=>reject(error??tx.error??invalid());
  });
 }
 open(){return this.change(row=>row);}
 bind(draft,lease,context){return this.change(row=>{
  if(row.draft!==draft || row.lease!==null&&row.lease!==lease || context!==undefined&&row.context!==null&&row.context!==context)throw invalid();
  return {...row,lease,...(context===undefined?{}:{context})};
 });}
 close(){this.opening?.then(db=>db.close(),()=>{});this.opening=null;}
}
