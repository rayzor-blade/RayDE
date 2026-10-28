// App frames have their own origin; only scoped workspace file calls cross back to the editor.
export class AppPreviews {
  constructor(client,screen=document.querySelector('#screen'),emit=()=>{}) {
    this.client=client;this.screen=screen;this.emit=emit;this.descriptors=new Map();this.surfaces=new Map();this.pending=new Set();this.pendingBytes=0;
    this.receive=event=>void this.files(event);addEventListener('message',this.receive);
    this.resize=()=>this.layout();addEventListener('resize',this.resize);addEventListener('scroll',this.resize,true);
  }
  register(value) {
    const url=new URL(value.url);
    if(!/^[a-f0-9]{64}$/.test(value.preview)||url.origin===location.origin||!['https:','http:'].includes(url.protocol))throw Error('The app preview needs an isolated origin.');
    if(url.protocol==='http:'&&!['127.0.0.1','localhost','[::1]'].includes(url.hostname))throw Error('The app preview requires HTTPS.');
    if(this.descriptors.size>=8&&!this.descriptors.has(value.preview))throw Error('Too many app previews.');
    this.descriptors.set(value.preview,{preview:value.preview,url:url.href,origin:url.origin});
  }
  update(request) {
    if(typeof request.surface!=='string'||request.surface.length>128)throw Error('Invalid preview surface.');
    if(request.remove){this.remove(request.surface);return {};}
    const descriptor=this.descriptors.get(request.preview);if(!descriptor)throw Error('This app preview is unavailable.');
    const args=request.arguments??[];
    if(!Array.isArray(args)||args.length>256||args.some(arg=>typeof arg!=='string')||args.join('').length>4096)throw Error('The preview program arguments are too large.');
    for(const field of ['x','y','width','height','viewportWidth','viewportHeight'])if(!Number.isFinite(request[field])||Math.abs(request[field])>100000)throw Error('Invalid preview bounds.');
    const exclusions=request.exclusions??[];
    if(!Array.isArray(exclusions)||exclusions.length>32||exclusions.some(rect=>!rect||['x','y','width','height'].some(field=>!Number.isFinite(rect[field])||Math.abs(rect[field])>100000)||rect.width<0||rect.height<0))throw Error('Invalid preview overlays.');
    let surface=this.surfaces.get(request.surface);
    if(surface&&surface.preview!==request.preview){this.remove(request.surface);surface=null;}
    if(!surface){
      if(this.surfaces.size>=4)throw Error('Too many preview surfaces.');
      const iframe=document.createElement('iframe');iframe.title='Application preview';iframe.dataset.raydeAppPreview=request.surface;
      iframe.sandbox='allow-scripts allow-same-origin';iframe.allow='cross-origin-isolated';iframe.referrerPolicy='strict-origin';
      const url=new URL(descriptor.url);for(const arg of args)url.searchParams.append('arg',arg);
      iframe.style.cssText='position:fixed;border:0;z-index:20;background:transparent;';iframe.src=url.href;
      surface={iframe,preview:request.preview,origin:descriptor.origin,bounds:request};this.surfaces.set(request.surface,surface);document.body.append(iframe);
    }
    surface.bounds=request;this.layout();return {};
  }
  layout() {
    const box=this.screen?.getBoundingClientRect();if(!box)return;
    for(const surface of this.surfaces.values()){
      const b=surface.bounds,sx=box.width/Math.max(1,b.viewportWidth),sy=box.height/Math.max(1,b.viewportHeight);
      const style=surface.iframe.style;style.visibility=b.visible===false?'hidden':'visible';
      style.left=(box.left+b.x*sx)+'px';style.top=(box.top+b.y*sy)+'px';style.width=Math.max(0,b.width*sx)+'px';style.height=Math.max(0,b.height*sy)+'px';
      style.clipPath=this.clip(b,sx,sy);
    }
  }
  clip(bounds,sx,sy) {
    if(!bounds.exclusions?.length)return '';
    let regions=[{left:0,top:0,right:Math.max(0,bounds.width*sx),bottom:Math.max(0,bounds.height*sy)}],changed=false;
    // Disjoint rectangles preserve overlapping tooltip cutouts and their pointer hit regions.
    for(const exclusion of bounds.exclusions){
      const hole={left:(exclusion.x-bounds.x)*sx,top:(exclusion.y-bounds.y)*sy,right:(exclusion.x+exclusion.width-bounds.x)*sx,bottom:(exclusion.y+exclusion.height-bounds.y)*sy},next=[];
      for(const region of regions){
        const left=Math.max(region.left,hole.left),top=Math.max(region.top,hole.top),right=Math.min(region.right,hole.right),bottom=Math.min(region.bottom,hole.bottom);
        if(left>=right||top>=bottom){next.push(region);continue;}
        changed=true;
        if(region.top<top)next.push({...region,bottom:top});
        if(bottom<region.bottom)next.push({...region,top:bottom});
        if(region.left<left)next.push({left:region.left,top,right:left,bottom});
        if(right<region.right)next.push({left:right,top,right:region.right,bottom});
      }
      regions=next;
    }
    return changed ? `path("${regions.map(r=>`M${r.left} ${r.top}H${r.right}V${r.bottom}H${r.left}Z`).join(' ')||'M0 0Z'}")` : '';
  }
  remove(id){const surface=this.surfaces.get(id);surface?.iframe.remove();this.surfaces.delete(id);}
  unregister(preview){for(const [id,surface] of this.surfaces)if(surface.preview===preview)this.remove(id);this.descriptors.delete(preview);}
  reset(){for(const id of [...this.surfaces.keys()])this.remove(id);this.descriptors.clear();}
  async files(event) {
    if(!['rayde-preview-files','rayde-preview-title'].includes(event.data?.type))return;
    const surface=[...this.surfaces.values()].find(value=>event.source===value.iframe.contentWindow&&event.origin===value.origin);if(!surface)return;
    if(event.data.type==='rayde-preview-title'){
      if(typeof event.data.title!=='string'||event.data.title.length>512)return;
      const title=event.data.title.replace(/[\u0000-\u001f\u007f]/g,' ').trim().slice(0,256);
      if(title&&title!==surface.title){surface.title=title;surface.iframe.title=title;this.emit({ev:'preview.title',preview:surface.preview,title});}
      return;
    }
    const request=event.data.request;if(!request||!Number.isSafeInteger(request.id)||typeof request.op!=='string')return;
    let reply;
    const ticket={bytes:typeof request.data==='string'?request.data.length:0};
    try {
      if(this.pending.size>=32||this.pendingBytes+ticket.bytes>16*1024*1024)throw Error('The preview filesystem queue is full.');this.pending.add(ticket);this.pendingBytes+=ticket.bytes;
      if(request.op==='preview.fs.hello')reply={root:this.client.hello.root};
      else {
        if(!['fs.stat','fs.list','fs.read','fs.write','fs.mkdir','fs.remove','fs.rename'].includes(request.op))throw Error('This preview may only access workspace files.');
        const params={};
        if(request.op==='fs.rename'){params.from=this.path(request.from,true);params.to=this.path(request.to,true);}
        else params.path=this.path(request.path,!['fs.stat','fs.list','fs.read'].includes(request.op));
        if(request.op==='fs.write'){
          if(typeof request.data!=='string'||request.data.length>12*1024*1024)throw Error('The preview write is too large.');
          params.data=request.data;params.encoding=request.encoding==='base64'?'base64':'utf8';
        }
        if(request.op==='fs.read'){params.encoding=request.encoding==='base64'?'base64':'utf8';}
        reply=await this.client.request(request.op,params);
      }
      reply={...reply,id:request.id,ok:true};
    } catch(error){reply={id:request.id,ok:false,message:error.message};}
    finally{if(this.pending.delete(ticket))this.pendingBytes-=ticket.bytes;}
    if(this.surfaces.get(surface.bounds.surface)===surface)event.source.postMessage({type:'rayde-preview-files-reply',reply},surface.origin);
  }
  path(value,write) {
    if(typeof value!=='string'||value.includes('\0')||value.includes('\\')||value.split('/').includes('..'))throw Error('Invalid preview file path.');
    const root=this.client.hello.root.replace(/\/$/,''),full=value.startsWith('/')?value:root+'/'+value;
    if(full!==root&&!full.startsWith(root+'/'))throw Error('The path leaves the preview workspace.');
    const relative=full===root?'':full.slice(root.length+1);
    if(relative.split('/').some(part=>['.git','.rayde','.rayde-session','.haxelib'].includes(part)))throw Error('This path is private to the workspace host.');
    if(write&&!relative)throw Error('The preview cannot replace its workspace.');return relative;
  }
  dispose(){this.reset();removeEventListener('message',this.receive);removeEventListener('resize',this.resize);removeEventListener('scroll',this.resize,true);}
}
