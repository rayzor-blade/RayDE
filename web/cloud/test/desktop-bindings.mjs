// Explicit native/Haxe and browser-client check; requires bin/desktop-sync-checks.hl and its staged natives.
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import WebSocket from 'ws';
import {SessionClient} from '../../session/src/client.js';
const pause=ms=>new Promise(done=>setTimeout(done,ms));
async function until(check,label){const deadline=Date.now()+30000;while(!await check()){if(Date.now()>deadline)throw Error('Timed out: '+label);await pause(25);}}
const port=await new Promise(done=>{const s=createServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>done(p));});});
const data=await mkdtemp(join(tmpdir(),'rayde-desktop-gateway-')),root=await mkdtemp(join(tmpdir(),'rayde-desktop-folder-')),base=`http://127.0.0.1:${port}`;
let log='',nativeLog='',gateway,native,client;
const stop=async process=>{if(!process||process.exitCode!==null||process.signalCode!==null)return;const done=new Promise(resolve=>process.once('exit',resolve));process.kill();await done;};
try{
 gateway=spawn('node',['dev/sync-dev.mjs','--port',String(port),'--data',data],{stdio:['ignore','pipe','inherit']});gateway.stdout.on('data',bytes=>{log+=bytes;});await until(()=>log.includes('Cloud Sync gateway'),'gateway');
 const git=(...args)=>{const r=spawnSync('git',['-C',root,'-c','user.name=T','-c','user.email=t@example.invalid','-c','commit.gpgsign=false',...args]);assert.equal(r.status,0,String(r.stderr));};
 git('init','-q','-b','main');await writeFile(join(root,'a.txt'),'base 🦀');git('add','.');git('commit','-qm','first');
 const push=spawnSync(resolve('../../native/sync/target/debug/examples/push'),[root,base,'alice'],{encoding:'utf8'});assert.equal(push.status,0,push.stderr);const published=JSON.parse(push.stdout.trim().split('\n').at(-1));assert.equal(published.event,'published');const id=published.url.split('/').pop();
 const response=await fetch(`${base}/api/sync/workspaces/${id}/open`,{method:'POST',headers:{'X-Dev-Account':'alice'}});assert.equal(response.status,200);
 const login=await fetch(`${base}/auth/dev?account=alice&return=/${id}`,{redirect:'manual'}),cookie=login.headers.getSetCookie()[0].split(';')[0];
 await until(async()=>{const state=await(await fetch(`${base}/api/workspaces/${id}`,{headers:{Cookie:cookie}})).json();if(state.status==='failed')throw Error(state.message);return state.status==='ready';},'browser session');
 globalThis.WebSocket=class extends WebSocket{constructor(url){super(url,{headers:{Cookie:cookie,Origin:base}});}};
 client=new SessionClient({url:`ws://127.0.0.1:${port}/api/workspaces/${id}/socket`,persist:false,reconnect:false});await client.connect();const doc=await client.openDoc('a.txt');
 native=spawn(process.env.ASH??'ash',['--preset','application',resolve('../../bin/desktop-sync-checks.hl'),root,base],{cwd:resolve('../..'),env:{...process.env,HOME:join(data,'home')},stdio:['pipe','pipe','pipe']});native.stdout.on('data',bytes=>{nativeLog+=bytes;});native.stderr.on('data',bytes=>{nativeLog+=bytes;});
 const step=async marker=>until(()=>{if(native.exitCode!==null&&!nativeLog.includes(marker))throw Error(nativeLog);return nativeLog.includes(marker);},marker);
 await step('DESKTOP_READY');doc.text.insert(0,'browser ');await until(()=>!doc.unsent,'browser acknowledgement');native.stdin.write('\n');await step('DESKTOP_SAVED');
 await doc.sync();assert.equal(doc.text.toString(),'native browser base 🦀');assert.equal(await readFile(join(root,'a.txt'),'utf8'),doc.text.toString());
 native.stdin.write('\n');await step('DESKTOP_DONE');await doc.sync();assert.equal(doc.text.toString(),'browser base 🦀');assert.equal(await readFile(join(root,'a.txt'),'utf8'),doc.text.toString());await doc.close();
 console.log('Desktop/browser editor binding, saved-file separation and per-author undo: passed');
}finally{client?.close();await stop(native);await stop(gateway);await rm(data,{recursive:true,force:true});await rm(root,{recursive:true,force:true});}
