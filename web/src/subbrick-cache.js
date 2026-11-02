import { colorInterpretation } from "./astc.js?v=20261102";

export function subbrickDivisions(brickSize, overlap) {
  if (brickSize <= 16 || overlap <= 0) return 1;
  let divisions = brickSize <= 32 ? 2 : brickSize <= 64 ? 4 : 8;
  while (divisions > Math.max(1, brickSize - 2 * overlap)) divisions /= 2;
  return divisions;
}

export function subbrickVisibility(transferFunctions, biases, renderMode, isoValue, alphaEpsilon = 0, isRGBA = false) {
  const values = new Float32Array(12);
  if (isRGBA) {
    values[8] = Number.isFinite(alphaEpsilon) ? Math.min(1, Math.max(0, alphaEpsilon)) : 0;
    values[11] = 2;
    return values;
  }
  values.fill(Infinity, 0, 4);
  values.fill(-Infinity, 4, 8);
  for (const [channel, tf] of transferFunctions.entries()) {
    if (!tf || tf.minVisibleIndex < 0) continue;
    const scale = tf.width * biases[channel];
    const margin = 8 * 2 ** -23;
    values[channel] = (tf.minVisibleIndex - 0.5) / scale - margin;
    values[4 + channel] = (tf.maxVisibleIndex + 1.5) / scale + margin;
  }
  values[8] = isoValue - 8 * 2 ** -23;
  values[11] = renderMode === 2 ? 1 : 0;
  return values;
}

// Native and browser renderers use the same cell partitions and filter halo.
// Ranges are reduced once per uploaded atlas slot; TF changes only reclassify them.
export class SubbrickCache {
  constructor(device, atlas) {
    this.device = device;
    this.isRGBA = colorInterpretation(atlas.manifest.volume?.channelInterpretation) === "rgba";
    this.channels = this.isRGBA ? 1 : atlas.componentCount;
    this.divisions = subbrickDivisions(atlas.brickSize, atlas.manifest.bricking.overlap);
    this.cells = this.divisions ** 3;
    this.maskStride = 1 + Math.ceil(this.cells / 32);
    this.dirty = new Set();
    this.visibilityKey = null;
    const rangeSize = atlas.slotCapacity * this.cells * this.channels * 8;
    const maskSize = atlas.slotCapacity * this.maskStride * 4;
    const limit = Math.min(device.limits.maxStorageBufferBindingSize, device.limits.maxBufferSize);
    if (rangeSize > limit || maskSize > limit) throw new Error("Subbrick buffers exceed WebGPU limits.");
    this.ranges = device.createBuffer({ label: "Subbrick ranges", size: rangeSize, usage: GPUBufferUsage.STORAGE });
    this.masks = device.createBuffer({ label: "Subbrick occupancy", size: maskSize, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
    this.layout = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.visibility = device.createBuffer({ size: 48, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.ids = device.createBuffer({ size: atlas.slotCapacity * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.reduceIDs = device.createBuffer({ size: atlas.slotCapacity * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(this.layout, 0, new Uint32Array([
      atlas.brickSize, atlas.manifest.bricking.overlap, atlas.brickSize - 2 * atlas.manifest.bricking.overlap,
      this.channels, atlas.atlasBricksPerAxis, this.divisions, this.cells, this.maskStride
    ]));
    const module = device.createShaderModule({ label: "Subbrick reduction/classification", code: subbrickShaderSource });
    this.reduction = device.createComputePipeline({ layout: "auto", compute: {
      module, entryPoint: "reduceSubbricks", constants: { componentBytes: atlas.bytesPerComponent, colorAlpha: this.isRGBA }
    } });
    this.classification = device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: "classifySubbricks" } });
  }

  invalidate(slot) { this.dirty.add(slot); }

  prepare(encoder, atlas, transferFunctions, biases, renderMode, isoValue, alphaEpsilon = 0) {
    const pages = Array.from(atlas.loadedBricks.values());
    const rebuilt = pages.filter(slot => this.dirty.has(slot));
    const visibility = subbrickVisibility(transferFunctions, biases, renderMode, isoValue, alphaEpsilon, this.isRGBA);
    const key = Array.from(visibility).join(",");
    const classified = key === this.visibilityKey ? rebuilt : pages;
    if (!classified.length) return;
    this.device.queue.writeBuffer(this.visibility, 0, visibility);
    this.device.queue.writeBuffer(this.ids, 0, new Uint32Array(classified));
    const pass = encoder.beginComputePass({ label: "Prepare subbrick skipping" });
    if (rebuilt.length) {
      this.device.queue.writeBuffer(this.reduceIDs, 0, new Uint32Array(rebuilt));
      pass.setPipeline(this.reduction);
      pass.setBindGroup(0, this.device.createBindGroup({ layout: this.reduction.getBindGroupLayout(0), entries: [
        { binding: 0, resource: { buffer: this.layout } }, { binding: 1, resource: { buffer: this.reduceIDs, size: rebuilt.length * 4 } },
        { binding: 2, resource: { buffer: this.ranges } }, { binding: 3, resource: atlas.texture.createView() },
        { binding: 4, resource: (atlas.secondaryTexture ?? atlas.texture).createView() }
      ] }));
      const groups = rebuilt.length * this.cells;
      const x = Math.min(groups, this.device.limits.maxComputeWorkgroupsPerDimension);
      pass.dispatchWorkgroups(x, Math.ceil(groups / x));
    }
    pass.setPipeline(this.classification);
    pass.setBindGroup(0, this.device.createBindGroup({ layout: this.classification.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: this.layout } }, { binding: 1, resource: { buffer: this.ids, size: classified.length * 4 } },
      { binding: 2, resource: { buffer: this.ranges } }, { binding: 5, resource: { buffer: this.visibility } },
      { binding: 6, resource: { buffer: this.masks } }
    ] }));
    pass.dispatchWorkgroups(Math.ceil(classified.length / 64));
    pass.end();
    for (const slot of rebuilt) this.dirty.delete(slot);
    this.visibilityKey = key;
  }

  destroy() {
    for (const buffer of [this.ranges, this.masks, this.layout, this.visibility, this.ids, this.reduceIDs]) buffer?.destroy();
  }
}

export const subbrickShaderSource = `
struct Layout { shape: vec4<u32>, grid: vec4<u32> };
struct Visibility { low: vec4<f32>, high: vec4<f32>, iso: vec4<f32> };
@group(0) @binding(0) var<uniform> config: Layout;
@group(0) @binding(1) var<storage, read> pages: array<u32>;
@group(0) @binding(2) var<storage, read_write> ranges: array<vec2<f32>>;
@group(0) @binding(3) var primary: texture_3d<f32>;
@group(0) @binding(4) var secondary: texture_3d<f32>;
@group(0) @binding(5) var<uniform> visibility: Visibility;
@group(0) @binding(6) var<storage, read_write> masks: array<u32>;
override componentBytes: u32 = 1u;
override colorAlpha: bool = false;
var<workgroup> minima: array<vec4<f32>, 64>;
var<workgroup> maxima: array<vec4<f32>, 64>;

@compute @workgroup_size(64)
fn reduceSubbricks(@builtin(workgroup_id) group: vec3<u32>,
  @builtin(num_workgroups) groups: vec3<u32>, @builtin(local_invocation_index) lane: u32) {
  let task = group.x + group.y * groups.x;
  if (task >= arrayLength(&pages) * config.grid.z) { return; }
  let page = pages[task / config.grid.z];
  let cell = task % config.grid.z;
  let divisions = config.grid.y;
  let side = vec3<u32>(cell % divisions, (cell / divisions) % divisions, cell / (divisions * divisions));
  let axis = config.grid.x;
  let origin = vec3<u32>(page % axis, (page / axis) % axis, page / (axis * axis)) * config.shape.x;
  let lo = vec3<i32>(config.shape.y + side * config.shape.z / divisions) - vec3<i32>(1);
  let hi = vec3<i32>(config.shape.y + (side + vec3<u32>(1)) * config.shape.z / divisions);
  let size = vec3<u32>(hi - lo + vec3<i32>(1));
  var low = vec4<f32>(3.402823466e+38);
  var high = -low;
  for (var i = lane; i < size.x * size.y * size.z; i += 64u) {
    let p = vec3<i32>(origin) + lo + vec3<i32>(vec3<u32>(i % size.x, (i / size.x) % size.y, i / (size.x * size.y)));
    var value = textureLoad(primary, p, 0);
    if (colorAlpha) {
      value = vec4<f32>(value.a, 0, 0, 0);
    } else if (componentBytes == 4u) {
      value = vec4<f32>(dot(value, vec4<f32>(1, 256, 65536, 16777216)) / 16843009.0, 0, 0, 0);
    } else if (componentBytes == 2u) {
      let extra = textureLoad(secondary, p, 0);
      value = vec4<f32>(dot(value.xy, vec2<f32>(1, 256)) / 257.0, dot(value.zw, vec2<f32>(1, 256)) / 257.0,
        dot(extra.xy, vec2<f32>(1, 256)) / 257.0, dot(extra.zw, vec2<f32>(1, 256)) / 257.0);
    }
    low = min(low, value); high = max(high, value);
  }
  minima[lane] = low; maxima[lane] = high;
  workgroupBarrier();
  for (var stride = 32u; stride > 0u; stride /= 2u) {
    if (lane < stride) {
      minima[lane] = min(minima[lane], minima[lane + stride]);
      maxima[lane] = max(maxima[lane], maxima[lane + stride]);
    }
    workgroupBarrier();
  }
  if (lane == 0u) {
    for (var c = 0u; c < config.shape.w; c++) {
      ranges[(page * config.grid.z + cell) * config.shape.w + c] = vec2<f32>(minima[0][c], maxima[0][c]);
    }
  }
}

@compute @workgroup_size(64)
fn classifySubbricks(@builtin(global_invocation_id) index: vec3<u32>) {
  if (index.x >= arrayLength(&pages)) { return; }
  let page = pages[index.x];
  var mask = 0u; var count = 0u;
  for (var cell = 0u; cell < config.grid.z; cell++) {
    let iso = visibility.iso.w != 0.0;
    var visible = iso;
    for (var c = 0u; c < config.shape.w; c++) {
      let r = ranges[(page * config.grid.z + cell) * config.shape.w + c];
      if (iso) { visible = visible && r.y >= visibility.iso.x; }
      else { visible = visible || (r.y >= visibility.low[c] && r.x <= visibility.high[c]); }
    }
    if (visibility.iso.w == 2.0) {
      let maximumAlpha = ranges[page * config.grid.z + cell].y;
      visible = maximumAlpha > 0.0 && maximumAlpha >= visibility.iso.x;
    }
    if (visible) { mask |= 1u << (cell & 31u); count++; }
    if ((cell & 31u) == 31u || cell + 1u == config.grid.z) {
      masks[page * config.grid.w + 1u + cell / 32u] = mask; mask = 0u;
    }
  }
  masks[page * config.grid.w] = select(select(0u, 1u, count != 0u), 2u, count == config.grid.z);
}
`;
