// The published demo's RayScript modules run in the real headless extension VM.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {readFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),extension=join(root,'site/demo/extensions/pocket-tools');
const source=await readFile(join(extension,'ext/main.rays'),'utf8');
const tasks=JSON.parse(await readFile(join(root,'site/demo/data/tasks.json'),'utf8'));
tasks[0].lane='Done';
const child=spawn(join(root,'bin/rayde-extension-host'),['--root',join(extension,'ext'),'--extension','pocket-tools'],{stdio:['pipe','pipe','pipe']});
const messages=[],errors=[];
child.stderr.on('data',bytes=>errors.push(String(bytes)));
const send=value=>child.stdin.write(JSON.stringify(value)+'\n');
createInterface({input:child.stdout}).on('line',line=>{
 const message=JSON.parse(line);messages.push(message);
 if(message.t==='call'){
  assert.equal(message.fn,'rayde.workspace.readFile');assert.equal(message.args[0],'data/tasks.json');
  send({t:'resolve',id:message.id,value:JSON.stringify(tasks)});
 }
});
async function until(test,label){const end=Date.now()+15000;while(!test()){
 const failure=messages.find(message=>message.t==='error');if(failure)throw Error(JSON.stringify(failure));
 if(child.exitCode!==null||Date.now()>end)throw Error(label+': '+errors.join(''));
 await new Promise(resolve=>setTimeout(resolve,20));
}}
try{
 await until(()=>messages.some(message=>message.t==='ready'),'host ready');
 send({t:'module',path:'rayde.workspace',functions:['readFile']});
 for(let iteration=0;iteration<2;iteration++){
  const before=messages.length;
  send({t:'run',name:join(extension,'ext/main.rays'),source});
  await until(()=>messages.slice(before).some(message=>message.t==='log'&&message.message==='Pocket Tools ready'),'sample mounted');
  assert.ok(messages.slice(before).some(message=>message.t==='registered'&&message.id==='pocket.summary'));
  assert.ok(messages.slice(before).some(message=>message.t==='ops'&&message.ops.some(op=>op[0]==='createText'&&op[2]==='Pocket Studio')));
  const clicks=messages.slice(before).flatMap(message=>message.t==='ops'?message.ops:[]).filter(op=>op[0]==='listen'&&op[2]==='click');
  assert.equal(clicks.length,1,'the panel exposes its refresh button');
  const clicked=messages.length;
  send({t:'event',node:clicks[0][1],event:'click',payload:{}});
  await until(()=>messages.slice(clicked).some(message=>message.t==='log'&&message.message==='Pocket Tools: 8 tasks, 3 done'),'preview button refresh');
  send({t:'command',id:'pocket.summary'});
  await until(()=>messages.slice(before).some(message=>message.t==='log'&&message.message==='Pocket Tools: 8 tasks, 3 done'),'workspace command');
  assert.ok(messages.slice(before).some(message=>message.t==='ops'&&message.ops.some(op=>op[0]==='setText')));
 }
 console.log('Pocket Tools: imported modules, mounted view, workspace command, reactive updates and reload passed.');
}finally{child.stdin.end();await new Promise(resolve=>{if(child.exitCode!==null)resolve();else child.once('exit',resolve);});}
