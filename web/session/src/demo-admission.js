/** Admission begins after the editor is visible; failed requests never replace its local documents. */
export class DemoAdmission {
 constructor(client,{fetch=globalThis.fetch.bind(globalThis),now=Date.now,pause=ms=>new Promise(resolve=>setTimeout(resolve,ms)),locks=globalThis.navigator?.locks,changed=()=>{}}={}){
  this.client=client;this.fetch=fetch;this.now=now;this.pause=pause;this.locks=locks;this.changed=changed;
  this.closed=false;this.busy=null;this.state={status:'waiting',message:'Workspace connecting…'};this.abort=new AbortController();
  this.stop=client.on('disconnected',()=>{if(!this.closed&&this.state.status==='ready'){this.set('connecting','Reconnecting workspace…');void this.disconnected();}});
  this.connected=client.on('connected',()=>this.set('ready','Workspace connected'));
 }
 set(status,message){if(!this.closed){this.state={status,message};this.changed(this.state);}}
 expire(){this.client.stopTransport(Error('The demo session expired.'));this.set('expired','Demo session expired · edits kept locally');this.client.emit('disconnected',{code:'expired'});}
 async disconnected(){try{await this.request('status');}catch(error){if(!this.closed&&!this.client.ready&&[401,410].includes(error.status))this.expire();}}
 async request(action){
  const response=await this.fetch('/api/demo/'+action,{method:action==='status'?'GET':'POST',credentials:'same-origin',cache:'no-store',signal:AbortSignal.any([this.abort.signal,AbortSignal.timeout(15000)])});
  const body=await response.json().catch(()=>({}));
  if(!response.ok)throw Object.assign(Error(body.message??'The workspace could not connect.'),{status:response.status});
  return body;
 }
 start(retry=false){
  if(this.closed)return Promise.resolve();if(this.busy)return this.busy;
  const work=this.run(retry);this.busy=work;
  work.finally(()=>{if(this.busy===work)this.busy=null;});return work;
 }
 async run(retry){
  this.set('connecting','Workspace connecting…');
  try{
   if(this.client.invalidated)throw this.client.invalidated;
   const open=async()=>{
    let lease=await this.request('open');
    if(lease.release!==this.client.source.release)throw Error('The demo source release changed. Your edits are kept in this browser.');
    this.client.binding=await this.client.store.bind(this.client.binding.draft,lease.id);
    if(retry&&lease.status==='failed')lease=await this.request('retry');
    return lease;
   };
   let lease=this.locks?await this.locks.request('rayde-demo-admission',open):await open();
   const deadline=Math.min(lease.expires,this.now()+180000);
   while(lease.status==='preparing'&&!this.closed){
    if(this.now()>=deadline)throw Error('Workspace startup is taking too long. Your edits are kept in this browser.');
    await this.pause(1000);if(this.closed)return;lease=await this.request('status');
    if(lease.id!==this.client.binding.lease||lease.release!==this.client.source.release)throw Error('The demo session changed. Your edits are kept in this browser.');
   }
   if(this.closed)return;
   if(lease.status!=='ready')throw Error(lease.message??'The workspace could not start. Your edits are kept in this browser.');
   clearTimeout(this.expiry);this.expiry=setTimeout(()=>this.expire(),Math.max(0,lease.expires-this.now()));
   await this.client.admit(lease);if(!this.closed)this.set('ready','Workspace connected');
  }catch(error){if(!this.closed)this.set(error.status===410?'expired':error.code==='workspace-changed'?'changed':'failed',error.message);}
 }
 close(){this.closed=true;clearTimeout(this.expiry);this.abort.abort();this.stop();this.connected();}
}

export function afterEditorReady(run,{document=globalThis.document,MutationObserver=globalThis.MutationObserver,later=callback=>globalThis.requestAnimationFrame(callback)}={}){
 let cancelled=false,scheduled=false,observer;const status=document.getElementById('status');
 const check=()=>{if(!scheduled&&(!status||status.hidden)){scheduled=true;observer?.disconnect();later(()=>later(()=>{if(!cancelled)run();}));}};
 if(status&&!status.hidden){observer=new MutationObserver(check);observer.observe(status,{attributes:true,attributeFilter:['hidden']});}
 check();return()=>{cancelled=true;observer?.disconnect();};
}
