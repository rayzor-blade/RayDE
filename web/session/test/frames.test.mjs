import { test } from "node:test";
import assert from "node:assert/strict";
import { Frames, frame, MAX_FRAME } from "../src/frames.js";

test("messages keep their boundaries across headers, UTF-8 characters and wrapped channel-sized chunks", () => {
  const messages = ["", "⌘あ🦊", "x".repeat(90000), JSON.stringify({ n: 2 })];
  for (const size of [1, 3, 16384, 30000]) {
    const found = [], receiver = new Frames(text => found.push(text));
    for (const text of messages) {
      const bytes = frame(text);
      for (let at = 0; at < bytes.length; at += size) receiver.push(bytes.subarray(at, at + size));
    }
    assert.deepEqual(found, messages);
  }
});

test("an untrusted oversized length is rejected before payload allocation", () => {
  const bytes = new Uint8Array(4); new DataView(bytes.buffer).setUint32(0, MAX_FRAME + 1);
  assert.throws(() => new Frames(() => {}).push(bytes), /too large/);
});
