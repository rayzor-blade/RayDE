// Browser Extension Studio: first open, preview events, reload, failure recovery and refresh.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {createServer as netServer} from 'node:net';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
const landing=process.argv.includes('--landing');
const root=resolve(import.meta.dirname,'../..'),dir=resolve(root,process.argv[2]??'bin/web/rayde'),shots=join(root,landing?'bin/web/landing-extension-shots':'bin/web/extension-shots');
mkdirSync(shots,{recursive:true});
const require=createRequire(join(root,'web/session/package.json')),puppeteer=require('puppeteer-core');
const workspace=mkdtempSync(join(tmpdir(),'rayde-extensions-')),state=mkdtempSync(join(tmpdir(),'rayde-extension-state-'));
mkdirSync(join(workspace,'src/rayzor/ext'),{recursive:true});mkdirSync(join(workspace,'src/orphan'),{recursive:true});mkdirSync(join(workspace,'.rayde'));
writeFileSync(join(workspace,'build.hxml'),'-cp src\n--interp\n');
writeFileSync(join(workspace,'.rayde/settings.json'),JSON.stringify({extensions:{disabled:['rayzor','git','markdown','jam']}}));
writeFileSync(join(workspace,'src/Main.hx'),'class Main { static function main() {} }\n');
writeFileSync(join(workspace,'src/rayzor/ext/main.rays'),readFileSync(join(root,'extensions/rayzor/ext/main.rays')));
writeFileSync(join(workspace,'src/orphan/main.rays'),readFileSync(join(root,'extensions/rayzor/ext/main.rays')));
writeFileSync(join(workspace,'src/rayzor/rayzor.rayext'),readFileSync(join(root,'extensions/rayzor/rayzor.rayext')));
writeFileSync(join(workspace,'src/rayzor/logo.svg'),readFileSync(join(root,'extensions/rayzor/logo.svg')));
writeFileSync(join(workspace,'src/theme.raytheme'),JSON.stringify({id:'browser-fixture',name:'Browser theme',extends:'restrained',colors:{primary:'#8855dd'}}));
writeFileSync(join(workspace,'src/preview.rays'),`var count = signal(0);
trace("Preview started");
mount(() -> <div class="flex flex-col gap-3 p-4">
  <p>Browser preview ready</p>
  <button class="px-3 py-2 bg-primary rounded-md" onClick={() -> { count.value++; trace("Preview clicked " + count.value); }}>Clicks: {count}</button>
</div>);
`);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const free=()=>new Promise(r=>{const s=netServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});
const webPort=await free(),sessionPort=await free(),logs=[],requests=[],messages=[],streams=new Map();
const report={ok:false};let browser,page;
function output(event){
 if(event.ev!=='proc.out'||event.stream!=='stdout')return;
 let text=(streams.get(event.pid)??'')+Buffer.from(event.data,'base64').toString();
 while(text.includes('\n')){const at=text.indexOf('\n'),line=text.slice(0,at);text=text.slice(at+1);try{messages.push({pid:event.pid,...JSON.parse(line)});}catch{}}
 streams.set(event.pid,text);
}
const server=createServer((request,response)=>{
 try{
  const name=new URL(request.url,'http://local').pathname;
  if(landing&&name==='/.well-known/rayde-preview'){response.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});response.end(JSON.stringify({version:1,endpoint:`ws://127.0.0.1:${sessionPort}/session`,token:'extension-test',project:'build.hxml',environment:[]}));return;}
  const base=landing&&!name.startsWith('/dist/')?join(root,'site'):dir;
  const asset=landing&&name.startsWith('/dist/')?name.slice(5):name;
  const path=resolve(base,'.'+(asset==='/'?'/index.html':asset));
  if(!path.startsWith(base+'/'))throw Error('outside bundle');
  let body=readFileSync(path);
  if(name.endsWith('/ashui-host.mjs'))body=Buffer.from(body.toString().replace('Math.max(1, (navigator.hardwareConcurrency || 4) - 1)','3'));
  if(name.endsWith('/rayde_session.mjs'))body=Buffer.from(body.toString()
   .replace('let reply;',`let reply; if (request.op.startsWith("view.") || request.op === "proc.spawn" || request.op === "proc.kill" || request.op === "view.save") console.log("extension-request:"+JSON.stringify(request));`)
   .replace('const answer = (message) => {',`const answer = (message) => { if (message.ev?.startsWith("proc.") || message.ok === false || message.result?.text !== undefined) console.log("extension-event:"+JSON.stringify(message)); `));
  response.writeHead(200,{'Content-Type':path.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(path)?'text/javascript':path.endsWith('.css')?'text/css':path.endsWith('.svg')?'image/svg+xml':path.endsWith('.webp')?'image/webp':path.endsWith('.woff2')?'font/woff2':'text/html','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});response.end(body);
 }catch{response.writeHead(404).end();}
}).listen(webPort,'127.0.0.1');
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',workspace,'--state-root',state,'--port',String(sessionPort),'--token','extension-test','--origin',`http://127.0.0.1:${webPort}`,'--exec','--extension-host',join(root,'bin/rayde-extension-host'),'--extensions',join(root,'extensions')],{stdio:'ignore',env:{...process.env,SHELL:'/bin/sh'}});
function healthy(){assert(!logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)),logs.slice(-20).join('\n'));}
async function until(test,label,seconds=15){const end=Date.now()+seconds*1000;while(!test()){healthy();if(Date.now()>end)throw Error('Timed out: '+label);await pause(50);}healthy();}
function hosts(){return requests.filter(r=>r.op==='proc.spawn'&&r.command.endsWith('rayde-extension-host'));}
async function click(x,y){
 if(landing){const element=await page.$('#editor');await element.scrollIntoView();const bounds=await element.boundingBox();x+=bounds.x;y+=bounds.y;}
 await page.mouse.click(x,y);
}
async function screenshot(name){await pause(250);healthy();const target=landing?await page.$('#editor'):page;await target.screenshot({path:join(shots,name+'.png')});}
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:landing?1440:1280,height:landing?1100:800}});
 page=await browser.newPage();
 await page.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'userAgentData',{value:{platform:'macOS'}}));
 page.on('console',m=>{const text=m.text();logs.push(text);if(text.startsWith('extension-request:'))requests.push(JSON.parse(text.slice(18)));if(text.startsWith('extension-event:'))output(JSON.parse(text.slice(16)));writeFileSync(join(shots,'console.log'),logs.join('\n'));});
 page.on('pageerror',e=>logs.push('PAGE ERROR '+e.stack));
 if(landing){
  await page.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
  await page.evaluateOnNewDocument(()=>addEventListener('DOMContentLoaded',()=>{
   const style=document.createElement('style');style.textContent='.wrap{width:1282px;max-width:none}.editor-frame{height:802px;aspect-ratio:auto}';document.head.append(style);
  }));
 }
 await page.goto(`http://127.0.0.1:${webPort}/?session=${encodeURIComponent(`ws://127.0.0.1:${sessionPort}/session`)}&project=build.hxml#token=extension-test`,{waitUntil:'domcontentloaded'});
 await until(()=>logs.includes('ashui: ready'),'ready',45);await pause(1500);
 if(landing){
  assert.equal(new URL(page.url()).search,'');assert.equal(new URL(page.url()).hash,'');
  const frame=await (await page.$('#editor')).contentFrame();
  assert.equal(new URL(frame.url()).search,'');assert.equal(new URL(frame.url()).hash,'');
  await frame.evaluate(()=>document.querySelector('#screen').focus());
  report.embedded=report.cleanURL=report.persistedConnection=true;
  await click(34,67);
 }
 async function chord(key){await page.keyboard.down('Meta');await page.keyboard.press(key);await page.keyboard.up('Meta');}
 async function choose(query){
  await chord('p');await pause(600);
  await page.keyboard.sendCharacter(query);await pause(600);await page.keyboard.press('Enter');await pause(700);
 }
 async function open(name){const before=requests.length;await choose(name);await until(()=>requests.slice(before).some(r=>r.op==='view.open'&&r.path.endsWith(name)),name+' document opened');}
 async function reload(menu){
  const before=hosts().length,start=messages.length;
  if(menu){await click(1248,129);await pause(350);await page.keyboard.press('ArrowDown');await pause(100);await page.keyboard.press('Enter');}
  else await choose('>Reload Extension');
  await until(()=>hosts().length===before+1,'reload started a fresh host');
  await until(()=>messages.slice(start).some(m=>m.t==='started'),'reloaded script started');await pause(400);
 }
 await chord('j');await pause(400);await click(600,605);await pause(200);
 await open('orphan/main.rays');
 await until(()=>messages.some(m=>m.t==='error'&&m.kind==='runtime'),'source-only Rayzor failure');
 await screenshot('runtime-error');report.runtimeErrorContained=true;
 await reload(true);await screenshot('runtime-error-menu-reload');report.errorReload=true;
 const contextStart=messages.length;
 await open('rayzor/ext/main.rays');
 await until(()=>messages.slice(contextStart).some(m=>m.t==='call'&&m.fn==='rayde.languages.registerServer'),'Rayzor settings and capability from its root manifest');
 await pause(700);healthy();assert(!messages.slice(contextStart).some(m=>m.t==='error'),JSON.stringify(messages.slice(contextStart)));
 await screenshot('manifest-context');report.manifestDiscovered=true;
 await open('theme.raytheme');await screenshot('theme-form');report.themeOpened=true;
 await until(()=>requests.some(r=>r.op==='view.open'&&r.path.endsWith('theme.raytheme')),'theme shared document');
 const themeHandle=requests.findLast(r=>r.op==='view.open'&&r.path.endsWith('theme.raytheme')).handle;
 await until(()=>requests.some(r=>r.op==='view.ready'&&r.handle===themeHandle),'theme document synchronized');
 await pause(400);await click(980,343);await chord('a');await page.keyboard.sendCharacter('Edited browser theme');await pause(300);await page.keyboard.press('Enter');
 await until(()=>JSON.parse(readFileSync(join(workspace,'src/theme.raytheme'),'utf8')).name==='Edited browser theme','theme form saved through session');
 assert(requests.some(r=>r.op==='view.save'),'theme form bypassed shared document save');report.themeSaved=true;
 await pause(300);await click(1000,138);await screenshot('theme-json');
 await click(1190,103);await screenshot('theme-return');
 await chord('w');await pause(500);
 const opens=requests.filter(r=>r.op==='view.open'&&r.path.endsWith('theme.raytheme')).length;
 await click(174,290);
 await until(()=>requests.filter(r=>r.op==='view.open'&&r.path.endsWith('theme.raytheme')).length>opens,'theme reopened from Explorer');
 await screenshot('theme-explorer');report.themeExplorer=true;
 await open('preview.rays');
 await until(()=>messages.some(m=>m.t==='ops'&&m.ops.some(op=>op[0]==='createText'&&op[2]==='Browser preview ready')),'preview node model');
 await screenshot('preview');report.previewMounted=true;
 async function clickPreview(){
  const before=messages.length;await click(1000,228);
  await until(()=>messages.slice(before).some(m=>m.t==='log'&&m.message==='Preview clicked 1'),'preview click round trip');
  await until(()=>messages.slice(before).some(m=>m.t==='ops'&&m.ops.some(op=>op[0]==='setText'&&op[2]==='1')),'reactive preview update');
 }
 await clickPreview();await screenshot('preview-clicked');report.previewInteractive=true;
 await reload(true);await clickPreview();await screenshot('preview-menu-reload');report.menuReload=true;
 await reload(false);await clickPreview();await screenshot('preview-command-reload');report.commandReload=true;
 const ready=logs.filter(s=>s==='ashui: ready').length,started=messages.length;
 await page.reload({waitUntil:'domcontentloaded'});await until(()=>logs.filter(s=>s==='ashui: ready').length>ready,'browser refresh',45);await pause(1200);
 await until(()=>messages.slice(started).some(m=>m.t==='log'&&m.message==='Preview started'),'restored preview after refresh');
 await clickPreview();await screenshot('refreshed');report.refresh=true;
 assert(requests.some(r=>r.op==='proc.kill'),'reload did not release the previous process');
 report.ok=true;console.log(JSON.stringify(report));
}finally{
 writeFileSync(join(shots,'result.json'),JSON.stringify(report,null,2));writeFileSync(join(shots,'messages.json'),JSON.stringify(messages,null,2));
 if(page)await page.screenshot({path:join(shots,'last.png')}).catch(()=>{});
 await browser?.close();session.kill('SIGINT');server.close();
}
