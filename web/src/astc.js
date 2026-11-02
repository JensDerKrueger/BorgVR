// Sliced ASTC LDR software fallback for the block modes emitted by BorgVR.
// WebGPU does not provide a portable compressed 3D ASTC texture, so decode before upload.
export function colorInterpretation(value = "independentChannels") {
  return value.replace(/ASTC(?:4x4|8x8)$/, "");
}

export function astcBlockSize(value = "") {
  return value.endsWith("ASTC4x4") ? 4 : value.endsWith("ASTC8x8") ? 8 : 0;
}

export function decodeASTCBrick(data, side, components, block) {
  if (!block) return data;
  if (![4, 8].includes(block) || !Number.isInteger(side) || side <= 0 || side % block ||
      ![3, 4].includes(components) || data.byteLength !== (side / block) ** 2 * side * 16) {
    throw new Error("Invalid ASTC brick layout or byte count.");
  }
  const output = new Uint8Array(side ** 3 * components);
  const blocks = side / block, scale = Math.floor((1024 + block / 2) / (block - 1));
  const unquantized = [0, 21, 43, 64];
  for (let z = 0; z < side; z++) for (let by = 0; by < blocks; by++) for (let bx = 0; bx < blocks; bx++) {
    const offset = ((z * blocks + by) * blocks + bx) * 16;
    function bits(start, count) {
      let value = 0;
      for (let bit = 0; bit < count; bit++) value |= ((data[offset + ((start + bit) >> 3)] >> ((start + bit) & 7)) & 1) << bit;
      return value;
    }
    const mode = bits(0, 11), constant = (mode & 0x1ff) === 0x1fc;
    let a = [0, 0, 0, 0], b = [0, 0, 0, 0], gx = 4, gy = 4, planes = 1;
    if (constant) {
      if (mode & 0x200) throw new Error("Unsupported ASTC HDR block.");
      a = a.map((_, c) => Math.floor((bits(64 + c * 16, 16) + 128) / 257));
    } else {
      if (mode === 0x402) { gy = 2; planes = 2; }
      else if (mode === 0x54e) { gx = 2; planes = 2; }
      else if (mode !== 0x42) throw new Error(`Unsupported ASTC software decoding mode: ${mode}.`);
      if (bits(11, 2) !== 0 || bits(13, 4) !== 12 || (planes === 2 && bits(94, 2) !== 3)) {
        throw new Error("Unsupported ASTC endpoint encoding.");
      }
      a = a.map((_, c) => bits(17 + c * 16, 8));
      b = b.map((_, c) => bits(25 + c * 16, 8));
      if (a[0] + a[1] + a[2] > b[0] + b[1] + b[2]) {
        for (const p of [a, b]) { p[0] = (p[0] + p[2]) >> 1; p[1] = (p[1] + p[2]) >> 1; }
        [a, b] = [b, a];
      }
    }
    const weights = Array.from({ length: 16 }, (_, i) => constant ? 0 : unquantized[bits(127 - i * 2, 1) | (bits(126 - i * 2, 1) << 1)]);
    for (let y = 0; y < block; y++) for (let x = 0; x < block; x++) {
      const sx = (scale * x * (gx - 1) + 32) >> 6, sy = (scale * y * (gy - 1) + 32) >> 6;
      const ix = sx >> 4, iy = sy >> 4, fx = sx & 15, fy = sy & 15, w11 = (fx * fy + 8) >> 4;
      const factors = [16 - fx - fy + w11, fx - w11, fy - w11, w11];
      const target = ((z * side + by * block + y) * side + bx * block + x) * components;
      for (let c = 0; c < components; c++) {
        let weight = 8;
        if (!constant) for (let corner = 0; corner < 4; corner++) if (factors[corner]) {
          weight += factors[corner] * weights[((iy + (corner >> 1)) * gx + ix + (corner & 1)) * planes + (planes === 2 && c === 3 ? 1 : 0)];
        }
        output[target + c] = constant ? a[c] : (a[c] * (64 - (weight >> 4)) + b[c] * (weight >> 4) + 32) >> 6;
      }
    }
  }
  return output;
}
