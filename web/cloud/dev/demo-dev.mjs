// Local acceptance harness: the gateway is Rust/WASM and compute runs on a real private runner.
import {readFile,access,appendFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {setTimeout as pause} from 'node:timers/promises';
import {Miniflare} from 'miniflare';
import {options} from '../test/fixture.mjs';
import {stageEditorRelease} from './editor-assets.mjs';

const [configuration,...args]=process.argv.slice(2);
if(!configuration)throw Error('Use demo-dev.mjs PRIVATE_CLIENT_JSON [--port N] [--hostname localhost|127.0.0.1] [--assets URL] [--release DIRECTORY] [--gate FILE] [--events FILE]');
const option=(name,fallback)=>{const at=args.indexOf(name);return at<0?fallback:args[at+1];};
const settings=JSON.parse(await readFile(configuration,'utf8'));
const port=Number(option('--port','8797')),hostname=option('--hostname','127.0.0.1');
if(!['localhost','127.0.0.1'].includes(hostname))throw Error('The acceptance harness requires a loopback hostname');
const appOrigin=`http://${hostname}:${port}`;
const gate=option('--gate'),events=option('--events'),release=option('--release');
const abort=new AbortController();
const {config}=options({port,appOrigin,asset:option('--assets','http://127.0.0.1:8798'),editorAssets:!!release,
 runnerUrl:settings.url,runnerSecret:(await readFile(settings.secretFile,'utf8')).trim(),runnerSessionOrigin:settings.url,
 demo:{release:settings.release,toolchain:settings.toolchain,maximum:2}});
const runner=config.serviceBindings.RUNNER;
config.serviceBindings.RUNNER=async request=>{
 const operation=new URL(request.url).pathname;
 if(gate&&operation==='/workspaces/open')while(!abort.signal.aborted){try{await access(gate);break;}catch{await pause(100,undefined,{signal:abort.signal});}}
 const started=performance.now(),response=await runner(request);
 if(events)await appendFile(resolve(events),JSON.stringify({operation,status:response.status,elapsedMs:Math.round(performance.now()-started)})+'\n',{mode:0o600});
 return response;
};
const mf=new Miniflare(config);
await mf.ready;
if(release)await stageEditorRelease(await mf.getR2Bucket('EDITOR_ASSETS'),release);
console.log(`Anonymous demo acceptance: ${appOrigin}/?demo=1&demo-live=1`);
console.log('Private runner connected through loopback; no public admission deployment.');
for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>{abort.abort();void mf.dispose().finally(()=>process.exit(0));});
