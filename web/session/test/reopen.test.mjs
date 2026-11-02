import test from "node:test";
import assert from "node:assert/strict";
import {reopenWorkspace} from "../src/reopen.js";

test("reopen waits for recovery and personal storage before scheduling navigation", async () => {
  const calls = [], scheduled = []; let saved;
  const client = {invalidated:{code:"workspace-changed"}, docs:new Map([["a",{checkpoint:() => new Promise(resolve => { saved = resolve; calls.push("recovery"); })}]])};
  const work = reopenWorkspace(client,async () => {calls.push("storage");},{later:fn => scheduled.push(fn),reload:() => calls.push("reload")});
  assert.deepEqual(calls,["recovery"]);assert.equal(scheduled.length,0);
  saved();await work;
  assert.deepEqual(calls,["recovery","storage"]);assert.equal(scheduled.length,1);
  scheduled[0]();assert.equal(calls.at(-1),"reload");
});

test("failed recovery or personal storage keeps the page open", async () => {
  for (const failure of ["recovery","storage"]) {
    let navigated = false;
    const client = {invalidated:{code:"workspace-changed"},docs:new Map([["a",{checkpoint:async () => {if(failure === "recovery")throw Error("disk full");}}]])};
    await assert.rejects(reopenWorkspace(client,async () => {if(failure === "storage")throw Error("disk full");},{later:() => {navigated = true;}}),/disk full/);
    assert.equal(navigated,false);
  }
  await assert.rejects(reopenWorkspace({docs:new Map()},async () => {}),/does not need/);
});

test("a stalled checkpoint cannot navigate after its reopen attempt expires", async () => {
  let finish, navigated = false;
  const client = {invalidated:{code:"workspace-changed"},docs:new Map([["a",{checkpoint:() => new Promise(resolve => {finish=resolve;})}]])};
  await assert.rejects(reopenWorkspace(client,async () => {},{timeout:10,later:() => {navigated=true;}}),/taking too long/);
  finish();await new Promise(resolve => setImmediate(resolve));assert.equal(navigated,false);
});

test("renewing Cloud Sync checkpoints edits and reauthorizes before navigation", async () => {
  const calls=[],scheduled=[];
  const client={docs:new Map([["a",{checkpoint:async()=>{calls.push("recovery");}}]])};
  await reopenWorkspace(client,async()=>{calls.push("storage");},{renew:async()=>{calls.push("renew");},later:fn=>scheduled.push(fn),reload:()=>calls.push("reload")});
  assert.deepEqual(calls,["recovery","storage","renew"]);
  scheduled[0]();assert.equal(calls.at(-1),"reload");
  await assert.rejects(reopenWorkspace(client,async()=>{},{renew:async()=>{throw Error("access expired");},later:()=>assert.fail("failed renewal must keep the page open")}),/access expired/);
});

test("an expired checkpoint cannot renew a credential later", async () => {
  let finish,renewed=false;
  const client={docs:new Map([["a",{checkpoint:()=>new Promise(resolve=>{finish=resolve;})}]])};
  await assert.rejects(reopenWorkspace(client,async()=>{},{timeout:10,renew:async()=>{renewed=true;},later:()=>assert.fail("expired reopen must keep the page open")}),/taking too long/);
  finish();await new Promise(resolve=>setImmediate(resolve));assert.equal(renewed,false);
});
