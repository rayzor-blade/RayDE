// Responsive landing, nested module loading and local launch-port regression.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {mkdtemp,mkdir,writeFile,readFile,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),shots=join(root,'bin/web/landing-shots');
const puppeteer=createRequire(join(root,'web/session/package.json'))('puppeteer-core');
await mkdir(shots,{recursive:true});
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const children=[];
async function service(command,args,prefix){
 const child=spawn(command,args,{cwd:root,stdio:['ignore','pipe','pipe']});children.push(child);
 let buffered='',errors='';child.stderr.on('data',bytes=>{errors=(errors+bytes).slice(-4000);});
 return new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>reject(Error('Preview did not start: '+errors)),20000);
  child.once('exit',code=>{clearTimeout(timer);reject(Error('Preview exited: '+code+' '+errors));});
  child.stdout.on('data',bytes=>{buffered+=bytes;while(buffered.includes('\n')){const at=buffered.indexOf('\n'),line=buffered.slice(0,at).trim();buffered=buffered.slice(at+1);if(line.startsWith(prefix)){clearTimeout(timer);resolve(line.slice(prefix.length).trim());}}});
 });
}
const url=await service('python3',['scripts/serve-site.py','--port','0','--offline'],'RayDE landing page: ');
const browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1440,height:1080}});
const temporary=await mkdtemp(join(tmpdir(),'rayde-nested-host-'));
const report={ok:false,mobile:[]},logs=[];
try{
 for(const width of [320,390,768]){
  const context=await browser.createBrowserContext(),page=await context.newPage(),requests=[];
  await page.setViewport({width,height:844,isMobile:true,deviceScaleFactor:1});
  page.on('request',request=>requests.push(new URL(request.url()).pathname));
  await page.goto(url,{waitUntil:'networkidle0'});
  assert.equal(await page.$eval('#editor',frame=>frame.hasAttribute('src')),false);
  assert.equal(requests.some(path=>/\.wasm$|\/(ashui-host|worker|thread|gpu-worker)/.test(path)),false,'Mobile loaded the runtime');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Mobile horizontal overflow');
  assert.equal(await page.$eval('.editor-poster',image=>image.complete&&image.naturalWidth>0),true);
  assert.equal(await page.$$eval('a[href^="#"]',links=>links.every(link=>document.querySelector(link.getAttribute('href')))),true);
  await page.screenshot({path:join(shots,`mobile-${width}.png`),fullPage:true});
  report.mobile.push(width);await context.close();
 }
 const page=await browser.newPage(),failures=[];
 await page.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'hardwareConcurrency',{value:4}));
 await page.emulateMediaFeatures([{name:'prefers-color-scheme',value:'dark'},{name:'prefers-reduced-motion',value:'reduce'}]);
 page.on('console',message=>logs.push(message.text()));page.on('pageerror',error=>failures.push(String(error)));
 page.on('response',response=>{if(response.status()>=400&&!response.url().endsWith('/favicon.ico'))failures.push(response.status()+' '+new URL(response.url()).pathname);});
 await page.goto(url);
 await page.waitForFunction(()=>document.querySelector('#demo-state').hasAttribute('data-live'),{timeout:120000});
 const editor=await (await page.$('#editor')).contentFrame();
 assert.equal(await editor.$$eval('canvas',nodes=>nodes.length),1);
 assert.equal(await page.$$eval('canvas',nodes=>nodes.length),0);
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 await page.screenshot({path:join(shots,'desktop.png'),fullPage:true});
 await (await page.$('#editor')).screenshot({path:join(shots,'editor.png')});
 await pause(1000);
 await (await editor.$('#screen')).click({offset:{x:300,y:210}});
 const modifier=await editor.evaluate(()=>/mac/i.test(navigator.userAgentData?.platform??navigator.platform)?'Meta':'Control');
 await page.keyboard.down(modifier);await page.keyboard.press('a');await page.keyboard.up(modifier);
 await page.keyboard.type('class Main { static function main() { trace("Landing edit"); } }',{delay:5});
 await page.keyboard.down(modifier);await page.keyboard.press('s');await page.keyboard.up(modifier);
 await editor.waitForFunction(()=>new Promise(resolve=>{
  const request=indexedDB.open('rayde-page',1);request.onsuccess=()=>{const db=request.result,read=db.transaction('files').objectStore('files').get('/work/pocket-studio/src/Main.hx');read.onsuccess=()=>{resolve(!!read.result&&atob(read.result.data).includes('Landing edit'));db.close();};};
 }),{timeout:20000});
 report.editing=true;
 const seeded=await editor.evaluate(()=>new Promise(resolve=>{
  const request=indexedDB.open('rayde-page',1);request.onsuccess=()=>{const db=request.result,read=db.transaction('files').objectStore('files').getAll();read.onsuccess=()=>{resolve(read.result.filter(entry=>entry.path.startsWith('/work/pocket-studio/')));db.close();};};
 }));
 assert.ok(seeded.some(entry=>entry.path.endsWith('/extensions/pocket-tools/ext/main.rays')));
 assert.ok(seeded.filter(entry=>!entry.directory).length>=20);
 const hxml=atob(seeded.find(entry=>entry.path.endsWith('/build.hxml')).data);
 const demo=JSON.parse(await readFile(join(root,'site/demo/haxelib.json'),'utf8'));
 assert.ok(hxml.includes('-L ashui:'+demo.dependencies.ashui));assert.ok(!hxml.includes('../'));
 await page.reload();await page.waitForFunction(()=>document.querySelector('#demo-state').hasAttribute('data-live'),{timeout:120000});
 const reloaded=await (await page.$('#editor')).contentFrame();
 const kept=await reloaded.evaluate(()=>new Promise(resolve=>{const request=indexedDB.open('rayde-page',1);request.onsuccess=()=>{const db=request.result,read=db.transaction('files').objectStore('files').get('/work/pocket-studio/src/Main.hx');read.onsuccess=()=>{resolve(atob(read.result.data));db.close();};};}));
 assert.match(kept,/Landing edit/);report.demoWorkspace=report.preservedEdits=true;
 await page.setViewport({width:390,height:844,isMobile:true});
 await page.waitForFunction(()=>!document.querySelector('#editor').hasAttribute('src'));
 assert.equal(await page.$eval('#editor',frame=>frame.hidden),true);
 assert.equal(await page.$eval('.editor-poster',image=>!image.hidden),true);
 report.resizeStopsRuntime=true;
 await page.goto(new URL('/docs/',url),{waitUntil:'networkidle0'});
 assert.match(await page.title(),/Getting started/);report.docs=true;
 assert.deepEqual(failures,[]);
 await page.close();
 // The containing page and host deliberately live in different directories.
 await mkdir(join(temporary,'workspace'));
 await symlink(join(root,'site/dist'),join(temporary,'dist'),'dir');
 await writeFile(join(temporary,'index.html'),`<!doctype html><meta name="ashui-module" content="rayde.wasm"><style>body{margin:30px}#screen{width:1000px;height:650px}#status[hidden]{display:none}</style><div id="status"><h1 id="status-title"></h1><p id="status-detail"></p></div><canvas id="screen" tabindex="0" data-xwindow="fit"></canvas><pre id="out"></pre><script src="./dist/rayde-platform.js"></script><script type="module" src="./dist/ashui-host.mjs"></script>`);
 const nested=await service(join(root,'native/session/target/debug/rayde-session'),['--root',join(temporary,'workspace'),'--state-root',join(temporary,'state'),'--web',temporary,'--port','0'],'http://');
 const inline=await browser.newPage(),bad=[];
 await inline.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'hardwareConcurrency',{value:4}));
 inline.on('response',response=>{if(response.status()>=400&&!response.url().endsWith('/favicon.ico'))bad.push(response.status()+' '+new URL(response.url()).pathname);});
 inline.on('pageerror',error=>bad.push(String(error)));
 await inline.goto('http://'+nested+'?demo=1');
 await inline.waitForFunction(()=>document.querySelector('#status').hidden,{timeout:120000});
 assert.deepEqual(bad,[]);report.nestedModulePaths=true;
 await inline.screenshot({path:join(shots,'nested-host.png')});
 report.ok=true;console.log(JSON.stringify(report));
}catch(error){for(const page of await browser.pages()){if(page.url().startsWith('http'))await page.screenshot({path:join(shots,'failure.png'),fullPage:true}).catch(()=>{});}throw error;}finally{
 await writeFile(join(shots,'result.json'),JSON.stringify(report,null,2));await writeFile(join(shots,'browser.log'),logs.join('\n'));
 await browser.close();
 for(const child of children){if(child.exitCode===null){const ended=once(child,'exit');child.kill('SIGINT');await ended;}}
 await rm(temporary,{recursive:true,force:true});
}
