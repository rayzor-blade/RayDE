import test from 'node:test';
import assert from 'node:assert/strict';
import {connectionSettings,readConnection,saveConnection,clearConnection} from '../src/connection.js';
import {pageEntry} from '../src/entry.js';
const config={version:1,endpoint:'ws://127.0.0.1:47991/session',token:'private-fixture',project:'build.hxml',environment:['CUSTOM=value']};
const storage=()=>{const data=new Map();return {getItem:key=>data.get(key)??null,setItem:(key,value)=>data.set(key,value),removeItem:key=>data.delete(key)};};
test('private browser settings survive reload and can be removed',()=>{
 const local=storage();assert.equal(readConnection(local),null);saveConnection(config,local);assert.deepEqual(readConnection(local),config);clearConnection(local);assert.equal(readConnection(local),null);
});
test('a clean editor URL selects remembered connection settings',()=>{
 const entry=pageEntry({href:'http://127.0.0.1:8732/dist/index.html'},config);
 assert.equal(entry.endpoint,config.endpoint);assert.equal(entry.token,config.token);assert.equal(entry.project,config.project);assert.equal(entry.demo,false);
 assert.equal(pageEntry({href:'http://127.0.0.1:8732/dist/index.html?demo=1'},config).endpoint,null);
});
test('hosted accounts and explicit session URLs take precedence over local preview settings',()=>{
 const hosted=pageEntry({href:'https://app.rayde.org/'+'a'.repeat(43)},config);assert.match(hosted.endpoint,/^wss:\/\/app.rayde.org/);assert.equal(hosted.token,undefined);
 const explicit=pageEntry({href:'http://localhost/?session=ws://remote.test/session#token=other'},config);assert.equal(explicit.endpoint,'ws://remote.test/session');assert.equal(explicit.token,'other');
});
test('connection settings reject executable URLs and malformed environment entries',()=>{
 for(const endpoint of ['javascript:alert(1)','https://example.test/session','ws://token@example.test/session'])assert.throws(()=>connectionSettings({...config,endpoint}));
 for(const environment of [['bad entry'],['NAME=x\nINJECT=y'],[10]])assert.throws(()=>connectionSettings({...config,environment}));
 const local=storage();local.setItem('rayde.workspaceConnection.v1','broken');assert.equal(readConnection(local),null);
 assert.equal(readConnection({getItem:()=>{throw Error('Storage denied');}}),null);
});
