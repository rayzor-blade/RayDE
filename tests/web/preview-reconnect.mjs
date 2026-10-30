// A full editor preview survives transport loss and recovers through its existing build cache.
// node tests/web/preview-reconnect.mjs bin/web/rayde
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {createServer as tcpServer} from 'node:net';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),bundle=resolve(process.argv[2]??'bin/web/rayde');
const puppeteer=createRequire(join(root,'web/session/package.json'))('puppeteer-core');
const directory=mkdtempSync(join(tmpdir(),'rayde-preview-reconnect-')),workspace=join(directory,'project');
mkdirSync(join(workspace,'src'),{recursive:true});
writeFileSync(join(workspace,'src/Main.hx'),'class Main { static function main() { js.Browser.document.title="Reconnect app"; js.Browser.document.getElementById("app").textContent="Preview is running"; } }');
writeFileSync(join(workspace,'build.hxml'),'-cp src\n-main Main\n-js bin/app.js\n');
writeFileSync(join(workspace,'.gitignore'),'.rayde/\nbin/\n');
execFileSync('git',['init','-q','-b','main'],{cwd:workspace});execFileSync('git',['add','.'],{cwd:workspace});
const shots=join(root,'bin/web/preview-reconnect');mkdirSync(shots,{recursive:true});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const port=()=>new Promise(resolve=>{const server=tcpServer().listen(0,'127.0.0.1',()=>{const n=server.address().port;server.close(()=>resolve(n));});});
async function until(check,label,timeout=60000){const end=Date.now()+timeout;while(!await check()){if(Date.now()>end)throw Error('Timed out: '+label);await sleep(50);}}
const webPort=await port(),sessionPort=await port(),unavailable=await port(),origin=`http://127.0.0.1:${webPort}`,endpoint=`ws://127.0.0.1:${sessionPort}/session`,lines=[];
const server=createServer((request,response)=>{try{
 const name=new URL(request.url,origin).pathname,path=resolve(bundle,'.'+(name==='/'?'/index.html':name));if(!path.startsWith(bundle+'/'))throw Error('outside');
 let bytes=readFileSync(path);if(name==='/ashui-host.mjs')bytes=Buffer.from(bytes.toString().replace('Math.max(1, (navigator.hardwareConcurrency || 4) - 1)','3'));
 if(name==='/rayde_session.mjs')bytes=Buffer.from(bytes.toString().replace('const answer = (message) => {','const answer = (message) => { if(message.ev==="session.disconnected"||message.ev==="session.connected")console.log("session:"+JSON.stringify(message));'));
 response.writeHead(200,{'Content-Type':path.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(path)?'text/javascript':path.endsWith('.css')?'text/css':'text/html','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});response.end(bytes);
}catch{response.writeHead(404).end();}}).listen(webPort,'127.0.0.1');
let session,browser;
const start=state=>{session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',workspace,'--state-root',state,'--port',String(sessionPort),'--token','preview-test','--origin',origin,'--exec'],{stdio:'ignore'});};
const stop=async()=>{if(session&&session.exitCode===null&&session.signalCode===null)await new Promise(resolve=>{session.once('exit',resolve);session.kill('SIGTERM');});};
try{
 start(join(directory,'private'));
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1280,height:800}});
 const page=await browser.newPage();
 await page.evaluateOnNewDocument(({endpoint,unavailable})=>{
  Object.defineProperty(navigator,'userAgentData',{value:{platform:'Linux'}});
  const NativeSocket=WebSocket;globalThis.socketLog={requests:[],preparations:[],sockets:[],offline:false};
  globalThis.WebSocket=class extends NativeSocket{
   constructor(url,...args){
    const ours=String(url)===endpoint;super(ours&&socketLog.offline?`ws://127.0.0.1:${unavailable}/session`:url,...args);
    if(!ours)return;socketLog.sockets.push(this);const pending=new Map();
    this.addEventListener('message',event=>{const reply=JSON.parse(event.data);if(pending.get(reply.id)==='preview.prepare')socketLog.preparations.push(reply);pending.delete(reply.id);});
    const send=this.send.bind(this);this.send=text=>{const request=JSON.parse(text);socketLog.requests.push(request);pending.set(request.id,request.op);return send(text);};
   }
  };
 },{endpoint,unavailable});
 page.on('console',message=>lines.push(message.text()));page.on('pageerror',error=>lines.push('PAGE ERROR '+error.stack));
 await page.goto(`${origin}/?session=${encodeURIComponent(endpoint)}&project=build.hxml#token=preview-test`);
 await until(()=>lines.includes('ashui: ready'),'editor ready');await sleep(600);
 await page.evaluate(()=>document.querySelector('#screen').focus());await page.keyboard.down('Control');await page.keyboard.press('p');await page.keyboard.up('Control');await sleep(400);await page.keyboard.sendCharacter('>Preview App');await sleep(300);await page.keyboard.press('Enter');
 const frame=async()=>{const handle=await page.$('iframe[data-rayde-app-preview]');return handle?handle.contentFrame():null;};
 async function ready(){await until(async()=>{try{const app=await frame();return app&&await app.evaluate(()=>document.getElementById('app')?.textContent==='Preview is running');}catch{return false;}},'running app');}
 await ready();
 const compilers=await page.evaluate(()=>socketLog.requests.filter(row=>row.op==='proc.spawn'&&/(^|\/)haxe$/.test(row.command)&&row.args.some(arg=>arg==='-js'||arg==='--js')).length);assert.equal(compilers,1);
 for(let i=0;i<10;i++){
  const before=await page.evaluate(()=>socketLog.preparations.length);
  await page.evaluate(()=>{const iframe=document.querySelector('iframe[data-rayde-app-preview]');globalThis.previousPreviewWindow=iframe.contentWindow;globalThis.previousPreviewUrl=iframe.src;socketLog.offline=true;for(const socket of socketLog.sockets)if(socket.readyState===WebSocket.OPEN)socket.close();});
  await until(()=>lines.some(line=>line.startsWith('session:')&&JSON.parse(line.slice(8)).ev==='session.disconnected'),'disconnect feedback');
  await sleep(300);
  assert.equal(await page.evaluate(()=>document.querySelector('iframe[data-rayde-app-preview]')?.contentWindow===previousPreviewWindow),true,'disconnect removed the loaded preview runtime');
  if(i===0)await page.screenshot({path:join(shots,'disconnected.png')});
  await page.evaluate(()=>{socketLog.offline=false;});
  await until(()=>page.evaluate(before=>socketLog.preparations.length>before,before),'automatic preview recovery');
  await until(()=>page.evaluate(()=>{const iframe=document.querySelector('iframe[data-rayde-app-preview]');return iframe&&iframe.src!==previousPreviewUrl;}),'replacement connection capability');await ready();
  assert.equal(await page.evaluate(()=>socketLog.preparations.at(-1).cached),'wasm','reconnect did not reuse its validated app bundle');
  assert.equal(await page.$$eval('iframe[data-rayde-app-preview]',frames=>frames.length),1);
 }
 assert.equal(await page.evaluate(()=>socketLog.requests.filter(row=>row.op==='proc.spawn'&&/(^|\/)haxe$/.test(row.command)&&row.args.some(arg=>arg==='-js'||arg==='--js')).length),compilers,'a cached reconnect ran the compiler');
 await page.screenshot({path:join(shots,'recovered.png')});
 const before=await page.evaluate(()=>socketLog.preparations.length);
 await stop();start(join(directory,'replacement-state'));
 await until(()=>lines.some(line=>line.startsWith('session:')&&JSON.parse(line.slice(8)).code==='workspace-changed'),'replacement workspace fencing');
 await until(()=>page.$$eval('iframe[data-rayde-app-preview]',frames=>frames.length===0),'old preview removed on context change');
 await sleep(400);assert.equal(await page.evaluate(()=>socketLog.preparations.length),before,'replacement workspace restarted an old preview');
 assert.equal(lines.some(line=>/PAGE ERROR|uncaught exception|RayDE stopped:/.test(line)),false);
 console.log('WASM app previews: loaded runtime retained while disconnected, ten cached recoveries without compilers, bounded frames and replacement-workspace fencing passed');
}finally{writeFileSync(join(shots,'console.log'),lines.join('\n'));await browser?.close();await stop();await new Promise(resolve=>server.close(resolve));rmSync(directory,{recursive:true,force:true});}
