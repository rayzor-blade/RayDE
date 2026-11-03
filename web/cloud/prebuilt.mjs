import {createHash} from 'node:crypto';
import {existsSync,readFileSync,readdirSync,renameSync,statSync,writeFileSync} from 'node:fs';
import {relative,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';

const root=fileURLToPath(new URL('.',import.meta.url));
const inputs=['Cargo.toml','Cargo.lock','package.json','package-lock.json','build.sh','prebuilt.mjs','src','../../native/session/Cargo.toml','../../native/session/src','../../native/sync/Cargo.toml','../../native/sync/src'];
function files(path){
 if(!statSync(path).isDirectory())return[path];
 return readdirSync(path,{withFileTypes:true}).filter(entry=>!entry.name.startsWith('.')).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(entry=>files(resolve(path,entry.name)));
}
function digest(base,paths){
 const hash=createHash('sha256');
 for(const path of paths.sort()){
  const bytes=readFileSync(path);hash.update(JSON.stringify([relative(base,path).split('\\').join('/'),bytes.length]));hash.update(bytes);
 }
 return hash.digest('hex');
}
function current(base){
 const build=resolve(base,'build');
 if(!existsSync(resolve(build,'index.js'))||!existsSync(resolve(build,'index_bg.wasm')))throw Error('No compiled Worker is available. Run npm run build locally first.');
 return{version:1,inputs:digest(base,inputs.flatMap(path=>files(resolve(base,path)))),artifacts:digest(build,files(build).filter(path=>!['prebuilt.json','prebuilt.json.next'].includes(relative(build,path))))};
}
export function record(base=root){
 const value=current(base),path=resolve(base,'build/prebuilt.json');
 writeFileSync(path+'.next',JSON.stringify(value)+'\n');renameSync(path+'.next',path);return value;
}
export function verify(base=root){
 const stamp=resolve(base,'build/prebuilt.json');
 if(!existsSync(stamp))throw Error('No verified Worker build is available. Run npm run build locally first.');
 const recorded=JSON.parse(readFileSync(stamp,'utf8')),value=current(base);
 if(recorded.version!==1||recorded.inputs!==value.inputs)throw Error('Worker source or build inputs changed. Run npm run build locally before deploying.');
 if(recorded.artifacts!==value.artifacts)throw Error('Compiled Worker artifacts changed. Run npm run build locally before deploying.');
 return value;
}
export async function checkConfig(base=root,args=[]){
 if(args.some(arg=>['-c','--config','--cwd','-e','--env'].some(flag=>arg===flag||arg.startsWith(flag+'='))))throw Error('Prebuilt deployment uses this workspace’s wrangler.jsonc without an environment override.');
 const {experimental_readRawConfig}=await import('wrangler');
 const {rawConfig}=experimental_readRawConfig({config:resolve(base,'wrangler.jsonc')});
 if(rawConfig.build?.command)throw Error('Remove build.command from wrangler.jsonc before deploying prebuilt artifacts.');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 try{
  const [command,...args]=process.argv.slice(2);
  if(command==='stamp'){record();console.log('Recorded verified local Worker build.');}
  else if(command==='deploy'){
   const value=verify();await checkConfig(root,args);console.log(`Using verified prebuilt Worker ${value.artifacts.slice(0,12)}.`);
   const result=spawnSync('npx',['--no-install','wrangler','deploy','build/index.js',...args],{cwd:root,stdio:'inherit'});
   if(result.error)throw result.error;process.exitCode=result.status??1;
  }else throw Error('Usage: node prebuilt.mjs stamp|deploy [Wrangler options]');
 }catch(error){console.error(error.message);process.exitCode=1;}
}
