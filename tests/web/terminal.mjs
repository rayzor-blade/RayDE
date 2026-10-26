// Real browser PTY input, resize, multiple screens, visibility, disconnect and no-exec behavior.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {createServer as netServer} from 'node:net';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),dir=resolve(root,process.argv[2]??'bin/web/rayde'),shots=join(root,'bin/web/terminal-shots');mkdirSync(shots,{recursive:true});
const require=createRequire(join(root,'web/session/package.json')),puppeteer=require('puppeteer-core');
const workspace=mkdtempSync(join(tmpdir(),'rayde-terminal-'));mkdirSync(join(workspace,'src'));mkdirSync(join(workspace,'.rayde'));
writeFileSync(join(workspace,'build.hxml'),'-cp src\n--interp\n');writeFileSync(join(workspace,'.rayde/settings.json'),JSON.stringify({extensions:{disabled:['rayzor','git','markdown','jam']}}));
writeFileSync(join(workspace,'src/Main.hx'),'class Main { static function main() {} }\n');
const pause=ms=>new Promise(r=>setTimeout(r,ms)),free=()=>new Promise(r=>{const s=netServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});
const webPort=await free(),sessionPort=await free(),logs=[],requests=[],replies=[];let browser;
const server=createServer((request,response)=>{try{const name=new URL(request.url,'http://local').pathname,path=resolve(dir,'.'+(name==='/'?'/index.html':name));if(!path.startsWith(dir+'/'))throw 0;let body=readFileSync(path);
 if(name==='/ashui-host.mjs')body=Buffer.from(body.toString().replace('Math.max(1, (navigator.hardwareConcurrency || 4) - 1)','3'));
 if(name==='/rayde_session.mjs')body=Buffer.from(body.toString()
  .replace('let reply;',`let reply; if (request.op.startsWith("term.")) console.log("terminal-request:"+JSON.stringify(request));`)
  .replace('const answer = (message) => {',`const answer = (message) => { if (message.ev?.startsWith("term.")) console.log("terminal-event:"+JSON.stringify(message)); if (message.ok === false) console.log("bridge-error:"+JSON.stringify(message)); `));
 response.writeHead(200,{'Content-Type':path.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(path)?'text/javascript':'text/html','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});response.end(body);
 }catch{response.writeHead(404).end();}}).listen(webPort,'127.0.0.1');
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',workspace,'--state-root',join(workspace,'.state'),'--port',String(sessionPort),'--token','terminal-test','--origin',`http://127.0.0.1:${webPort}`,...(process.env.RAYDE_TERMINAL_NO_EXEC?[]:['--exec'])],{stdio:'ignore',env:{...process.env,SHELL:'/bin/sh'}});
const report={ok:false,noExec:!!process.env.RAYDE_TERMINAL_NO_EXEC};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1280,height:800}});
 const page=await browser.newPage();await page.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'userAgentData',{value:{platform:'macOS'}}));
 page.on('console',m=>{const text=m.text();logs.push(text);if(text.startsWith('terminal-request:'))requests.push(JSON.parse(text.slice(17)));if(text.startsWith('terminal-event:'))replies.push(JSON.parse(text.slice(15)));writeFileSync(join(shots,'console.log'),logs.join('\n'));});page.on('pageerror',e=>logs.push('PAGE ERROR '+e.stack));
 async function until(test,label,seconds=15){const end=Date.now()+seconds*1000;while(!test()){assert(!logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)),logs.join('\n'));if(Date.now()>end)throw Error('Timed out: '+label);await pause(50);}}
 await page.goto(`http://127.0.0.1:${webPort}/?session=${encodeURIComponent(`ws://127.0.0.1:${sessionPort}/session`)}&project=build.hxml#token=terminal-test`,{waitUntil:'domcontentloaded'});await until(()=>logs.includes('ashui: ready'),'ready',45);await pause(1500);
 async function toggle(){await page.keyboard.down('Control');await page.keyboard.press('Backquote');await page.keyboard.up('Control');}
 await toggle();
 if(report.noExec){await pause(1200);assert(!logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)));assert.equal(requests.length,0);await page.screenshot({path:join(shots,'no-exec.png')});report.unavailableSafe=true;}
 else {
  await until(()=>replies.some(r=>r.ev==='term.update'),'initial screen');await pause(600);
  await page.screenshot({path:join(shots,'opened.png')});
  const opened=requests.filter(r=>r.op==='term.open').length;await page.mouse.click(650,680);
  await page.keyboard.type("printf '\\033[31m%s%s\\033[0m\\n' 'RayDE-' 'PTY'; test -t 0 && echo tty-yes; stty size",{delay:5});await page.keyboard.press('Enter');
  const text=r=>(r.rows??[]).map(row=>row.text??'').join('\n');
  await until(()=>replies.some(r=>text(r).includes('RayDE-PTY')),'typed PTY command');await pause(200);await page.screenshot({path:join(shots,'command-output.png')});report.inputOutput=true;
  await pause(300);const resizes=new Map();for(const request of requests.filter(r=>r.op==='term.resize')){const value=[request.cols,request.rows].join(':');assert.notEqual(resizes.get(request.tid),value,'Repeated identical resize');resizes.set(request.tid,value);}report.resizeCoalesced=true;
  const resized=requests.filter(r=>r.op==='term.resize').length;await page.setViewport({width:1080,height:740});
  await until(()=>requests.filter(r=>r.op==='term.resize').length>resized,'resize');report.resize=true;
  await toggle();await until(()=>requests.some(r=>r.op==='term.visible'&&r.visible===false),'hide');
  await toggle();await pause(400);assert.equal(requests.filter(r=>r.op==='term.open').length,opened,'Reopening the panel must retain the PTY');
  await page.keyboard.type("printf '%s%s\\n' 'Reopened-' 'terminal'",{delay:5});await page.keyboard.press('Enter');await until(()=>replies.some(r=>text(r).includes('Reopened-terminal')),'reopened terminal input');report.reopen=true;
  await page.keyboard.down('Control');await page.keyboard.down('Shift');await page.keyboard.press('Backquote');await page.keyboard.up('Shift');await page.keyboard.up('Control');
  await until(()=>requests.filter(r=>r.op==='term.open').length>opened,'second terminal');await until(()=>new Set(replies.filter(r=>r.ev==='term.ready').map(r=>r.tid)).size===2,'two ready terminals');report.multiple=true;
  await pause(250);await page.screenshot({path:join(shots,'two-terminals.png')});session.kill('SIGINT');
  await pause(500);await page.keyboard.down('Meta');await page.keyboard.down('Shift');await page.keyboard.press('p');await page.keyboard.up('Shift');await page.keyboard.up('Meta');await pause(300);await page.screenshot({path:join(shots,'after-disconnect.png')});report.disconnectSafe=true;
 }
 assert(!logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)));report.ok=true;console.log(JSON.stringify(report));
}finally{writeFileSync(join(shots,'result.json'),JSON.stringify(report,null,2));if(browser)await browser.close();session.kill('SIGINT');server.close();}
