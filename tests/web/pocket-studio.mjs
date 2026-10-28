// Every Pocket Studio module previews its extension in the embedded editor.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp,mkdir,cp,symlink,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {createRequire} from 'node:module';
import {resolve,join,dirname} from 'node:path';
const root=resolve(import.meta.dirname,'../..');
const javascript=process.env.RAYDE_TEST_JAVASCRIPT==='1',appMode=javascript||process.env.RAYDE_TEST_APP==='1';
const puppeteer=createRequire(join(root,'web/session/package.json'))('puppeteer-core');
const shots=join(root,'bin/web/pocket-demo-browser-shots');await mkdir(shots,{recursive:true});
const fixture=await mkdtemp(join(root,'bin/published-demo/landing-'));
const privateRoot=await mkdtemp(join(tmpdir(),'rayde-builtins-'));
const web=join(privateRoot,'web');await mkdir(join(web,'dist'),{recursive:true});
await writeFile(join(privateRoot,'environment.json'),JSON.stringify({HAXELIB_PATH:join(process.env.HOME,'.rayde-session/demos/pocket-studio/.haxelib'),ASH_PROFILE:'phases'}));
await cp(join(root,'site/demo'),fixture,{recursive:true,filter:path=>!/(?:^|\/)bin(?:\/|$)/.test(path)});
const installed=join(process.env.HOME,'.rayde-session/demos/pocket-studio/.haxelib');
await mkdir(join(fixture,'.haxelib'),{recursive:true});
for(const name of await readdir(installed))await symlink(join(installed,name),join(fixture,'.haxelib',name));
await mkdir(join(fixture,'.rayde'),{recursive:true});await writeFile(join(fixture,'.rayde/settings.json'),JSON.stringify({extensions:{disabled:['rayzor','git','markdown','jam']}}));
await cp(join(fixture,'README.md'),join(fixture,'src/Guide.md'));
if(javascript){
 await mkdir(join(fixture,'public'),{recursive:true});
 await writeFile(join(fixture,'build.hxml'),'-cp src\n-main Main\n--js bin/app.js\n');
 await writeFile(join(fixture,'src/Main.hx'),'class Main {static function main(){js.Browser.document.querySelector("#app").textContent="Configured JavaScript preview";}}\n');
 await writeFile(join(fixture,'public/index.html'),'<main id="app"></main><script src="bin/app.js"></script>');
 await writeFile(join(fixture,'.rayde/settings.json'),JSON.stringify({extensions:{disabled:['rayzor','git','markdown','jam']},run:{targets:{js:{mode:'browser',runner:'browser',previewDirectory:'public',arguments:['literal $(false)','space here']}}}}));
}
for(const name of await readdir(join(root,'site')))if(name!=='dist')await symlink(join(root,'site',name),join(web,name));
for(const name of await readdir(join(root,'site/dist')))if(name!=='rayde_session.mjs')await symlink(join(root,'site/dist',name),join(web,'dist',name));
const agent=(await readFile(join(root,'site/dist/rayde_session.mjs'),'utf8'))
 .replace('const request = JSON.parse(text2);','const request = JSON.parse(text2); if (["proc.spawn","proc.write","proc.kill","view.open","page.markdown"].includes(request.op) || request.op.startsWith("preview.")) console.log("builtin-request:"+JSON.stringify(request));')
 .replace('const answer = (message) => {','const answer = (message) => { if (message.pid != null || message.cached != null || message.result?.kind === "document" || message.preview != null || message.directory != null || message.ok === false) console.log("builtin-event:"+JSON.stringify(message));');
await writeFile(join(web,'dist/rayde_session.mjs'),agent);
const git=args=>execFileSync('git',['-C',fixture,...args],{stdio:'ignore'});
git(['init','-b','main']);git(['add','.']);git(['-c','user.name=Demo Developer','-c','user.email=demo@example.invalid','commit','-m','Start Pocket Studio']);
await writeFile(join(fixture,'history.txt'),'A second demo commit.\n');git(['add','.']);git(['-c','user.name=Demo Developer','-c','user.email=demo@example.invalid','commit','-m','Add the demo guide']);
const logs=[],requests=[],events=[],messages=[],lsp=[],streams=new Map(),framed=new Map();
function output(event){
 if(event.ev!=='proc.out'||event.stream!=='stdout')return;
 const bytes=Buffer.from(event.data,'base64');
 let text=(streams.get(event.pid)??'')+bytes.toString();
 while(text.includes('\n')){const at=text.indexOf('\n'),line=text.slice(0,at);text=text.slice(at+1);try{messages.push({pid:event.pid,...JSON.parse(line)});}catch{}}
 streams.set(event.pid,text.slice(-500000));
 let data=Buffer.concat([framed.get(event.pid)??Buffer.alloc(0),bytes]);
 if(data.subarray(0,30).toString().startsWith('Content-Length:'))for(;;){
  const at=data.indexOf('\r\n\r\n');if(at<0)break;
  const length=Number(data.subarray(0,at).toString().match(/content-length:\s*(\d+)/i)?.[1]);if(!length||data.length<at+4+length)break;
  lsp.push(JSON.parse(data.subarray(at+4,at+4+length).toString()));data=data.subarray(at+4+length);
 }
 framed.set(event.pid,data.length<2000000?data:Buffer.alloc(0));
}
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',fixture,'--state-root',join(privateRoot,'state'),'--env-file',join(privateRoot,'environment.json'),'--web',web,'--port','0','--token','builtin-preview-fixture-32-characters','--preview-project','build.hxml','--exec',...(javascript?[]:['--preview-tools',join(root,'bin/preview-tools')]),'--extension-host',join(root,'bin/rayde-extension-host'),'--extensions',join(root,'extensions')],{stdio:['ignore','pipe','pipe'],env:{...process.env,HAXELIB_PATH:join(process.env.HOME,'.rayde-session/demos/pocket-studio/.haxelib'),PATH:join(root,'../ash/target/release')+':'+join(root,'../rayzor/target/release')+':'+process.env.PATH,RAYZOR_STD_PATH:join(root,'../rayzor/compiler/haxe-std')}});
let browser,page;
const report={ok:false};const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(check,label,timeout=60000){const end=Date.now()+timeout;while(!check()){
 const failure=logs.find(line=>/PAGE ERROR|RayDE stopped:|uncaught exception/.test(line));if(failure)throw Error(failure);
 if(Date.now()>end)throw Error('Timed out: '+label);await pause(50);
}}
try{
 const url=await new Promise((resolve,reject)=>{let text='';session.stdout.on('data',bytes=>{text+=bytes;const match=text.match(/http:\/\/[^\s]+/);if(match)resolve(match[0]);});session.on('exit',code=>reject(Error('Session exited '+code)));setTimeout(()=>reject(Error('Session startup timeout')),15000).unref();});
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1440,height:1100}});
 page=await browser.newPage();await page.evaluateOnNewDocument(()=>{
  Object.defineProperty(navigator,'hardwareConcurrency',{value:4});
  Object.defineProperty(navigator,'userAgentData',{value:{platform:'macOS'}});
  if(!localStorage.getItem('fixture-stale')){localStorage.setItem('rayde.workspaceConnection.v1',JSON.stringify({version:1,endpoint:'ws://127.0.0.1:1/session',token:'stale',project:'wrong.hxml',environment:[]}));localStorage.setItem('fixture-stale','1');}
 });
 page.on('console',message=>{const line=message.text();logs.push(line);
  if(line.startsWith('builtin-request:')){const request={...JSON.parse(line.slice(16)),at:Date.now()};requests.push(request);if(request.op.startsWith('preview.'))console.log(request.op,request.stage??'');}
  if(line.startsWith('builtin-event:')){const event={...JSON.parse(line.slice(14)),at:Date.now()};events.push(event);output(event);
   if(event.cached!=null)console.log('preview cache:',event.cached,event.cacheNote??'');
   if(event.ev==='proc.out'){const text=Buffer.from(event.data,'base64').toString();if(/(^|\n)Error:|: (tw:|hxx:)|Uncaught exception/.test(text))logs.push('PAGE ERROR '+text);}
  }
 });
 page.on('pageerror',error=>logs.push('PAGE ERROR '+error.stack));
 await page.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
 await page.goto(url);await page.waitForFunction(()=>document.querySelector('#demo-state').hasAttribute('data-live'),{timeout:120000});
 const frame=await (await page.$('#editor')).contentFrame();
 assert.equal(new URL(page.url()).search,'');assert.equal(new URL(frame.url()).search,'');assert.equal(new URL(frame.url()).hash,'');
 const preset=await page.evaluate(()=>JSON.parse(localStorage.getItem('rayde.workspaceConnection.v1')));
 assert.equal(preset.project,'build.hxml');assert.equal(new URL(preset.endpoint).port,new URL(url).port);report.automaticPreset=report.staleSettingsReplaced=true;
 await frame.evaluate(()=>document.querySelector('#screen').focus());
 async function chord(key){await page.keyboard.down('Meta');await page.keyboard.press(key);await page.keyboard.up('Meta');}
 async function choose(query){await chord('p');await pause(500);await page.keyboard.sendCharacter(query);await pause(500);await page.keyboard.press('Enter');await pause(500);}
 let doneCount=2;
 const tasks=JSON.parse(await readFile(join(fixture,'data/tasks.json'),'utf8'));
 const hostMessages = () => messages.filter(message => message.t === 'error');
 for(const file of appMode?[]:['main.rays','panel.rays','summary.rays']) {
  const before=messages.length;
  await choose(file);
  await until(()=>requests.some(r=>r.op==='view.open'&&r.path.endsWith(file)),file+' source');
  assert.equal(messages.slice(before).some(m=>m.t==='log'&&m.message==='Pocket Tools ready'),false,'preview started before requested');
  const box=await (await page.$('#editor')).boundingBox();
  await page.mouse.click(box.x+box.width-157,box.y+64);
  await until(()=>messages.slice(before).some(m=>m.t==='log'&&m.message==='Pocket Tools ready'),file+' preview entry');
  await until(()=>messages.slice(before).some(m=>m.t==='log'&&m.message===`Pocket Tools: 8 tasks, ${doneCount} done`),file+' saved board');
  assert.ok(messages.slice(before).some(m=>m.t==='started'&&m.name.endsWith('/ext/main.rays')),file+' did not run its extension entry');
  await (await page.$('#editor')).screenshot({path:join(shots,file+'.png')});
  tasks[0].lane=tasks[0].lane==='Done'?'In progress':'Done';
  doneCount=tasks.filter(task=>task.lane==='Done').length;
  await writeFile(join(fixture,'data/tasks.json'),JSON.stringify(tasks));
  const clicked=messages.length, editor=await page.$('#editor');
  await editor.scrollIntoView();const bounds=await editor.boundingBox();
  await page.mouse.click(bounds.x+bounds.width-248,bounds.y+428);
  await until(()=>messages.slice(clicked).some(m=>m.t==='log'&&m.message===`Pocket Tools: 8 tasks, ${doneCount} done`),file+' refresh button');
  const reload=messages.length;await page.keyboard.press('Escape');await choose('>Reload Extension');
  await page.mouse.click(box.x+box.width-157,box.y+64);
  await until(()=>messages.slice(reload).some(m=>m.t==='log'&&m.message===`Pocket Tools: 8 tasks, ${doneCount} done`),file+' reload');
  report[file]=true;
 }
 assert.deepEqual(hostMessages(),[]);
 if(appMode){
  console.log('Building the app preview through the workspace session');
  await page.keyboard.press('Escape');await choose('BoardApp.hx');await choose('>Preview App');
  await until(()=>requests.some(r=>r.op==='preview.prepare'),'preview preparation',30000);
  await (await page.$('#editor')).screenshot({path:join(shots,'app-building.png')});
  await until(()=>requests.some(r=>r.op==='proc.spawn'&&r.args?.includes(javascript?'--js':'wasm32-wasip1-threads')),'app compiler',180000);
  if(!javascript){
   const build=requests.find(r=>r.op==='proc.spawn'&&r.args?.includes('wasm32-wasip1-threads'));
   assert.ok(build.args.includes('-O3'));
   const level=build.args.indexOf('--codegen-opt-level');
   assert.ok(level>=0&&build.args[level+1]==='0'&&level<build.args.length-1,'Ash preview optimization options were not passed before the bytecode input');
   assert.ok(build.args.at(-1).endsWith('/app.hl'));
  }
  await frame.waitForSelector('iframe[data-rayde-app-preview]',{timeout:180000});
  if(!javascript){await until(()=>logs.filter(line=>line==='ashui: ready').length>=2,'app renderer',120000);await until(()=>events.some(event=>event.ev==='preview.title'&&event.title==='Pocket Studio'),'app window title',30000);assert.equal(await frame.$eval('iframe[data-rayde-app-preview]',iframe=>iframe.title),'Pocket Studio');report.windowTitle=true;await pause(300);await page.screenshot({path:join(shots,'editor-window-title.png')});}
  const compileRequests=()=>requests.filter(r=>r.op==='proc.spawn'&&(r.args?.includes('--js')||r.args?.includes('wasm32-wasip1-threads')||r.args?.some(a=>String(a).endsWith('/app.hl'))));
  report.compileTimes=compileRequests().map(request=>{const pid=events.find(event=>event.id===request.id)?.pid;return {command:request.command,milliseconds:events.find(event=>event.ev==='proc.exit'&&event.pid===pid)?.at-request.at};});
  const compiles=compileRequests().length,opened=requests.filter(r=>r.op==='preview.open').length,started=Date.now();
  await frame.evaluate(()=>document.querySelector('#screen').focus());
  await choose('>Preview App');
  await until(()=>requests.filter(r=>r.op==='preview.open').length>opened,'cached preview',30000);
  assert.ok(events.some(event=>event.cached==='wasm'),'unchanged rebuild missed the WASM cache');
  assert.equal(compileRequests().length,compiles,'unchanged preview spawned a compiler');
  report.cachedRebuildMilliseconds=Date.now()-started;
  if(!javascript)await until(()=>logs.filter(line=>line==='ashui: ready').length>=3,'cached app renderer',120000);
  const appElement=await frame.$('iframe[data-rayde-app-preview]'),app=await appElement.contentFrame();
  assert.equal(await app.evaluate(()=>crossOriginIsolated),true);
  assert.equal(await app.evaluate(()=>{try{parent.localStorage;return false;}catch{return true;}}),true);
  if(javascript){
   await app.waitForFunction(()=>document.querySelector('#app')?.textContent==='Configured JavaScript preview');
   assert.deepEqual(await app.evaluate(()=>new URL(location.href).searchParams.getAll('arg')),['literal $(false)','space here']);
   assert.equal(requests.some(r=>r.op==='proc.spawn'&&r.args?.includes('wasm32-wasip1-threads')),false,'JS preview invoked Ash');
   await appElement.screenshot({path:join(shots,'javascript-preview.png')});report.javascript=true;
  }else{
  const previewBox=await appElement.boundingBox();
  await page.mouse.move(previewBox.x+278,previewBox.y-60);await pause(900);
  assert.equal(await appElement.evaluate(frame=>getComputedStyle(frame).visibility),'visible','Close tooltip hid the app preview');
  await page.screenshot({path:join(shots,'editor-preview-tooltip.png')});report.previewTooltip=true;
  await page.mouse.move(previewBox.x+previewBox.width/2,previewBox.y+100);await pause(200);
  const before=JSON.parse(await readFile(join(fixture,'data/tasks.json'),'utf8')).length;
  const box=await appElement.boundingBox();
  await appElement.screenshot({path:join(shots,'app-preview-before.png')});
  const toolbar=106;
  await page.mouse.click(box.x+box.width-80,box.y+toolbar);await pause(300);
  await page.mouse.move(box.x+65,box.y+300);await page.mouse.down();
  await page.mouse.move(box.x+80,box.y+312,{steps:3});await pause(150);
  await page.mouse.move(box.x+box.width-90,box.y+228,{steps:8});await pause(150);
  await appElement.screenshot({path:join(shots,'app-drag.png')});
  await page.mouse.up();await pause(300);
  await page.mouse.move(box.x+250,box.y+300);await page.mouse.down();
  await page.mouse.move(box.x+95,box.y+228,{steps:8});await pause(100);
  await page.keyboard.press('Escape');await page.mouse.up();await pause(200);
  await page.mouse.click(box.x+box.width-200,box.y+toolbar);
  const end=Date.now()+15000;
  while(JSON.parse(await readFile(join(fixture,'data/tasks.json'),'utf8')).length!==before+1&&Date.now()<end)await pause(100);
  assert.equal(JSON.parse(await readFile(join(fixture,'data/tasks.json'),'utf8')).length,before+1,'embedded app did not persist the added task');
  assert.equal(JSON.parse(await readFile(join(fixture,'data/tasks.json'),'utf8')).find(task=>task.id===2).lane,'Done','browser drag did not persist the destination lane');
  assert.equal(JSON.parse(await readFile(join(fixture,'data/tasks.json'),'utf8')).find(task=>task.id===1).lane,'In progress','Escape committed the cancelled browser drag');
  await appElement.screenshot({path:join(shots,'app-preview.png')});
  }
  // Navigating away destroys the app renderer; its compiled artifacts remain reusable.
  await frame.evaluate(()=>document.querySelector('#screen').focus());await choose('BoardApp.hx');
  await frame.waitForFunction(()=>!document.querySelector('iframe[data-rayde-app-preview]'),{timeout:15000});
  report.appPreview=true;
 }
 report.ok=true;console.log(JSON.stringify(report));
}finally{
 await writeFile(join(shots,'result.json'),JSON.stringify(report,null,2));await writeFile(join(shots,'console.log'),logs.join('\n'));
 await writeFile(join(shots,'messages.json'),JSON.stringify(messages));await writeFile(join(shots,'lsp.json'),JSON.stringify(lsp));
 await writeFile(join(shots,'requests.json'),JSON.stringify(requests));
 await page?.screenshot({path:join(shots,'last.png'),fullPage:true}).catch(()=>{});await browser?.close();
 if(session.exitCode===null){const done=once(session,'exit');session.kill('SIGINT');await done;}
 await rm(fixture,{recursive:true,force:true});await rm(privateRoot,{recursive:true,force:true});
}
