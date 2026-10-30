#!/usr/bin/env node
// Prepare the demo through the editor's normal Run Configuration and verify a full cache hit.
import assert from 'node:assert/strict';
import {access,realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import {homedir} from 'node:os';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {parseArgs} from 'node:util';

const root=resolve(import.meta.dirname,'..');
const {values}=parseArgs({options:{url:{type:'string',default:'http://127.0.0.1:8731/'},workspace:{type:'string',default:resolve(homedir(),'.rayde-session/demos/pocket-studio')},chrome:{type:'string'},timeout:{type:'string',default:'240'},help:{type:'boolean'}}});
if(values.help){console.log('node scripts/warm-preview.mjs [--url http://127.0.0.1:8731/] [--workspace PATH] [--chrome PATH] [--timeout SECONDS]');process.exit(0);}
const url=new URL(values.url),timeout=Number(values.timeout)*1000;
assert.ok(url.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(url.hostname)&&!url.username&&!url.password&&!url.search&&!url.hash,'Use a loopback demo URL without credentials or query parameters');
assert.ok(Number.isFinite(timeout)&&timeout>=1000&&timeout<=600000,'Timeout must be between 1 and 600 seconds');
const expected=await realpath(values.workspace);
const require=createRequire(resolve(root,'web/session/package.json'));
const puppeteer=require('puppeteer-core'),{WebSocket}=require('ws');
let executablePath=values.chrome??process.env.CHROME;
if(!executablePath)for(const candidate of ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','/usr/bin/chromium','/usr/bin/chromium-browser','/usr/bin/google-chrome']){
 try{await access(candidate,constants.X_OK);executablePath=candidate;break;}catch{}
}
assert.ok(executablePath,'Set CHROME or --chrome to a Chrome/Chromium executable');
const prepares=[],opened=[],published=[],compiles=[],roots=new Set(),tracked=new WeakSet();
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let stopped=null,browser;
function observe(client){
 if(tracked.has(client))return;tracked.add(client);
 const pending=new Map();
 const decode=frame=>{try{return JSON.parse(frame.opcode===2?Buffer.from(frame.payloadData,'base64').toString():frame.payloadData);}catch{return null;}};
 client.on('Network.webSocketFrameSent',event=>{
  const request=decode(event.response);if(!request)return;
  const compiler=request.op==='proc.spawn'&&request.args?.some(arg=>arg==='wasm32-wasip1-threads'||String(arg).endsWith('/app.hl'));
  if(compiler)compiles.push(request.command);
  if(['hello','preview.prepare','preview.cache','preview.open'].includes(request.op))pending.set(event.requestId+':'+JSON.stringify(request.id),request);
 });
 client.on('Network.webSocketFrameReceived',event=>{
  const reply=decode(event.response);if(!reply)return;
  const key=event.requestId+':'+JSON.stringify(reply.id),request=pending.get(key);if(!request)return;pending.delete(key);
  if(reply.ok!==true){stopped=reply.message??'Preview request failed';return;}
  if(request.op==='hello'&&reply.root)roots.add(reply.root);
  if(request.op==='preview.prepare'){prepares.push({...reply,recipe:request.recipe});console.log('Preview cache: '+reply.cached+(reply.cacheNote?' ('+reply.cacheNote+')':''));}
  if(request.op==='preview.cache'&&request.stage==='wasm')published.push(reply);
  if(request.op==='preview.open')opened.push(reply);
 });
 return client.send('Network.enable');
}
async function until(check,label){
 const end=Date.now()+timeout;
 while(!await check()){
  if(stopped)throw Error(stopped);
  if(Date.now()>end)throw Error('Timed out waiting for '+label);
  await pause(50);
 }
}
try{
 browser=await puppeteer.launch({executablePath,headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1440,height:1100}});
 const page=await browser.newPage();
 page.on('workercreated',worker=>{Promise.resolve(observe(worker.client)).catch(error=>{stopped=error.message;});});
 await observe(await page.createCDPSession());
 page.on('pageerror',error=>{stopped=error.message;});
 page.on('console',message=>{if(message.text().startsWith('RayDE stopped:'))stopped=message.text();});
 await page.goto(url.href,{waitUntil:'domcontentloaded'});
 await page.$eval('#editor',element=>element.parentElement.scrollIntoView());
 await until(()=>page.$eval('#demo-state',element=>element.hasAttribute('data-live')),'the landing editor');
 await until(()=>roots.size>0,'the workspace handshake');
 assert.ok(roots.size===1&&roots.has(expected),'The landing session is not connected to the expected demo workspace');
 const frame=await(await page.$('#editor')).contentFrame();
 const primary=await frame.evaluate(()=>/mac|iphone|ipad/i.test(navigator.userAgentData?.platform??navigator.platform)?'Meta':'Control');
 async function preview(){
  await frame.evaluate(()=>document.querySelector('#screen').focus());
  await page.keyboard.down(primary);await page.keyboard.press('p');await page.keyboard.up(primary);await pause(400);
  await page.keyboard.sendCharacter('>Preview App');await pause(400);await page.keyboard.press('Enter');
 }
 console.log('Preparing the preview through its Run Configuration…');
 const first=Date.now();await preview();
 await until(()=>opened.length===1,'the built preview');
 assert.ok(prepares.length===1,'Expected one preview build');
 assert.ok(prepares[0].cached==='wasm'||published.some(reply=>reply.cached===true),'The completed WASM build was not cached');
 const preparedMilliseconds=Date.now()-first,previousCompiles=compiles.length,next=Date.now();
 const connection=await page.evaluate(()=>JSON.parse(localStorage.getItem('rayde.workspaceConnection.v1')));
 assert.equal(new URL(connection.endpoint).origin,url.origin.replace('http:','ws:'),'The cache probe must use the same session host');
 const socket=new WebSocket(connection.endpoint,{headers:{Origin:url.origin}}),waiting=new Map();let serial=0,probe=null;
 socket.on('message',bytes=>{const reply=JSON.parse(bytes.toString()),done=waiting.get(reply.id);if(done){waiting.delete(reply.id);done(null,reply);}});
 const failed=error=>{for(const done of waiting.values())done(error);waiting.clear();};
 socket.on('error',failed);socket.on('close',()=>failed(Error('Cache probe disconnected')));
 function request(op,data={}){return new Promise((resolve,reject)=>{
  const id=++serial,timer=setTimeout(()=>{waiting.delete(id);reject(Error('Cache probe timed out: '+op));},timeout);
  waiting.set(id,(error,reply)=>{clearTimeout(timer);if(error)reject(error);else if(reply.ok!==true)reject(Error(reply.message??'Cache probe failed'));else resolve(reply);});
  socket.send(JSON.stringify({...data,id,op}));
 });}
 try{
  await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Cache probe connection timed out')),timeout);socket.once('open',()=>{clearTimeout(timer);resolve();});socket.once('error',error=>{clearTimeout(timer);reject(error);});});
  assert.equal((await request('hello',{token:connection.token})).root,expected,'The cache probe reached another workspace');
  probe=await request('preview.prepare',{recipe:prepares[0].recipe});
  assert.equal(probe.cached,'wasm','The verification request missed the full WASM cache');
  console.log('Preview cache: '+probe.cached);
 }finally{
  if(probe)await request('preview.discard',{path:probe.path}).catch(()=>{});
  socket.terminate();
 }
 assert.equal(compiles.length,previousCompiles,'A compiler ran during the cached verification');
 console.log(JSON.stringify({cached:'wasm',preparationCache:prepares[0].cached,preparationCompiles:previousCompiles,preparedMilliseconds,verifiedMilliseconds:Date.now()-next,verificationCompiles:compiles.length-previousCompiles}));
}catch(error){console.error('Preview preparation failed: '+error.message);process.exitCode=1;}
finally{await browser?.close();}
