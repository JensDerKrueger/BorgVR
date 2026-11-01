const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const converter = process.argv[2];
assert.ok(converter, "Usage: node Tests/ConverterPhysicalSizeTests.cjs CONVERTER");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "borgvr-physical-size-"));
let sequence = 0;
try {
  const raw = Buffer.alloc(24, 10);
  fs.writeFileSync(path.join(root, "voxels.raw"), raw);
  function nrrd(name, spacing) {
    const file = path.join(root, name + ".nrrd");
    fs.writeFileSync(file, Buffer.concat([Buffer.from("NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 3 4\n"
      + (spacing ? "spacings: 2 3 4\n" : "") + "encoding: raw\n\n"), raw]));
    return file;
  }
  function qvis(name, spacing) {
    const file = path.join(root, name + ".dat");
    fs.writeFileSync(file, "ObjectFileName: voxels.raw\nResolution: 2 3 4\nFormat: UCHAR\n"
      + (spacing ? "SliceThickness: 2 3 4\n" : ""));
    return file;
  }
  function zarr(name, physical) {
    const directory = path.join(root, name + ".zarr");
    const array = { zarr_format: 3, node_type: "array", shape: [4, 3, 2], data_type: "uint8",
      dimension_names: ["z", "y", "x"], fill_value: 10,
      chunk_grid: { name: "regular", configuration: { chunk_shape: [4, 3, 2] } },
      chunk_key_encoding: { name: "default", configuration: { separator: "/" } },
      codecs: [{ name: "bytes", configuration: { endian: "little" } }] };
    fs.mkdirSync(directory);
    if (physical) {
      fs.mkdirSync(path.join(directory, "0"));
      fs.writeFileSync(path.join(directory, "0/zarr.json"), JSON.stringify(array));
      fs.writeFileSync(path.join(directory, "zarr.json"), JSON.stringify({ zarr_format: 3, node_type: "group",
        attributes: { ome: { version: "0.5", multiscales: [{
          axes: ["z", "y", "x"].map(name => ({ name, type: "space", unit: "meter" })),
          datasets: [{ path: "0", coordinateTransformations: [{ type: "scale", scale: [4, 3, 2] }] }]
        }] } } }));
    } else { fs.writeFileSync(path.join(directory, "zarr.json"), JSON.stringify(array)); }
    return directory;
  }
  function run(mode, input, options = [], ok = true) {
    const output = path.join(root, `output-${sequence++}.data`);
    const result = spawnSync(converter, [mode, input, output, "Physical size test", "8", "1", ...options], { encoding: "utf8" });
    assert.equal(result.status === 0, ok, result.stdout + result.stderr);
    if (!ok) { assert.ok(!fs.existsSync(output), "Invalid options produced an output file"); return; }
    const bytes = fs.readFileSync(output), base = Number(bytes.readBigUInt64LE());
    const size = [14, 22, 30].map(offset => Number(bytes.readBigInt64LE(base + offset)));
    const spacing = [56, 60, 64].map(offset => bytes.readFloatLE(base + offset));
    return { extent: size.map((value, index) => value * spacing[index]), log: result.stdout + result.stderr };
  }
  function extent(result, expected) {
    result.extent.forEach((value, index) => assert.ok(Math.abs(value - expected[index]) < 1e-6,
      `Extent ${result.extent} differs from ${expected}`));
  }
  for (const [mode, make] of [["N", nrrd], ["Q", qvis], ["Z", zarr]]) {
    const missing = make(`${mode}-relative`, false), known = make(`${mode}-physical`, true);
    extent(run(mode, missing, ["--size-x", "0.2"]), [0.2, 0.3, 0.4]);
    extent(run(mode, known, ["--size-x", "0.2"]), [4, 9, 16]);
    extent(run(mode, known, ["--force-size-x", "0.2"]), [0.2, 0.45, 0.8]);
    extent(run(mode, known), [4, 9, 16]);
    extent(run(mode, missing), [0.5, 0.75, 1]);
  }
  const pvm = path.join(root, "relative.pvm");
  fs.writeFileSync(pvm, Buffer.concat([Buffer.from("PVM2\n2 3 4\n2 3 4\n1\n"), raw]));
  extent(run("P", pvm, ["--size-x", "0.2"]), [0.2, 0.45, 0.8]);
  const i3m = path.join(root, "relative.i3m"), header = Buffer.alloc(32);
  [69426942, 1, 2, 3, 4].forEach((value, index) => header.writeUInt32LE(value, 4 * index));
  [2, 3, 4].forEach((value, index) => header.writeFloatLE(value, 20 + 4 * index));
  fs.writeFileSync(i3m, Buffer.concat([header, Buffer.alloc(24 * 4, 10)]));
  extent(run("I", i3m, ["--size-x", "0.2"]), [0.2, 0.45, 0.8]);
  function dicom(physical) {
    const directory = path.join(root, physical ? "physical-dicom" : "unknown-dicom");
    fs.mkdirSync(directory);
    function element(group, tag, vr, value) {
      let payload = Buffer.isBuffer(value) ? value : Buffer.from(value);
      if (payload.length % 2) payload = Buffer.concat([payload, Buffer.from([32])]);
      const header = Buffer.alloc(8);
      header.writeUInt16LE(group); header.writeUInt16LE(tag, 2);
      header.write(vr, 4); header.writeUInt16LE(payload.length, 6);
      return Buffer.concat([header, payload]);
    }
    function uint16(value) { const bytes = Buffer.alloc(2); bytes.writeUInt16LE(value); return bytes; }
    fs.writeFileSync(path.join(directory, "slice.dcm"), Buffer.concat([
      Buffer.alloc(128), Buffer.from("DICM"), element(2, 0x10, "UI", "1.2.840.10008.1.2.1\0"),
      ...[[0x10, 2], [0x11, 2], [2, 1], [0x100, 8], [0x101, 8], [0x103, 0]]
        .map(([tag, value]) => element(0x28, tag, "US", uint16(value))),
      ...(physical ? [element(0x28, 0x30, "DS", "0.5\\1.5"), element(0x18, 0x50, "DS", "3 ")] : []),
      element(0x7fe0, 0x10, "US", Buffer.from([0, 20, 40, 60]))
    ]));
    return directory;
  }
  extent(run("D", dicom(false), ["--size-x", "0.2"]), [0.2, 0.2, 0.1]);
  const physicalDicom = dicom(true);
  extent(run("D", physicalDicom, ["--size-x", "0.2"]), [0.003, 0.001, 0.003]);
  extent(run("D", physicalDicom, ["--force-size-x", "0.2"]), [0.2, 0.2 / 3, 0.2]);
  const input = nrrd("validation", true);
  for (const flag of ["--size-x", "--force-size-x"]) {
    for (const value of ["0", "-1", "nan", "inf", "invalid"]) run("N", input, [flag, value], false);
    run("N", input, [flag], false);
    run("N", input, [flag, "0.2", flag, "0.3"], false);
  }
  run("N", input, ["--size-x", "0.2", "--force-size-x", "0.3"], false);
  run("E", input, ["--force-size-x", "0.2"], false);
  run("C", input, ["--size-x", "0.2"], false);
  console.log("Physical X-size fallback/override, anisotropic proportions and option validation passed.");
} finally { fs.rmSync(root, { recursive: true, force: true }); }
