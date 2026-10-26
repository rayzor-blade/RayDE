// Browser editor scrolling with short, large, syntax-heavy and long-line source.
// node tests/web/scroll.mjs [bundle directory] [result directory]
// Uses an isolated workspace with LSP/extensions disabled to measure the editor itself.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {createServer as netServer} from 'node:net';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),dir=resolve(root,process.argv[2]??'bin/web/rayde'),out=resolve(root,process.argv[3]??'bin/web/scroll-shots');mkdirSync(out,{recursive:true});
const require=createRequire(join(root,'web/session/package.json')),puppeteer=require('puppeteer-core');
const work=mkdtempSync(join(tmpdir(),'rayde-scroll-'));mkdirSync(join(work,'src'));mkdirSync(join(work,'.rayde'));
writeFileSync(join(work,'build.hxml'),'-cp src\n--interp\n');writeFileSync(join(work,'.rayde/settings.json'),JSON.stringify({extensions:{disabled:['rayzor','git','markdown','jam']}}));
const source=(name,n,line)=>'class '+name+' {\n'+Array.from({length:n},(_,i)=>line(i)).join('\n')+'\n}\n';
for(const [name,text] of [
 ['Small.hx',source('Small',200,i=>'\tvar field'+i+':Int = '+i+';')],
 ['Big.hx',source('Big',12000,i=>'\tvar field'+i+':Int = '+i+';')],
 ['Real.hx',readFileSync(join(root,'src/rayde/ui/workbench/EditorPart.hx'),'utf8')],
 ['Wide.hx',source('Wide',1000,i=>'\t// '+i+' '+('long comment text '.repeat(150)))],
 ['Plain.txt',Array.from({length:1000},(_,i)=>i+' '+('unhighlighted source '.repeat(130))).join('\n')]
])writeFileSync(join(work,'src',name),text);
const pause=ms=>new Promise(r=>setTimeout(r,ms)),free=()=>new Promise(r=>{const s=netServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});
const port=await free(),sessionPort=await free(),logs=[];
const server=createServer((req,res)=>{try{const name=new URL(req.url,'http://local').pathname,path=resolve(dir,'.'+(name==='/'?'/index.html':name));if(!path.startsWith(dir+'/'))throw 0;
 let body=name==='/gpu-probe.mjs'?readFileSync(join(root,'tests/web/gpu-probe.mjs')):name==='/queue-probe.mjs'?readFileSync(join(root,'tests/web/queue-probe.mjs')):readFileSync(path);
 if(name==='/ashui-host.mjs')body=Buffer.from(body.toString().replace('Math.max(1, (navigator.hardwareConcurrency || 4) - 1)','3'));
 if(name==='/xwindow.mjs')body=Buffer.from('import {watchQueue} from "./queue-probe.mjs";\n'+body.toString().replace('const queue = new Queue(memory, address + QUEUE);','const queue = new Queue(memory, address + QUEUE); const traceQueue = watchQueue(memory,address+QUEUE);').replace('const posted = post_XwEvent(queue, event);','const posted = post_XwEvent(queue, event); traceQueue(event,posted);'));
 if(name==='/gpu-worker.mjs')body=Buffer.from('import "./gpu-probe.mjs";\n'+body);
 if(name==='/gpu-probe.mjs')body=Buffer.from(body.toString().replace('const stats = {','const stats = { submitTimes:[],').replace('stats.submissions++;','stats.submissions++; stats.submitTimes.push(performance.timeOrigin+performance.now()); if(stats.submitTimes.length>1000)stats.submitTimes.shift();').replace('setInterval(report, 1000)','setInterval(report, 100)'));
 if(name==='/gpu-agent.mjs')body=Buffer.from(body.toString().replace('execute(wire, words[2] >>> 0, words[3] >>> 0);','globalThis.raydeBatch(wire,words[2]>>>0,words[3]>>>0);execute(wire,words[2]>>>0,words[3]>>>0);'));
 res.writeHead(200,{'Content-Type':name.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(name)?'text/javascript':'text/html','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});res.end(body);
}catch{res.writeHead(404).end();}}).listen(port,'127.0.0.1');
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',work,'--state-root',join(work,'.state'),'--port',String(sessionPort),'--token','scroll-test','--origin',`http://127.0.0.1:${port}`],{stdio:'ignore'});
let browser;const report={ok:false,cases:[]};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1280,height:800}});
 const page=await browser.newPage();await page.evaluateOnNewDocument(()=>{const Original=Worker;globalThis.__scrollProbe={};globalThis.Worker=class extends Original{constructor(...args){super(...args);this.addEventListener('message',({data})=>{if(data.kind==='rayde-gpu-probe')globalThis.__scrollProbe.gpu=data.stats;});}};});
 page.on('console',m=>{logs.push({at:Date.now(),text:m.text()});writeFileSync(join(out,'console.json'),JSON.stringify(logs,null,2));});page.on('pageerror',e=>logs.push({at:Date.now(),text:'PAGE ERROR '+e.stack}));
 async function until(f,label,seconds=45){const end=Date.now()+seconds*1000;while(!f()){if(Date.now()>end)throw Error('Timeout '+label);assert(!logs.some(l=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(l.text)));await pause(100);}}
 await page.goto(`http://127.0.0.1:${port}/?session=${encodeURIComponent(`ws://127.0.0.1:${sessionPort}/session`)}&project=build.hxml&env=ASHUI_FRAME_STATS=1#token=scroll-test`,{waitUntil:'domcontentloaded'});await until(()=>logs.some(l=>l.text==='ashui: ready'),'ready');await pause(500);await page.screenshot({path:join(out,'welcome.png')});
 async function chord(k){await page.keyboard.down('Meta');await page.keyboard.press(k);await page.keyboard.up('Meta');}
 const quantile=(a,p)=>a.length?[...a].sort((a,b)=>a-b)[Math.min(a.length-1,Math.floor(a.length*p))]:0;
 for(const name of ['Small.hx','Big.hx','Real.hx','Wide.hx','Plain.txt']){
  await chord('p');await pause(200);await page.keyboard.type(name);await pause(200);await page.keyboard.press('Enter');await pause(2500);await page.mouse.move(750,400);await pause(100);
  await page.screenshot({path:join(out,name+'.png')});
  const before=await page.evaluate(()=>({gpu:__scrollProbe.gpu,queue:raydeQueueProbe})),start=Date.now();
  for(let i=0;i<100;i++){await page.mouse.wheel({deltaY:(i<60?1:-1)*24});await pause(10);}await pause(600);
  const end=Date.now(),after=await page.evaluate(()=>({gpu:__scrollProbe.gpu,queue:raydeQueueProbe}));
  const t=after.gpu.submitTimes.filter(t=>t>=start&&t<=end),gaps=t.slice(1).map((v,i)=>v-t[i]).filter(t=>t>0.5),input=after.queue.inputLatencyMs.slice(before.queue.inputLatencyMs.length);
  report.cases.push({name,elapsed:end-start,frames:after.gpu.submissions-before.gpu.submissions,frameGapP50:quantile(gaps,.5),frameGapP95:quantile(gaps,.95),frameGapMax:Math.max(...gaps),inputP95:quantile(input,.95),inputMax:Math.max(...input),queueDropped:after.queue.dropped,stats:logs.filter(l=>l.at>=start&&l.at<=end&&/^\[(frames|loop)\]/.test(l.text)).map(l=>l.text)});console.log(JSON.stringify(report.cases.at(-1)));writeFileSync(join(out,'result.json'),JSON.stringify(report,null,2));
 }
 const ordinary=report.cases[0].frameGapP50;
 for(const sample of report.cases){assert(sample.frames>0,'No scroll frames: '+sample.name);assert.equal(sample.queueDropped,0,'Input dropped: '+sample.name);}
 for(const name of ['Wide.hx','Plain.txt']) assert(report.cases.find(c=>c.name===name).frameGapP50<ordinary*3,'Long-line rendering escaped horizontal culling: '+name);
 report.ok=true;
}finally{writeFileSync(join(out,'result.json'),JSON.stringify(report,null,2));if(browser)await browser.close();session.kill();server.close();}
