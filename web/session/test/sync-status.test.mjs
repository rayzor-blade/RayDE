import {test} from 'node:test';
import assert from 'node:assert/strict';
import {SessionClient} from '../src/client.js';

test('sync readiness that arrives before the page subscribes is retained in the handshake',()=>{
 const client=new SessionClient({url:'ws://unused',persist:false});
 client.hello={root:'/workspace',syncWriteback:{workspace:'one',generation:1,ready:false}};
 const ready={workspace:'one',generation:3,ready:true};
 client.receive({ev:'sync.status',syncWriteback:ready});
 assert.equal(client.hello.syncWriteback,ready);
 const received=[];client.on('sync.status',event=>received.push(event.syncWriteback));
 const paused={workspace:'one',generation:3,ready:false,error:'sync-recovery'};
 client.receive({ev:'sync.status',syncWriteback:paused});
 assert.equal(client.hello.syncWriteback,paused);assert.deepEqual(received,[paused]);
 client.receive({ev:'sync.status',syncWriteback:null});assert.equal(client.hello.syncWriteback,null);
});
