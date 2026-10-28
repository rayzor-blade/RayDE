// Real built-in extensions in the preset landing workspace, without setup URLs.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp,mkdir,cp,symlink,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {createRequire} from 'node:module';
import {resolve,join,dirname} from 'node:path';
const root=resolve(import.meta.dirname,'../..');
const puppeteer=createRequire(join(root,'web/session/package.json'))('puppeteer-core');
const shots=join(root,'bin/web/builtin-shots');await mkdir(shots,{recursive:true});
const fixture=await mkdtemp(join(root,'bin/published-demo/landing-'));
const privateRoot=await mkdtemp(join(tmpdir(),'rayde-builtins-'));
const web=join(privateRoot,'web');await mkdir(join(web,'dist'),{recursive:true});
await cp(join(root,'site/demo'),fixture,{recursive:true});
await cp(join(fixture,'README.md'),join(fixture,'src/Guide.md'));
for(const name of await readdir(join(root,'site')))if(name!=='dist')await symlink(join(root,'site',name),join(web,name));
for(const name of await readdir(join(root,'site/dist')))if(name!=='rayde_session.mjs')await symlink(join(root,'site/dist',name),join(web,'dist',name));
const agent=(await readFile(join(root,'site/dist/rayde_session.mjs'),'utf8'))
 .replace('const request = JSON.parse(text2);','const request = JSON.parse(text2); if (["proc.spawn","proc.write","proc.kill","view.open","page.markdown"].includes(request.op)) console.log("builtin-request:"+JSON.stringify(request));')
 .replace('const answer = (message) => {','const answer = (message) => { if (message.ev === "proc.out" || message.result?.kind === "document") console.log("builtin-event:"+JSON.stringify(message));');
await writeFile(join(web,'dist/rayde_session.mjs'),agent);
const git=args=>execFileSync('git',['-C',fixture,...args],{stdio:'ignore'});
git(['init','-b','main']);git(['add','.']);git(['-c','user.name=Demo Developer','-c','user.email=demo@example.invalid','commit','-m','Start Pocket Studio']);
await writeFile(join(fixture,'history.txt'),'A second demo commit.\n');git(['add','.']);git(['-c','user.name=Demo Developer','-c','user.email=demo@example.invalid','commit','-m','Add the demo guide']);
const logs=[],requests=[],events=[],messages=[],lsp=[],streams=new Map(),framed=new Map();
function output(event){
 if(event.ev!=='proc.out'||event.stream!=='stdout')return;
 const bytes=Buffer.from(event.data,'base64');
 let text=(streams.get(event.pid)??'')+bytes.toString();
 while(text.includes('\n')){const at=text.indexOf('\n'),line=text.slice(0,at);text=text.slice(at+1);try{messages.push(JSON.parse(line));}catch{}}
 streams.set(event.pid,text.slice(-500000));
 let data=Buffer.concat([framed.get(event.pid)??Buffer.alloc(0),bytes]);
 if(data.subarray(0,30).toString().startsWith('Content-Length:'))for(;;){
  const at=data.indexOf('\r\n\r\n');if(at<0)break;
  const length=Number(data.subarray(0,at).toString().match(/content-length:\s*(\d+)/i)?.[1]);if(!length||data.length<at+4+length)break;
  lsp.push(JSON.parse(data.subarray(at+4,at+4+length).toString()));data=data.subarray(at+4+length);
 }
 framed.set(event.pid,data.length<2000000?data:Buffer.alloc(0));
}
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',fixture,'--state-root',join(privateRoot,'state'),'--web',web,'--port','0','--token','builtin-preview-fixture-32-characters','--preview-project','build.hxml','--exec','--extension-host',join(root,'bin/rayde-extension-host'),'--extensions',join(root,'extensions')],{stdio:['ignore','pipe','pipe'],env:{...process.env,PATH:join(root,'../rayzor/target/release')+':'+process.env.PATH,RAYZOR_STD_PATH:join(root,'../rayzor/compiler/haxe-std')}});
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
  if(line.startsWith('builtin-request:'))requests.push(JSON.parse(line.slice(16)));
  if(line.startsWith('builtin-event:')){const event=JSON.parse(line.slice(14));events.push(event);output(event);}
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
 await until(()=>requests.some(r=>r.command==='rayzor'),'Rayzor starts for the demo code tabs');
 await until(()=>lsp.some(m=>m.result?.capabilities?.hoverProvider),'actual Rayzor initialize');report.rayzor=true;
 await until(()=>lsp.some(m=>m.method==='textDocument/publishDiagnostics'),'actual Rayzor diagnostics',120000);report.diagnostics=true;
 await (await page.$('#editor')).screenshot({path:join(shots,'split-code.png')});
 await choose('>Git: History');
 await until(()=>messages.some(m=>m.t==='ops'&&JSON.stringify(m.ops).includes('tab:Git history')),'Git graph tab');
 await until(()=>messages.some(m=>m.t==='ops'&&JSON.stringify(m.ops).includes('Add the demo guide')),'real Git commits');report.git=true;
 await (await page.$('#editor')).screenshot({path:join(shots,'git.png')});
 await choose('Guide.md');await until(()=>requests.some(r=>r.op==='view.open'&&r.path.endsWith('Guide.md')),'Markdown source');
 await choose('>Markdown: Open Preview');
 await until(()=>messages.some(m=>m.t==='ops'&&JSON.stringify(m.ops).includes('markdown-document')),'Markdown preview mounted');
 await until(()=>messages.some(m=>m.t==='ops'&&m.ops.some(op=>['set','setField'].includes(op[0])&&op[2]==='document'&&(typeof op[3]==='string'?JSON.parse(op[3]):op[3])?.kind==='document')),'rendered Markdown document');report.markdown=true;
 await (await page.$('#editor')).screenshot({path:join(shots,'markdown.png')});
 assert.equal(messages.some(m=>m.t==='error'),false,JSON.stringify(messages.filter(m=>m.t==='error')));
 report.ok=true;console.log(JSON.stringify(report));
}finally{
 await writeFile(join(shots,'result.json'),JSON.stringify(report,null,2));await writeFile(join(shots,'console.log'),logs.join('\n'));
 await writeFile(join(shots,'messages.json'),JSON.stringify(messages));await writeFile(join(shots,'lsp.json'),JSON.stringify(lsp));
 await page?.screenshot({path:join(shots,'last.png'),fullPage:true}).catch(()=>{});await browser?.close();
 if(session.exitCode===null){const done=once(session,'exit');session.kill('SIGINT');await done;}
 await rm(fixture,{recursive:true,force:true});await rm(privateRoot,{recursive:true,force:true});
}
