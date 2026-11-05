import {readFile,realpath,lstat} from 'node:fs/promises';
import {basename,resolve,sep} from 'node:path';
import {createHash} from 'node:crypto';

const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

/** Promote a prepared public release only after every listed asset has been verified. */
export async function stageEditorRelease(bucket,directory){
 const root=await realpath(directory),release=basename(root),manifest=await readFile(resolve(root,'manifest.json'));
 if(!/^[a-f0-9]{64}$/.test(release)||manifest.length>1024*1024||sha(manifest)!==release)throw Error('Invalid editor release identity.');
 const value=JSON.parse(manifest),files=Object.entries(value.files??{});
 if(value.version!==1||!value.files['index.html']||!value.files['dist/index.html']||files.length>4096)throw Error('Incomplete editor release.');
 let total=0;
 for(const [name,info]of files){
  if(typeof name!=='string'||name.includes('\\')||name.split('/').some(part=>!part||part.startsWith('.'))||name.startsWith('/')||
     !info||!Number.isSafeInteger(info.bytes)||info.bytes<0||info.bytes>256*1024*1024||!/^[a-f0-9]{64}$/.test(info.sha256))throw Error('Invalid editor release asset.');
  total+=info.bytes;if(total>1024*1024*1024)throw Error('Editor release exceeds 1 GiB.');
  const path=resolve(root,name);
  if(!path.startsWith(root+sep)||await realpath(path)!==path||!(await lstat(path)).isFile())throw Error('Editor release contains a non-regular asset.');
  const bytes=await readFile(path);
  if(bytes.length!==info.bytes||sha(bytes)!==info.sha256)throw Error('Editor release asset changed: '+name);
  await bucket.put(`releases/${release}/${name}`,bytes);
 }
 await bucket.put(`releases/${release}/manifest.json`,manifest);
 await bucket.put('editor-release.json',JSON.stringify({version:1,release}));
 return release;
}
