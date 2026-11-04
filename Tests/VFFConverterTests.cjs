const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const converter = process.argv[2];
assert.ok(converter, "Usage: node Tests/VFFConverterTests.cjs CONVERTER [VFF ...]");
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "borgvr-vff-conversion-"));
function run(args) {
  const result = spawnSync(converter, args, { encoding: "utf8", timeout: 120000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${args.join(" ")}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}
function check(source, options = [], expectedSizeX) {
  const target = path.join(directory, "volume.data");
  const exported = path.join(directory, "volume.nrrd");
  run(["F", source, target, "VFF roundtrip test", "32", "2", ...options]);
  run(["E", target, exported, "0"]);
  const file = fs.readFileSync(source);
  const delimiter = file.indexOf(12);
  const sourceHeader = file.toString("ascii", 0, delimiter);
  const dimensions = /\bsize=([^;]+);/.exec(sourceHeader)[1].trim().split(/\s+/).map(Number);
  const bits = Number(/\bbits=(\d+);/.exec(sourceHeader)[1]);
  const width = bits / 8;
  let offset = delimiter + 1;
  if (file[offset] === 13) offset++;
  if (file[offset] === 10) offset++;
  const nrrd = fs.readFileSync(exported);
  const headerEnd = nrrd.indexOf("\n\n");
  assert.ok(headerEnd > 0);
  const header = nrrd.toString("utf8", 0, headerEnd);
  const raw = nrrd.subarray(headerEnd + 2);
  assert.equal(raw.length, file.length - offset);
  for (let index = 0; index < raw.length; index += width) {
    const original = file.readUIntBE(offset + index, width);
    const expected = (original ^ (2 ** (bits - 1))) >>> 0;
    assert.equal(raw.readUIntLE(index, width), expected, `Voxel at byte ${index}`);
  }
  if (expectedSizeX !== undefined) {
    const spacingX = Number(/spacings: ([^\n]+)/.exec(header)[1].trim().split(/\s+/)[0]);
    assert.ok(Math.abs(spacingX * dimensions[0] - expectedSizeX) < 0.000001, header);
  }
  assert.match(header, /converted by BorgVR Converter/);
}
try {
  assert.match(run(["--help"]), /F  VFF/);
  const source = path.join(directory, "fixture.vff");
  const raw = Buffer.alloc(3 * 2 * 2 * 2);
  for (let i = 0; i < raw.length / 2; i++) raw.writeInt16BE(-30000 + i * 5000, i * 2);
  const header = "ncaa\ntype=raster;rank=3;bands=1;format=slice;size=3 2 2;bits=16;spacing=1 2 3;elementsize=0.09289;\n\f\n";
  fs.writeFileSync(source, Buffer.concat([Buffer.from(header), raw]));
  check(source, ["--size-x", "0.5"], 3 * 0.00009289);
  check(source, ["--force-size-x", "0.5"], 0.5);
  fs.writeFileSync(source, Buffer.concat([Buffer.from(header.replace("elementsize=0.09289;", "")), raw]));
  check(source, ["--size-x", "0.5"], 0.5);
  for (const file of process.argv.slice(3)) check(file);
  console.log("VFF CLI import/export, exact voxels, physical size, overrides and provenance passed");
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
