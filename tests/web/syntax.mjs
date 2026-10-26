// Browser built-in aliases, session grammars, live edits and navigation while syntax is pending.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {createServer as netServer} from 'node:net';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),dir=resolve(root,process.argv[2]??'bin/web/rayde'),shots=join(root,'bin/web/syntax-shots');mkdirSync(shots,{recursive:true});
const require=createRequire(join(root,'web/session/package.json')),puppeteer=require('puppeteer-core');
const workspace=mkdtempSync(join(tmpdir(),'rayde-syntax-'));mkdirSync(join(workspace,'src'));mkdirSync(join(workspace,'.rayde'));
writeFileSync(join(workspace,'build.hxml'),'-cp src\n--interp\n');writeFileSync(join(workspace,'.rayde/settings.json'),JSON.stringify({extensions:{disabled:['rayzor','git','markdown','jam']}}));
const files={
 'script.mjs':'export function greet(name) {\n const text = "Hello";\n return text + name;\n}\n',
 'component.tsx':'export function Card({name}: {name: string}) {\n return <div className="card">Hello {name}</div>;\n}\n',
 'main.rs':'// Rust source\nfn main() {\n let value = 42;\n println!("Hello {value}");\n}\n',
 'main.py':'# Python source\ndef greet(name):\n return "Hello " + name\n',
 'style.css':'.card {\n color: #aabbcc;\n padding: 12px;\n}\n',
 'config.toml':'[package]\nname = "RayDE"\nversion = 42\n',
 'workflow.yaml':'name: "RayDE"\ncount: 42\njobs:\n  test:\n    runs-on: "ubuntu-latest"\n',
 'run.sh':'#!/bin/sh\n# Build the app\necho "Hello"\nexit 0\n',
 'index.html':'<div class="card">\n  <h1>Hello</h1>\n</div>\n',
 'main.go':'package main\n\nfunc main() {\n value := 42\n println("Hello", value)\n}\n',
};for(const [name,text]of Object.entries(files))writeFileSync(join(workspace,'src',name),text);
const pause=ms=>new Promise(r=>setTimeout(r,ms)),free=()=>new Promise(r=>{const s=netServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});
const webPort=await free(),sessionPort=await free(),logs=[],requests=[],replies=[];let browser;
const server=createServer((request,response)=>{try{const name=new URL(request.url,'http://local').pathname,path=resolve(dir,'.'+(name==='/'?'/index.html':name));if(!path.startsWith(dir+'/'))throw 0;let body=readFileSync(path);
 if(name==='/ashui-host.mjs')body=Buffer.from(body.toString().replace('Math.max(1, (navigator.hardwareConcurrency || 4) - 1)','3'));
 if(name==='/rayde_session.mjs')body=Buffer.from(body.toString()
  .replace('let reply;',`let reply; if (request.op === "syntax.highlight") { console.log("syntax-request:"+JSON.stringify({id:request.id,file:request.file,source:request.source})); if (globalThis.__holdSyntax && request.file === "config.toml") { console.log("syntax-held"); await new Promise(resolve => globalThis.__releaseSyntax=resolve); } }`)
  .replace('const answer = (message) => {',`const answer = (message) => { if (Object.hasOwn(message,"tokens")) console.log("syntax-reply:"+JSON.stringify({id:message.id,kinds:[...new Set((message.tokens??[]).flat().map(t=>t.kind))]}));`));
 response.writeHead(200,{'Content-Type':path.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(path)?'text/javascript':'text/html','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});response.end(body);
 }catch{response.writeHead(404).end();}}).listen(webPort,'127.0.0.1');
const session=spawn(join(root,'native/session/target/debug/rayde-session'),['--root',workspace,'--state-root',join(workspace,'.state'),'--port',String(sessionPort),'--token','syntax-test','--origin',`http://127.0.0.1:${webPort}`],{stdio:'ignore'});
const report={ok:false,builtins:[],grammars:[]};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1280,height:800}});
 const page=await browser.newPage();await page.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'userAgentData',{value:{platform:'macOS'}}));
 page.on('console',m=>{const text=m.text();logs.push(text);if(text.startsWith('syntax-request:'))requests.push(JSON.parse(text.slice(15)));if(text.startsWith('syntax-reply:'))replies.push(JSON.parse(text.slice(13)));writeFileSync(join(shots,'console.log'),logs.join('\n'));});page.on('pageerror',e=>logs.push('PAGE ERROR '+e.stack));
 async function until(test,label,seconds=15){const end=Date.now()+seconds*1000;while(!test()){assert(!logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)),logs.join('\n'));if(Date.now()>end)throw Error('Timed out: '+label);await pause(50);}}
 await page.goto(`http://127.0.0.1:${webPort}/?session=${encodeURIComponent(`ws://127.0.0.1:${sessionPort}/session`)}&project=build.hxml#token=syntax-test`,{waitUntil:'domcontentloaded'});await until(()=>logs.includes('ashui: ready'),'ready',45);
 async function chord(k){await page.keyboard.down('Meta');await page.keyboard.press(k);await page.keyboard.up('Meta');}
 async function open(name){await chord('p');await pause(160);await page.keyboard.type(name);await pause(160);await page.keyboard.press('Enter');await pause(400);}
 async function highlighted(name,after=0){await until(()=>requests.slice(after).some(q=>q.file===name&&replies.some(r=>r.id===q.id&&r.kinds.some(k=>k!=='plain'))),'tokens for '+name);await pause(200);}
 for(const name of ['script.mjs','component.tsx','main.rs','main.py','style.css']){await open(name);await highlighted(name);await page.screenshot({path:join(shots,name+'.png')});report.builtins.push(name);}
 await page.evaluate(()=>globalThis.__holdSyntax=true);await open('config.toml');await until(()=>logs.includes('syntax-held'),'held query');
 await open('workflow.yaml');await highlighted('workflow.yaml');report.navigationWhilePending=true;await page.screenshot({path:join(shots,'workflow.yaml.png')});
 await page.evaluate(()=>{globalThis.__holdSyntax=false;globalThis.__releaseSyntax();});
 const before=requests.length;await open('config.toml');await highlighted('config.toml',before);await page.screenshot({path:join(shots,'config.toml.png')});
 await page.mouse.click(700,180);await chord('a');const edited='[package]\nname = "Edited 🙂"\nversion = 123\n';await page.keyboard.sendCharacter(edited);
 await until(()=>requests.some(q=>q.file==='config.toml'&&q.source===edited&&replies.some(r=>r.id===q.id&&r.kinds.includes('number'))),'edited syntax');await pause(200);await page.screenshot({path:join(shots,'config-edited.png')});report.liveEdits=true;report.grammars.push('config.toml','workflow.yaml');
 for(const name of ['run.sh','index.html','main.go']){await open(name);await highlighted(name);await page.screenshot({path:join(shots,name+'.png')});report.grammars.push(name);}
 assert(!logs.some(s=>/RayDE stopped:|uncaught exception|PAGE ERROR/.test(s)));report.ok=true;console.log(JSON.stringify(report));
}finally{writeFileSync(join(shots,'result.json'),JSON.stringify(report,null,2));if(browser)await browser.close();session.kill();server.close();}
