import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFileSync,existsSync} from 'node:fs';
import puppeteer from 'puppeteer-core';

const chrome=process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
test('app preview bridges reject unscoped calls and bound queued writes; removing a tab removes its frame',{skip:!existsSync(chrome)},async t=>{
 const source=readFileSync(new URL('../src/previews.js',import.meta.url)),metadata=readFileSync(new URL('../../../preview/app-metadata.mjs',import.meta.url));
 function server(child){return createServer((request,response)=>{
  for(const [key,value] of Object.entries({'Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cross-Origin-Resource-Policy':'cross-origin'}))response.setHeader(key,value);
  response.setHeader('Content-Type',request.url.endsWith('.mjs')||request.url==='/previews.js'?'text/javascript':'text/html');
  response.end(request.url==='/previews.js'?source:request.url==='/metadata.mjs'?metadata:child?`<script>
   globalThis.replies=new Map();
   addEventListener('message',event=>{if(event.data?.type==='rayde-preview-files-reply')replies.set(event.data.reply.id,event.data.reply);});
   globalThis.ask=request=>{
    parent.postMessage({type:'rayde-preview-files',request},'*');
    return new Promise(resolve=>{const timer=setInterval(()=>{if(replies.has(request.id)){clearInterval(timer);resolve(replies.get(request.id));}},10);});
   };
  </script><meta name="ashui-module" content="app.wasm"><title>Loading</title><div id="status"></div><script type="module" src="metadata.mjs"></script>`:'<canvas id="screen" width="1000" height="700"></canvas>');
 });}
 const parent=server(false),child=server(true);
 for(const server of[parent,child]){await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());}
 const browser=await puppeteer.launch({executablePath:chrome,headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const page=await browser.newPage();await page.goto('http://127.0.0.1:'+parent.address().port);
 const id='a'.repeat(64),url='http://127.0.0.1:'+child.address().port+'/index.html';
 await page.evaluate(async({id,url})=>{
  const {AppPreviews}=await import('/previews.js');globalThis.calls=[];globalThis.titles=[];globalThis.hold=false;globalThis.release=[];
  const client={hello:{root:'/workspace'},request:async(op,params)=>{calls.push({op,params});if(hold)await new Promise(resolve=>release.push(resolve));return{data:'okay'};}};
  globalThis.previews=new AppPreviews(client,undefined,event=>titles.push(event));
  previews.register({preview:id,url});previews.update({surface:'app',preview:id,x:10,y:20,width:800,height:600,viewportWidth:1000,viewportHeight:700});
 },{id,url});
 const app=await(await page.$('iframe')).contentFrame();await app.waitForFunction(()=>typeof ask==='function');
 const ask=request=>app.evaluate(request=>ask(request),request);
 await app.evaluate(()=>{document.title='Pocket Studio';});
 await new Promise(resolve=>setTimeout(resolve,100));assert.equal(await page.evaluate(()=>titles.length),0,'title changed before the first app frame');
 await app.evaluate(()=>document.querySelector('#status').classList.add('fading'));
 await page.waitForFunction(()=>titles.length===1);
 assert.deepEqual(await page.evaluate(()=>titles[0]),{ev:'preview.title',preview:id,title:'Pocket Studio'});
 await app.evaluate(()=>{document.title='Pocket Studio — changed';});
 await page.waitForFunction(()=>titles.length===2);
 assert.equal(await page.$eval('iframe',iframe=>iframe.title),'Pocket Studio — changed');
 await page.evaluate(()=>postMessage({type:'rayde-preview-title',title:'Untrusted'},'*'));
 await new Promise(resolve=>setTimeout(resolve,50));assert.equal(await page.evaluate(()=>titles.length),2,'unrelated window renamed a preview');
 await page.evaluate(()=>{
  const surface=previews.surfaces.get('app');globalThis.originalFrame=surface.iframe.contentWindow;
  previews.update({...surface.bounds,exclusions:[{x:30,y:50,width:80,height:40},{x:50,y:70,width:80,height:40}]});
 });
 assert.deepEqual(await page.evaluate(()=>{
  const iframe=document.querySelector('iframe'),box=iframe.getBoundingClientRect();
  return {visible:getComputedStyle(iframe).visibility,overlap:document.elementFromPoint(box.left+50,box.top+60)?.id,outside:document.elementFromPoint(box.left+250,box.top+150)===iframe,same:iframe.contentWindow===originalFrame};
 }),{visible:'visible',overlap:'screen',outside:true,same:true});
 await page.evaluate(()=>{const surface=previews.surfaces.get('app');previews.update({...surface.bounds,exclusions:[]});});
 assert.equal(await page.$eval('iframe',iframe=>iframe.style.clipPath),'');
 assert.equal((await ask({id:1,op:'fs.read',path:'data/tasks.json'})).ok,true);
 for(const [index,request]of[{op:'fs.read',path:'/etc/passwd'},{op:'fs.read',path:'../private'},{op:'fs.read',path:'.rayde/settings.json'},{op:'proc.spawn',command:'sh'}].entries())assert.equal((await ask({id:index+2,...request})).ok,false);
 assert.deepEqual(await page.evaluate(()=>calls),[{op:'fs.read',params:{path:'data/tasks.json',encoding:'utf8'}}]);
 await page.evaluate(()=>{hold=true;});
 await app.evaluate(()=>{void ask({id:10,op:'fs.write',path:'one.txt',data:'x'.repeat(11*1024*1024)});});
 await page.waitForFunction(()=>calls.length===2);
 const refused=await app.evaluate(()=>ask({id:11,op:'fs.write',path:'two.txt',data:'x'.repeat(6*1024*1024)}));assert.equal(refused.ok,false);assert.match(refused.message,/queue is full/);
 await page.evaluate(()=>{hold=false;for(const resolve of release)resolve();});await app.waitForFunction(()=>replies.has(10));
 assert.equal(await page.evaluate(()=>previews.pendingBytes),0);
 await page.evaluate(id=>previews.unregister(id),id);assert.equal(await page.$('iframe'),null);
});
