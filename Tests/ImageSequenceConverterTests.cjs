const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { deflateSync } = require('node:zlib');
const { spawnSync } = require('node:child_process');

const converter = process.argv[2] || '/private/tmp/borgvr-format5-converter/Build/Products/Release/TerminalConverterApp';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'borgvr-image-cli-'));
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]);
  const length = Buffer.alloc(4), crc = Buffer.alloc(4);
  length.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}
function png(file, rgba, value, width = 2, colors = null) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(2, 4);
  header[8] = 8; header[9] = rgba ? 6 : 2;
  const pixel = rgba ? [value, value, value, 128] : [value, value, value];
  const rows = Array.from({ length: 2 }, (_, y) => Buffer.from([0,
    ...Array.from({ length: width }, (_, x) => colors ? colors[y * width + x] : pixel).flat()]));
  fs.writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))]));
}
function run(args, success = true) {
  const result = spawnSync(converter, args, { encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status === 0, success, `${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
  return result;
}
try {
  for (const rgba of [false, true]) {
    const directory = path.join(root, rgba ? 'rgba' : 'rgb'); fs.mkdirSync(directory);
    png(path.join(directory, '10.png'), rgba, 160);
    const colors = [[40, 20, 10], [255, 0, 0], [0, 255, 0], [0, 0, 255]];
    png(path.join(directory, '02.png'), false, 40, 2, colors); // Mixed slices must promote RGB to RGBA.
    const output = path.join(root, `${rgba}.data`);
    const args = ['S', directory, output, 'Color scan', '4', '1', '0.2', '0.4', '0.6'];
    run(args);
    const data = fs.readFileSync(output), offset = Number(data.readBigUInt64LE());
    assert.equal(data[offset + 55], rgba ? 2 : 1);
    assert.equal(Number(data.readBigInt64LE(offset + 38)), rgba ? 4 : 3);
    assert.ok(Math.abs(data.readFloatLE(offset + 56) - 0.1) < 0.00001);
    if (rgba) assert.deepEqual([...data.subarray(offset + 84, offset + 86)], [128, 255]);
    assert.equal(data[offset + (rgba ? 86 : 84)], 1); // Compression follows only the optional alpha pair.
    const flat = path.join(root, `${rgba}.nrrd`); run(['E', output, flat, '0']);
    const exported = fs.readFileSync(flat), start = exported.indexOf('\n\n') + 2;
    const samples = exported.subarray(start), components = rgba ? 4 : 3;
    assert.equal(samples[0], 40); assert.equal(samples[4 * components], 160);
    assert.deepEqual([...samples.subarray(0, 4 * components)],
      colors.flatMap(color => rgba ? [...color, 255] : color));
    if (rgba) { assert.equal(samples[3], 255); assert.equal(samples[4 * components + 3], 128); }
    png(path.join(directory, '11.png'), rgba, 80, 3);
    run(args, false); assert.deepEqual(fs.readFileSync(output), data);
    fs.unlinkSync(path.join(directory, '11.png'));
    fs.writeFileSync(path.join(directory, '12.png'), 'corrupt'); run(args, false);
    for (const size of ['0', '-1', 'nan', 'inf']) {
      const invalid = [...args]; invalid[7] = size; run(invalid, false);
    }
  }
  assert.match(run(['--help']).stdout, /Mode S/);
  console.log('Image-sequence CLI: RGB/RGBA, mixed alpha, filename order, extents, corrupt slices, atomic output and validation passed.');
} finally { fs.rmSync(root, { recursive: true, force: true }); }
