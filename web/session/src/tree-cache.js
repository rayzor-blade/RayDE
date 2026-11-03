const MAX_DIRECTORIES = 256, MAX_BYTES = 4*1024*1024;
const clean = path => typeof path === 'string' && !path.startsWith('/') && !/[\\\0]/.test(path) &&
  (path === '' || path.split('/').every(part => part && part !== '.' && part !== '..'));
const parent = path => path.slice(0,Math.max(0,path.lastIndexOf('/')));
const under = (path,dir) => dir === '' || path === dir || path.startsWith(dir+'/');
const raced = () => Object.assign(Error('The directory changed while loading.'),{code:'tree-changed'});

/** Visited directory metadata is disposable; document contents remain in the CRDT and authoritative filesystem calls bypass this cache. */
export class TreeCache {
  constructor(client,{storage=new TreeStorage(),changed=()=>{},now=Date.now}={}) {
    this.client=client;this.storage=storage;this.changed=changed;this.now=now;
    this.rows=new Map();this.reads=new Map();this.flights=new Map();this.versions=new Map();this.pending=new Map();
    this.bytes=0;this.epoch=0;this.closed=false;this.notifying=false;
    this.stops=[
      client.on('fs.changed',event=>{
        if(event.kind!=='change')this.invalidate(event.path);
        if(event.path?.split('/').at(-1)==='.gitignore'||event.path?.endsWith('.git/info/exclude'))this.notify();
      }),
      client.on('workspace.moved',event=>{this.invalidate(event.from);this.invalidate(event.to);}),
      client.on('connected',()=>{this.reset(false);this.notify();}),
      client.on('signed-in',()=>{this.reset(true);this.notify();}),
      client.on('context-changed',()=>this.reset(true))
    ];
  }
  guard() {
    if(this.closed || this.client.invalidated || this.client.accountPaused)throw this.client.invalidated ?? Error('The workspace connection is stopped.');
  }
  address(params) {
    const path=params.path??'',mount=params.mount??null;
    if(!clean(path))throw Error('Invalid directory path.');
    const source=mount===null ? null : this.client.hello.readRoots?.find(source=>source.id===mount);
    if(mount!==null&&!source)throw Error('Unknown installed source mount.');
    const scope=JSON.stringify([this.client.workspace,this.client.hello.root,mount,source?.path??null]);
    return {key:JSON.stringify([scope,path]),scope,path,params:{path,...(mount===null?{}:{mount})}};
  }
  notify() {
    if(this.notifying||this.closed)return;this.notifying=true;
    queueMicrotask(()=>{this.notifying=false;if(!this.closed)this.changed();});
  }
  reset(clear) {
    this.epoch++;this.flights.clear();this.reads.clear();this.versions.clear();
    if(clear){this.rows.clear();this.bytes=0;}
    else for(const row of this.rows.values())row.checked=0;
  }
  track(key,delta) {
    const count=(this.pending.get(key)??0)+delta;
    if(count>0)this.pending.set(key,count);
    else {this.pending.delete(key);if(!this.rows.has(key))this.versions.delete(key);}
  }
  put(address,entries,checked) {
    const bytes=JSON.stringify(entries).length*2;
    const previous=this.rows.get(address.key);if(previous)this.bytes-=previous.bytes;
    if(bytes>MAX_BYTES){this.rows.delete(address.key);return null;}
    const row={...address,entries,checked,bytes};
    this.rows.delete(address.key);this.rows.set(address.key,row);this.bytes+=bytes;
    while(this.rows.size>MAX_DIRECTORIES||this.bytes>MAX_BYTES){const [key,old]=this.rows.entries().next().value;this.rows.delete(key);this.bytes-=old.bytes;if(!this.pending.has(key))this.versions.delete(key);}
    return row;
  }
  async list(params={},retry=0) {
    this.guard();const address=this.address(params),known=this.rows.get(address.key);
    if(known) {
      this.rows.delete(address.key);this.rows.set(address.key,known);
      if(this.client.ready&&this.now()-known.checked>15000)this.load(address).catch(()=>{});
      return {entries:structuredClone(known.entries)};
    }
    if(this.reads.has(address.key))return this.reads.get(address.key);
    const epoch=this.epoch,version=this.versions.get(address.key)??0;
    const work=(async()=>{
      const saved=this.client.cacheable&&this.client.options?.persist!==false ? await this.storage.get(address.key).catch(()=>null) : null;
      this.guard();if(epoch!==this.epoch||(this.versions.get(address.key)??0)!==version)throw raced();
      if(saved?.version===1&&saved.key===address.key&&valid(saved.entries)&&JSON.stringify(saved.entries).length*2<=MAX_BYTES) {
        this.put(address,saved.entries,0);
        if(this.client.ready)this.load(address).catch(()=>{});
        return {entries:structuredClone(saved.entries)};
      }
      return this.load(address);
    })();
    this.reads.set(address.key,work);this.track(address.key,1);
    try{return await work;}
    catch(error){
      if(error.code!=='tree-changed'||retry>=2)throw error;
      if(this.reads.get(address.key)===work)this.reads.delete(address.key);
      return this.list(params,retry+1);
    }finally{if(this.reads.get(address.key)===work)this.reads.delete(address.key);this.track(address.key,-1);}
  }
  load(address) {
    if(this.flights.has(address.key))return this.flights.get(address.key);
    const epoch=this.epoch,version=this.versions.get(address.key)??0;
    const work=(async()=>{
      const reply=await this.client.request('fs.list',address.params);
      this.guard();if(epoch!==this.epoch||(this.versions.get(address.key)??0)!==version)throw raced();
      if(!valid(reply.entries))throw Error('Invalid directory metadata.');
      const old=this.rows.get(address.key),different=old&&JSON.stringify(old.entries.map(e=>[e.name,e.kind]))!==JSON.stringify(reply.entries.map(e=>[e.name,e.kind]));
      const row=this.put(address,reply.entries,this.now());
      if(row&&this.client.cacheable&&this.client.options?.persist!==false)
        this.storage.put({version:1,key:address.key,entries:reply.entries,used:this.now()}).catch(()=>{});
      if(different)this.notify();
      return {entries:structuredClone(reply.entries)};
    })();
    this.flights.set(address.key,work);this.track(address.key,1);
    work.finally(()=>{if(this.flights.get(address.key)===work)this.flights.delete(address.key);this.track(address.key,-1);}).catch(()=>{});
    return work;
  }
  invalidate(path='',mount=null,refresh=false) {
    if(!clean(path))return;
    const address=this.address({path,mount});
    const keys=new Set([...this.rows.keys(),...this.flights.keys(),...this.reads.keys()]);let changed=false;
    for(const key of keys) {
      const [scope,dir]=JSON.parse(key);
      if(scope!==address.scope||!(dir===parent(path)||under(dir,path)))continue;
      changed=true;
      this.versions.set(key,(this.versions.get(key)??0)+1);
      this.flights.delete(key);
      const row=this.rows.get(key);
      if(row){row.checked=0;if(!refresh&&this.client.ready)this.load(row).catch(()=>{});}
    }
    if(changed&&refresh)this.notify();
  }
  close() {this.closed=true;this.reset(true);for(const stop of this.stops)stop();this.storage.close();}
}

function valid(entries) {
  return Array.isArray(entries)&&
    entries.every(entry=>entry&&typeof entry.name==='string'&&entry.name.length>0&&entry.name.length<=4096&&
      !/[\/\\\0]/.test(entry.name)&&entry.name!=='.'&&entry.name!=='..'&&['dir','file','other'].includes(entry.kind)&&
      Number.isFinite(entry.size)&&entry.size>=0&&Number.isFinite(entry.mtime)&&entry.mtime>=0);
}

/** A bounded metadata store, separate from durable document recovery. Cache failures never prevent navigation. */
export class TreeStorage {
  constructor(){this.database=null;}
  async open() {
    if(!this.database)this.database=new Promise((resolve,reject)=>{
      const request=indexedDB.open('rayde-visited-tree-v1',1);
      request.onupgradeneeded=()=>{request.result.createObjectStore('directories',{keyPath:'key'});request.result.createObjectStore('usage',{keyPath:'key'});};
      request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
    });
    return this.database;
  }
  async get(key) {
    const db=await this.open();return new Promise((resolve,reject)=>{
      const request=db.transaction('directories').objectStore('directories').get(key);
      request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
    });
  }
  async put(row) {
    const db=await this.open();return new Promise((resolve,reject)=>{
      const tx=db.transaction(['directories','usage'],'readwrite'),store=tx.objectStore('directories'),usage=tx.objectStore('usage');
      store.put(row);usage.put({key:row.key,used:row.used,bytes:JSON.stringify(row).length*2});const request=usage.getAll();
      request.onsuccess=()=>{
        const rows=request.result.sort((a,b)=>b.used-a.used);let bytes=0;
        for(let i=0;i<rows.length;i++){bytes+=rows[i].bytes;if(i>=MAX_DIRECTORIES||bytes>MAX_BYTES){store.delete(rows[i].key);usage.delete(rows[i].key);}}
      };
      tx.oncomplete=()=>resolve();tx.onerror=tx.onabort=()=>reject(tx.error??Error('Directory metadata could not be cached.'));
    });
  }
  close(){this.database?.then(db=>db.close()).catch(()=>{});this.database=null;}
}
