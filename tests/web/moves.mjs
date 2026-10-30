// Full WASM Explorer rename against a native session, keeping its editor and undo binding alive.
// node tests/web/moves.mjs bin/web/rayde
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {createServer as tcpServer} from 'node:net';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';

const root=resolve(import.meta.dirname,'../..'),bundle=resolve(process.argv[2]??'bin/web/rayde');
const puppeteer=createRequire(join(root,'web/session/package.json'))('puppeteer-core');
const directory=mkdtempSync(join(tmpdir(),'rayde-moves-')),workspace=join(directory,'project'),state=join(directory,'private');
mkdirSync(join(workspace,'src'),{recursive:true});
const source='class Main {\n  static function main() { trace("move"); }\n}\n';
writeFileSync(join(workspace,'src/Main.hx'),source);writeFileSync(join(workspace,'src/Other.hx'),'class Other {}\n');
writeFileSync(join(workspace,'build.hxml'),'-cp src\n-main Main\n--interp\n');
const shots=join(root,'bin/web/live-moves');mkdirSync(shots,{recursive:true});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const freePort=()=>new Promise(resolve=>{const server=tcpServer().listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>resolve(port));});});
async function until(check,label){const end=Date.now()+60000;while(!await check()){if(Date.now()>end)throw Error('Timed out: '+label);await sleep(50);}}
const webPort=await freePort(),sessionPort=await freePort(),origin=`http://127.0.0.1:${webPort}`,lines=[];
const web=createServer((request,response)=>{try{
 const name=new URL(request.url,origin).pathname,path=resolve(bundle,'.'+(name==='/'?'/index.html':name));
 if(!path.startsWith(bundle+'/'))throw Error('outside');let bytes=readFileSync(path);
 if(name==='/ashui-host.mjs')bytes=Buffer.from(bytes.toString().replace('Math.max(1, (navigator.hardwareConcurrency || 4) - 1)','3'));
 if(name==='/rayde_session.mjs')bytes=Buffer.from(bytes.toString()
  .replace('const answer = (message) => {','const answer = (message) => { if(message.ok===false || message.ev?.startsWith("view.") || message.ev==="workspace.moved" || message.result!==undefined) console.log("projection:"+JSON.stringify(message));')
  .replace('const request = JSON.parse(text2);','const request = JSON.parse(text2); if(request.op?.startsWith("view.") || request.op==="fs.rename")console.log("editor-request:"+JSON.stringify(request));'));
 response.writeHead(200,{'Content-Type':path.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(path)?'text/javascript':path.endsWith('.css')?'text/css':'text/html','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});response.end(bytes);
}catch{response.writeHead(404).end();}}).listen(webPort,'127.0.0.1');
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',workspace,'--state-root',state,'--port',String(sessionPort),'--token','move-test','--origin',origin],{stdio:'ignore'});
let browser;
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1280,height:800}});
 const page=await browser.newPage();await page.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'userAgentData',{value:{platform:'Linux'}}));
 page.on('console',message=>lines.push(message.text()));page.on('pageerror',error=>lines.push('PAGE ERROR '+error.stack));
 const requests=()=>lines.filter(line=>line.startsWith('editor-request:')).map(line=>JSON.parse(line.slice(15)));
 const projections=()=>lines.filter(line=>line.startsWith('projection:')).map(line=>JSON.parse(line.slice(11)));
 async function palette(text){await page.evaluate(()=>document.querySelector('#screen').focus());await page.keyboard.down('Control');await page.keyboard.press('p');await page.keyboard.up('Control');await sleep(400);await page.keyboard.sendCharacter(text);await sleep(300);await page.keyboard.press('Enter');}
 const endpoint=`ws://127.0.0.1:${sessionPort}/session`;
 await page.goto(`${origin}/?session=${encodeURIComponent(endpoint)}&project=build.hxml#token=move-test`);
 await until(()=>lines.includes('ashui: ready'),'editor ready');await sleep(700);
 await palette('Main.hx');await until(()=>requests().some(row=>row.op==='view.ready'),'initial document');
 const opened=requests().find(row=>row.op==='view.open'&&row.path==='src/Main.hx');assert(opened);
 // Split editors stay mounted while the active tab is renamed.
 await palette('Other.hx');await until(()=>requests().filter(row=>row.op==='view.ready').length===2,'second document');
 await palette('>Split Editor Right');await sleep(350);await palette('Main.hx');await sleep(300);
 await page.mouse.click(350,300);await page.keyboard.down('Control');await page.keyboard.press('End');await page.keyboard.up('Control');await page.keyboard.sendCharacter('// before move\n');
 await until(()=>readFileSync(join(workspace,'src/Main.hx'),'utf8').includes('// before move'),'pre-move edit');
 await palette('>Rename File');await sleep(400);await page.keyboard.down('Control');await page.keyboard.press('a');await page.keyboard.up('Control');await page.keyboard.type('Renamed.hx',{delay:20});await page.keyboard.press('Enter');
 await until(()=>existsSync(join(workspace,'src/Renamed.hx')),'native rename');
 await until(()=>projections().some(row=>row.ev==='workspace.moved'),'confirmed move event');await sleep(500);
 assert(!existsSync(join(workspace,'src/Main.hx')));
 assert.equal(requests().filter(row=>row.op==='view.open').length,2,'renaming cannot reopen or replace the editor binding');
 assert.equal(requests().filter(row=>row.op==='view.close'&&row.handle===opened.handle).length,0,'renaming cannot dispose the undo owner');
 await page.screenshot({path:join(shots,'renamed.png')});
 await page.mouse.click(350,300);await page.keyboard.down('Control');await page.keyboard.press('z');await page.keyboard.up('Control');
 await until(()=>requests().some(row=>row.op==='view.undo'&&row.handle===opened.handle),'undo retains the binding');
 await until(()=>readFileSync(join(workspace,'src/Renamed.hx'),'utf8')===source,'pre-move edit remains undoable');
 await page.keyboard.down('Control');await page.keyboard.press('s');await page.keyboard.up('Control');
 await until(()=>requests().some(row=>row.op==='view.save'&&row.handle===opened.handle),'save uses the moved handle');
 const saved=requests().findLast(row=>row.op==='view.save'&&row.handle===opened.handle);
 await until(()=>projections().some(row=>row.id===saved.id),'Save acknowledgement');
 assert.equal(projections().find(row=>row.id===saved.id).ok,true);
 assert.equal(projections().filter(row=>row.ev==='workspace.moved').length,1);
 assert.equal(projections().filter(row=>row.ev==='view.error').length,0);
 assert.equal(lines.some(line=>/PAGE ERROR|uncaught exception|RayDE stopped:/.test(line)),false);
 console.log('WASM Explorer rename: confirmed path event, retained split editors, same binding, pre-move undo and Save passed');
}finally{
 writeFileSync(join(shots,'console.log'),lines.join('\n'));await browser?.close();
 if(session.exitCode===null&&session.signalCode===null)await new Promise(resolve=>{session.once('exit',resolve);session.kill('SIGTERM');});
 await new Promise(resolve=>web.close(resolve));rmSync(directory,{recursive:true,force:true});
}
