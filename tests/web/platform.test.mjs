import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import test from 'node:test';
const source=readFileSync(new URL('../../web/platform.js',import.meta.url),'utf8');
function boot({platform='MacIntel',data,search='',standalone=false,embedded=false,environment=[]}={}){
 const window={matchMedia:()=>({matches:standalone})};window.top=embedded?{}:window;
 let rewrites=0;
 const context={URLSearchParams,navigator:{platform,userAgentData:data},window,localStorage:{getItem:()=>JSON.stringify({version:1,environment})},location:{search,pathname:'/playground/',hash:'#editor'},history:{replaceState:()=>rewrites++}};
 runInNewContext(source,context);
 return {environment:Array.from(context.ashuiEnvironment),rewrites,url:new URL('https://example.test/playground/'+search+'#editor')};
}
for(const [platform,expected] of [['MacIntel','Mac'],['iPad','Mac'],['Win32','Windows'],['Linux x86_64','Linux']]){
 test(`fallback platform ${platform}`,()=>assert.deepEqual(boot({platform}).environment,['RAYDE_VISITOR='+expected]));
}
test('browser platform data takes precedence over legacy platform',()=>assert.deepEqual(boot({platform:'MacIntel',data:{platform:'Windows'}}).environment,['RAYDE_VISITOR=Windows']));
test('a shared URL cannot pin another visitor’s keyboard',()=>{
 const result=boot({search:'?env=RAYDE_VISITOR=Linux&env=ASH_GC_STATS=1&env=RAYDE_VISITOR=Windows&session=demo'});
 assert.deepEqual(result.environment,['ASH_GC_STATS=1','RAYDE_VISITOR=Mac']);assert.equal(result.url.searchParams.get('session'),'demo');assert.equal(result.rewrites,0);
});
test('standalone mode and keyboard are both detected',()=>{
 assert.deepEqual(boot({standalone:true}).environment,['RAYDE_VISITOR=Mac','RAYDE_STANDALONE=1']);
 assert.deepEqual(boot({standalone:true,embedded:true}).environment,['RAYDE_VISITOR=Mac']);
});
test('remembered runtime variables do not dirty the browser URL or override its platform',()=>{
 const result=boot({platform:'Win32',environment:['CUSTOM=value','RAYDE_VISITOR=Mac']});
 assert.deepEqual(result.environment,['CUSTOM=value','RAYDE_VISITOR=Windows']);assert.equal(result.url.search,'');assert.equal(result.rewrites,0);
});
