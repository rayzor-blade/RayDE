import test from 'node:test';
import assert from 'node:assert/strict';
import {samplePreset} from '../src/preset.js';
const preset=()=>({version:1,name:'Pocket Studio',root:'/work/pocket-studio',project:'pocket-studio/build.hxml',entries:[{path:'/work',directory:true,data:null},{path:'/work/pocket-studio',directory:true,data:null},{path:'/work/pocket-studio/build.hxml',directory:false,data:btoa('-cp src\n-main Main\n')}]});
test('a namespaced sample contains its own project and stays inside browser storage',()=>assert.equal(samplePreset(preset()).project,'pocket-studio/build.hxml'));
test('sample manifests reject traversal, unrelated files, duplicates and missing project files',()=>{
 for(const path of ['/home/web/settings.json','/work/pocket-studio/../private','/work/other/file']){
  const value=preset();value.entries.push({path,directory:false,data:''});assert.throws(()=>samplePreset(value));
 }
 const duplicate=preset();duplicate.entries.push(duplicate.entries[0]);assert.throws(()=>samplePreset(duplicate));
 const incomplete=preset();incomplete.entries.pop();assert.throws(()=>samplePreset(incomplete));
 const large=preset();large.entries[2].data='a'.repeat(3*1024*1024);assert.throws(()=>samplePreset(large));
});
