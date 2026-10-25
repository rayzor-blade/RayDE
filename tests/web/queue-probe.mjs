// Test-only observation of xwindow's shared ring; no event or wake is added.
export function watchQueue(memory, address) {
  let tail = 0, head = 0, produced = 0, consumed = 0, pending = [];
  const stats = {events:0, failed:0, dropped:0, maxBytes:0, maxPending:0, inputLatencyMs:[], pending:0};
  globalThis.raydeQueueProbe = stats;
  const words = () => new Int32Array(memory.buffer, address, 5);
  const update = () => {
    const w = words(), capacity = Atomics.load(w, 3) >>> 0;
    if (!capacity) return;
    const nextTail = Atomics.load(w, 0) >>> 0, nextHead = Atomics.load(w, 1) >>> 0;
    produced += (nextTail - tail + capacity) % capacity; tail = nextTail;
    consumed += (nextHead - head + capacity) % capacity; head = nextHead;
    stats.maxBytes = Math.max(stats.maxBytes, (tail - head + capacity) % capacity);
    stats.dropped = Atomics.load(w, 4) >>> 0;
    const now = performance.now();
    while (pending.length && pending[0].end <= consumed) {
      const event = pending.shift();
      if (event.input && stats.inputLatencyMs.length < 4096) stats.inputLatencyMs.push(now - event.at);
    }
    stats.pending = pending.length;
  };
  const frame = () => { update(); requestAnimationFrame(frame); };
  requestAnimationFrame(frame);
  return (event, posted) => {
    update(); stats.events++;
    if (!posted) { stats.failed++; return; }
    pending.push({end:produced, at:performance.now(), input:["mouse-input", "keyboard-input", "mouse-wheel"].includes(event.kind)});
    stats.maxPending = Math.max(stats.maxPending, pending.length);
  };
}
