// Length-prefixed messages split into channel-sized pieces, without imposing the ring's size on files.
export const MAX_FRAME = 16 * 1024 * 1024;
const encode = new TextEncoder(), decode = new TextDecoder("utf-8", { fatal: true });

export function frame(text) {
  const bytes = encode.encode(text);
  if (bytes.length > MAX_FRAME) throw new Error("The session message is too large.");
  const out = new Uint8Array(4 + bytes.length);
  new DataView(out.buffer).setUint32(0, bytes.length);
  out.set(bytes, 4);
  return out;
}

export class Frames {
  constructor(receive) { this.receive = receive; this.header = new Uint8Array(4); this.headerUsed = 0; this.payload = null; this.used = 0; }
  push(chunk) {
    let at = 0;
    while (at < chunk.length) {
      if (this.headerUsed < 4) {
        const count = Math.min(4 - this.headerUsed, chunk.length - at);
        this.header.set(chunk.subarray(at, at + count), this.headerUsed); at += count; this.headerUsed += count;
        if (this.headerUsed < 4) return;
        const length = new DataView(this.header.buffer).getUint32(0);
        if (length > MAX_FRAME) throw new Error("The session message is too large.");
        this.payload = new Uint8Array(length); this.used = 0;
      }
      const count = Math.min(this.payload.length - this.used, chunk.length - at);
      this.payload.set(chunk.subarray(at, at + count), this.used); at += count; this.used += count;
      if (this.used === this.payload.length) {
        const text = decode.decode(this.payload); this.payload = null; this.headerUsed = 0;
        this.receive(text);
      }
    }
  }
}
