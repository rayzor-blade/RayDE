// Injected into the GPU worker by page.mjs --probe. Logical allocations are not driver residency.
const stats = { buffers: 0, bufferBytes: 0, textures: 0, textureBytes: 0, peakTextureBytes: 0, uncountedFormats: [], submissions: 0, completed: 0, firstCompletedAt: null, maxInFlight: 0, batches: 0, crossBatchSubmits: 0, lastBatches: [], pipelines: [], errors: [] };
const report = () => self.postMessage({ kind: "rayde-gpu-probe", stats });
globalThis.raydeBatch = (wire, at, len) => {
  const ops = [];
  const view = new DataView(wire.memory.buffer);
  for (const end = at + len; at < end; at += 8 + view.getUint32(at + 4, true)) ops.push(view.getUint32(at, true));
  stats.batches++;
  stats.lastBatches.push({ batch: stats.batches, count: ops.length, first: ops.slice(0, 4), last: ops.slice(-6) });
  if (stats.lastBatches.length > 8) stats.lastBatches.shift();
};
let acquiredBatch = null;
const acquire = GPUCanvasContext.prototype.getCurrentTexture;
GPUCanvasContext.prototype.getCurrentTexture = function (...args) {
  acquiredBatch = stats.batches;
  return acquire.apply(this, args);
};
const bytesPerPixel = { r8unorm: 1, rgba8unorm: 4, "rgba8unorm-srgb": 4, bgra8unorm: 4, "bgra8unorm-srgb": 4, rgba16float: 8, rgba32float: 16, depth24plus: 4, "depth24plus-stencil8": 4, depth32float: 4 };
for (const [method, count, bytes] of [["createBuffer", "buffers", "bufferBytes"], ["createTexture", "textures", "textureBytes"]]) {
  const original = GPUDevice.prototype[method];
  GPUDevice.prototype[method] = function (descriptor) {
    const object = original.call(this, descriptor);
    let size = descriptor.size;
    if (method === "createTexture") {
      const [width, height = 1, depth = 1] = Array.isArray(size) ? size : [size.width, size.height, size.depthOrArrayLayers];
      const bpp = bytesPerPixel[descriptor.format];
      if (!bpp && !stats.uncountedFormats.includes(descriptor.format)) stats.uncountedFormats.push(descriptor.format);
      size = 0;
      for (let mip = 0; mip < (descriptor.mipLevelCount ?? 1); mip++) size += Math.max(1, width >> mip) * Math.max(1, height >> mip) * depth * (bpp ?? 0) * (descriptor.sampleCount ?? 1);
    }
    stats[count]++;
    stats[bytes] += size;
    stats.peakTextureBytes = Math.max(stats.peakTextureBytes, stats.textureBytes);
    let alive = true;
    const destroy = object.destroy.bind(object);
    object.destroy = () => {
      if (alive) { stats[count]--; stats[bytes] -= size; alive = false; }
      return destroy();
    };
    return object;
  };
}
const request = GPUAdapter.prototype.requestDevice;
GPUAdapter.prototype.requestDevice = async function (...args) {
  const device = await request.apply(this, args);
  device.addEventListener("uncapturederror", e => { stats.errors.push(e.error.message); report(); });
  return device;
};
const pipeline = GPUDevice.prototype.createRenderPipeline;
GPUDevice.prototype.createRenderPipeline = function (descriptor) {
  const start = performance.now();
  const result = pipeline.call(this, descriptor);
  stats.pipelines.push({ ms: performance.now() - start, at: start, label: descriptor.label ?? "" });
  return result;
};
const submit = GPUQueue.prototype.submit;
GPUQueue.prototype.submit = function (...args) {
  const result = submit.apply(this, args);
  stats.submissions++;
  if (acquiredBatch !== null && acquiredBatch !== stats.batches) stats.crossBatchSubmits++;
  acquiredBatch = null;
  stats.maxInFlight = Math.max(stats.maxInFlight, stats.submissions - stats.completed);
  this.onSubmittedWorkDone().then(() => {
    stats.completed++;
    if (stats.completed === 1) { stats.firstCompletedAt = performance.timeOrigin + performance.now(); report(); }
  }, error => { stats.errors.push(String(error)); report(); });
  return result;
};
setInterval(report, 1000);
