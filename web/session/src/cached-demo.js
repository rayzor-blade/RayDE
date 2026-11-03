const digest = /^[a-f0-9]{64}$/;
const privatePart = path => path.split('/').some(part => ['.git','.rayde','.rayzor','.haxelib','.rayde-session'].includes(part));
export const demoInput = path => !privatePart(path) && path!=='data/tasks.json' && !['bin','build','Export'].includes(path.split('/')[0]);
const sha = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),byte=>byte.toString(16).padStart(2,'0')).join('');
const canonical = value => JSON.stringify(value,(_,item)=>item && typeof item==='object' && !Array.isArray(item) ? Object.fromEntries(Object.entries(item).sort(([a],[b])=>a.localeCompare(b))) : item);
const decode = data => Uint8Array.from(atob(data),char=>char.charCodeAt(0));

export async function remoteDemoEntries(client) {
  const entries=[];let bytes=0,count=0;
  async function walk(path) {
    for(const entry of (await client.request('fs.list',{path})).entries) {
      if(++count>512)throw Error('The demo workspace has too many files.');
      const name=path?path+'/'+entry.name:entry.name;
      if(privatePart(name)||['bin','build','Export'].includes(name.split('/')[0]))continue;
      if(entry.kind==='dir')await walk(name);
      else if(demoInput(name)) {
        const file=await client.request('fs.read',{path:name,encoding:'base64'});
        bytes+=file.data.length;if(bytes>3*1024*1024)throw Error('The demo sources are too large.');
        entries.push({path:client.hello.root+'/'+name,directory:false,data:file.data});
      }
    }
  }
  await walk('');return entries;
}

/** Public app artifacts are usable only for their matching source inputs. */
export class CachedDemo {
  constructor(preset, base, origin, entries, client) {
    const value=preset.preview;
    if(!value || !digest.test(value.release) || value.entry!==`demo/${value.release}/index.html` ||
       !value.configuration || value.configuration.mode!=='browser' || canonical(value.configuration).length>128*1024 ||
       !value.inputs || typeof value.inputs!=='object' || Array.isArray(value.inputs) || Object.keys(value.inputs).length>256 ||
       Object.entries(value.inputs).some(([path,hash])=>!path || path.startsWith('/') || path.split('/').some(part=>!part || part==='.' || part==='..') || path.includes('\\') || !demoInput(path) || !digest.test(hash))) throw Error('Invalid demo preview manifest.');
    const url=new URL(value.entry,base),host=new URL(origin);
    if(!['https:','http:'].includes(host.protocol)||host.username||host.password||host.origin===new URL(base).origin ||
       host.protocol==='http:'&&!['127.0.0.1','localhost','[::1]'].includes(host.hostname))throw Error('The demo preview needs an isolated HTTPS origin.');
    url.protocol=host.protocol;url.host=host.host;
    this.preset=preset;this.entries=entries;this.client=client;
    this.artifact={preview:value.release,url:url.href,path:'',cached:true};
  }
  async open(root,configuration) {
    if(root!==this.client.hello.root || canonical(configuration)!==canonical(this.preset.preview.configuration)) return {available:false};
    const entries=await this.entries(),inputs=entries.filter(entry=>!entry.directory && entry.path.startsWith(root+'/') && demoInput(entry.path.slice(root.length+1)));
    if(inputs.length!==Object.keys(this.preset.preview.inputs).length)return {available:false};
    for(const entry of inputs) {
      if(typeof entry.data!=='string'||entry.data.length>3*1024*1024)return {available:false};
      if(await sha(decode(entry.data))!==this.preset.preview.inputs[entry.path.slice(root.length+1)])return {available:false};
    }
    return {available:true,...this.artifact};
  }
}

