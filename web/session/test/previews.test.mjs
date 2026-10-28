import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFileSync,existsSync} from 'node:fs';
import puppeteer from 'puppeteer-core';

const chrome=process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
test('app preview bridges reject unscoped calls and bound queued writes; removing a tab removes its frame',{skip:!existsSync(chrome)},async t=>{
 const source=readFileSync(new URL('../src/previews.js',import.meta.url));
 function server(child){return createServer((request,response)=>{
  for(const [key,value] of Object.entries({'Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cross-Origin-Resource-Policy':'cross-origin'}))response.setHeader(key,value);
  response.setHeader('Content-Type',request.url==='/previews.js'?'text/javascript':'text/html');
  response.end(request.url==='/previews.js'?source:child?`<script>
   globalThis.replies=new Map();
   addEventListener('message',event=>{if(event.data?.type==='rayde-preview-files-reply')replies.set(event.data.reply.id,event.data.reply);});
   globalThis.ask=request=>{
    parent.postMessage({type:'rayde-preview-files',request},'*');
    return new Promise(resolve=>{const timer=setInterval(()=>{if(replies.has(request.id)){clearInterval(timer);resolve(replies.get(request.id));}},10);});
   };
  </script>`:'<canvas id="screen" width="1000" height="700"></canvas>');
 });}
 const parent=server(false),child=server(true);
 for(const server of[parent,child]){await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());}
 const browser=await puppeteer.launch({executablePath:chrome,headless:true,args:['--no-sandbox']});t.after(()=>browser.close());
 const page=await browser.newPage();await page.goto('http://127.0.0.1:'+parent.address().port);
 const id='a'.repeat(64),url='http://127.0.0.1:'+child.address().port+'/index.html';
 await page.evaluate(async({id,url})=>{
  const {AppPreviews}=await import('/previews.js');globalThis.calls=[];globalThis.hold=false;globalThis.release=[];
  const client={hello:{root:'/workspace'},request:async(op,params)=>{calls.push({op,params});if(hold)await new Promise(resolve=>release.push(resolve));return{data:'okay'};}};
  globalThis.previews=new AppPreviews(client);
  previews.register({preview:id,url});previews.update({surface:'app',preview:id,x:10,y:20,width:800,height:600,viewportWidth:1000,viewportHeight:700});
 },{id,url});
 const app=await(await page.$('iframe')).contentFrame();await app.waitForFunction(()=>typeof ask==='function');
 const ask=request=>app.evaluate(request=>ask(request),request);
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
