import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {CachedDemo,remoteDemoEntries} from '../src/cached-demo.js';

const root='/work/pocket-studio',configuration={mode:'browser',runner:'ash',buildFlags:['-O3']};
const encode=value=>Buffer.from(value).toString('base64');
const entry={path:root+'/src/Main.hx',directory:false,data:encode('class Main {}')};
const preset={preview:{release:'a'.repeat(64),entry:'demo/'+ 'a'.repeat(64)+'/index.html',configuration,
  inputs:{'src/Main.hx':createHash('sha256').update('class Main {}').digest('hex')}}};
const instance=entries=>new CachedDemo(preset,'https://rayde.org/dist/demo-workspace.json','https://preview.rayde.org',async()=>entries,{hello:{root}});

test('a matching published source opens its isolated artifact without a compiler',async()=>{
  const result=await instance([entry]).open(root,{buildFlags:['-O3'],runner:'ash',mode:'browser'});
  assert.equal(result.available,true);assert.equal(result.cached,true);
  assert.equal(result.url,`https://preview.rayde.org/dist/demo/${'a'.repeat(64)}/index.html`);
});
test('edited, missing, added inputs and changed runner flags cannot reuse a stale artifact',async()=>{
  for(const entries of [[],[{...entry,data:encode('class Changed {}')}],[entry,{...entry,path:root+'/src/Other.hx'}]])
    assert.equal((await instance(entries).open(root,configuration)).available,false);
  assert.equal((await instance([entry]).open(root,{...configuration,buildFlags:['-O0']})).available,false);
  assert.equal((await instance([entry]).open('/another-workspace',configuration)).available,false);
  assert.equal((await instance([entry,{path:root+'/data/tasks.json',directory:false,data:encode('[]')}]).open(root,configuration)).available,true);
  for(const name of ['README.md','.gitignore'])
    assert.equal((await instance([entry,{path:root+'/'+name,directory:false,data:encode('local notes')}]).open(root,configuration)).available,true);
});
test('the artifact must have a distinct trusted origin and a bounded manifest',()=>{
  assert.throws(()=>new CachedDemo(preset,'https://rayde.org/dist/sample.json','https://rayde.org',()=>[],{}));
  assert.throws(()=>new CachedDemo({...preset,preview:{...preset.preview,entry:'../private/index.html'}},'https://rayde.org/sample.json','https://preview.rayde.org',()=>[],{}));
});
test('remote validation excludes generated files and refuses an unbounded inventory',async()=>{
  const client={hello:{root},request:async(op,{path})=>op==='fs.list'?{entries:path===''?[{name:'src',kind:'dir'},{name:'.rayde',kind:'dir'},{name:'data',kind:'dir'}]:[{name:path==='data'?'tasks.json':'Main.hx',kind:'file'}]}:{data:entry.data}};
  assert.deepEqual(await remoteDemoEntries(client),[entry]);
  client.request=async()=>({entries:Array.from({length:513},(_,i)=>({name:'x'+i+'.txt',kind:'file'}))});
  await assert.rejects(remoteDemoEntries(client));
});
