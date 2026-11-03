const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

async function main() {
  const executable = process.argv[2];
  assert.ok(executable, "Usage: node Tests/ConverterRepackTests.cjs CONVERTER");
  const converter = path.resolve(executable);
  const lz4Source = fs.readFileSync(path.join(__dirname, "../web/src/lz4.js"), "utf8");
  const { decodeAppleLZ4 } = await import(`data:text/javascript;base64,${Buffer.from(lz4Source).toString("base64")}`);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "borgvr-cli-repack-"));
  const filename = name => path.join(root, name);
  let sequence = 0;

  function run(args, success = true) {
    const result = spawnSync(converter, args, { encoding: "utf8", timeout: 60000, maxBuffer: 16 * 1024 * 1024 });
    const details = `${args.join(" ")}\n${result.stdout || ""}\n${result.stderr || ""}`;
    assert.ifError(result.error);
    assert.equal(result.signal, null, details);
    assert.equal(result.status === 0, success, details);
    return result;
  }

  function int64(value) {
    const bytes = Buffer.alloc(8); bytes.writeBigInt64LE(BigInt(value)); return bytes;
  }
  function string(value) {
    const bytes = Buffer.from(value, "utf8"); return Buffer.concat([int64(bytes.length), bytes]);
  }
  function textBlock(bytes) {
    return Buffer.concat([Buffer.from([0]), int64(bytes.length), int64(bytes.length), bytes]);
  }

  // Parse just v5's unsigned metadata; brick offsets remain absolute file offsets.
  function metadata(file) {
    const bytes = fs.readFileSync(file), base = Number(bytes.readBigUInt64LE());
    assert.ok(base >= 8 && base < bytes.length, "Invalid metadata offset");
    assert.equal(bytes.readBigInt64LE(base + 6), 5n, "Expected current v5 fixture");
    const dimensions = [14, 22, 30].map(offset => Number(bytes.readBigInt64LE(base + offset)));
    const channels = Number(bytes.readBigInt64LE(base + 38));
    const width = Number(bytes.readBigInt64LE(base + 46));
    assert.equal(bytes[base + 54], 0, "Fixture must use unsigned components");
    const interpretation = bytes[base + 55];
    const spacingBytes = bytes.subarray(base + 56, base + 68);
    const brickSize = Number(bytes.readBigInt64LE(base + 68));
    const overlap = Number(bytes.readBigInt64LE(base + 76));
    let offset = base + 84;
    function integer() { const value = Number(bytes.readBigInt64LE(offset)); offset += 8; return value; }
    function scalar() { const value = bytes.readUIntLE(offset, width); offset += width; return value; }
    function range() { return [scalar(), scalar()]; }
    function readString() { const count = integer(); const text = bytes.toString("utf8", offset, offset + count); offset += count; return text; }
    function block() {
      const codec = bytes[offset++], raw = integer(), stored = integer();
      assert.ok(codec === 0 || codec === 1, "Unknown metadata text codec");
      const payload = bytes.subarray(offset, offset + stored); offset += stored;
      const decoded = codec ? Buffer.from(decodeAppleLZ4(payload, raw)) : payload;
      assert.equal(decoded.length, raw); return decoded;
    }
    const aggregate = interpretation === 0 ? range() : null;
    const rangeCount = interpretation === 0 ? integer() : [2, 4, 6].includes(interpretation) ? 1 : 0;
    const ranges = Array.from({ length: rangeCount }, range);
    const compression = bytes[offset++];
    assert.ok(compression === 0 || compression === 1);
    const stringsStart = offset;
    const uuid = readString(), description = readString(), metaDescription = readString();
    const history = block();
    let historyOffset = 8;
    const provenance = Array.from({ length: Number(history.readBigUInt64LE()) }, () => {
      const time = Number(history.readBigInt64LE(historyOffset)); historyOffset += 8;
      const length = Number(history.readBigInt64LE(historyOffset)); historyOffset += 8;
      const text = history.toString("utf8", historyOffset, historyOffset + length); historyOffset += length;
      return { time, text };
    });
    assert.equal(historyOffset, history.length);
    const meta = block().toString("utf8"), tailStart = offset;
    const brickCount = integer(), brickDataOffset = integer();
    assert.equal(brickDataOffset, 0, "Expected self-contained dataset");
    const bricks = Array.from({ length: brickCount }, () => {
      const position = integer(), size = integer();
      const aggregate = interpretation === 0 ? range() : null;
      const ranges = Array.from({ length: rangeCount }, range);
      assert.ok(position >= 8 && size > 0 && position + size <= base, "Invalid brick payload address");
      return { position, size, aggregate, ranges };
    });
    assert.equal(offset, bytes.length, "Unexpected trailing metadata");
    return { bytes, base, dimensions, channels, width, interpretation, spacingBytes, brickSize, overlap,
      aggregate, ranges, compression, stringsStart, uuid, description, metaDescription, provenance, meta,
      tailStart, brickCount, bricks };
  }

  function enrich(file) {
    const original = metadata(file);
    const description = "Repack reference: Schädel / 血管";
    const metaDescription = "Independent channels, odd dimensions\nsecond description line";
    const meta = '{"scanner":"test","opaque":"<tag> café \\u0000 </tag>"}\nExact metadata\r\n';
    const entries = [
      { time: Date.parse("2024-01-02T03:04:05.123Z"), text: "Acquired at scanner" },
      { time: Date.parse("2025-02-03T00:00:00Z"), text: "date only: 2025-02-03; anonymized" },
      ...original.provenance
    ];
    const history = Buffer.concat([int64(entries.length), ...entries.flatMap(entry => [int64(entry.time), string(entry.text)])]);
    fs.writeFileSync(file, Buffer.concat([original.bytes.subarray(0, original.stringsStart),
      string(original.uuid), string(description), string(metaDescription), textBlock(history),
      textBlock(Buffer.from(meta)), original.bytes.subarray(original.tailStart)]));
    const patched = metadata(file);
    assert.equal(patched.description, description); assert.equal(patched.metaDescription, metaDescription);
    assert.equal(patched.meta, meta); assert.deepEqual(patched.provenance, entries);
    return patched;
  }

  function exported(input, level = 0) {
    const output = filename(`export-${sequence++}.nrrd`);
    run(["E", input, output, String(level)]);
    const bytes = fs.readFileSync(output), end = bytes.indexOf("\n\n");
    assert.ok(end >= 0, "Expected inline NRRD export");
    const header = bytes.toString("utf8", 0, end);
    assert.match(header, /(?:^|\n)encoding:\s*raw(?:\n|$)/);
    return { header, payload: bytes.subarray(end + 2) };
  }

  function preserved(before, after, started) {
    assert.notEqual(after.uuid, before.uuid, "Repack reused the source UUID");
    assert.match(after.uuid, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
    for (const key of ["description", "metaDescription", "meta", "channels"]) {
      assert.equal(after[key], before[key], `${key} was not preserved`);
    }
    assert.deepEqual(after.dimensions, before.dimensions);
    assert.deepEqual(after.spacingBytes, before.spacingBytes, "Voxel spacing changed");
    assert.deepEqual(after.provenance.slice(0, before.provenance.length), before.provenance,
      "Original provenance prefix was lost, reordered, or changed");
    const appended = after.provenance.slice(before.provenance.length);
    assert.ok(appended.length > 0, "Repack did not append provenance");
    assert.ok(appended.some(entry => /repack/i.test(entry.text)), "Missing repack operation entry");
    assert.ok(appended.some(entry => /BorgVR Converter\s+\d+\.\d+/i.test(entry.text)), "Missing converter/version identification");
    appended.forEach(entry => assert.ok(entry.time >= started && entry.time <= Date.now(), "Invalid repack timestamp"));
  }

  function checkBrickRanges(data) {
    const fullBytes = data.brickSize ** 3 * data.channels * data.width;
    for (const brick of data.bricks) {
      const stored = data.bytes.subarray(brick.position, brick.position + brick.size);
      const raw = data.compression && stored.length < fullBytes ? Buffer.from(decodeAppleLZ4(stored, fullBytes)) : stored;
      assert.equal(raw.length, fullBytes, "Wrong regenerated brick size");
      const ranges = Array.from({ length: data.channels }, () => [Infinity, -Infinity]);
      for (let offset = 0, index = 0; offset < raw.length; offset += data.width, index++) {
        const value = raw.readUIntLE(offset, data.width), range = ranges[index % data.channels];
        range[0] = Math.min(range[0], value); range[1] = Math.max(range[1], value);
      }
      const expected = data.interpretation === 0 ? ranges : data.interpretation === 2 ? [ranges[3]] : [];
      assert.deepEqual(brick.ranges, expected, "Regenerated per-brick ranges disagree with actual samples");
      if (data.interpretation === 0) {
        assert.deepEqual(brick.aggregate, [Math.min(...ranges.map(range => range[0])), Math.max(...ranges.map(range => range[1]))]);
      }
    }
  }

  try {
    const dimensions = [9, 7, 5], count = dimensions.reduce((a, b) => a * b), raw = Buffer.alloc(count * 4);
    const values = Array.from({ length: count }, (_, index) => [
      (index * 73) % 4096, 1000 + (index * 113) % 30000
    ]);
    values[0] = [0, 1000]; values[count - 1] = [4095, 31000];
    values.forEach((voxel, index) => voxel.forEach((value, channel) => raw.writeUInt16LE(value, index * 4 + channel * 2)));
    const nrrd = filename("odd-anisotropic.nrrd"), source = filename("source.data");
    fs.writeFileSync(nrrd, Buffer.concat([Buffer.from("NRRD0005\ntype: uint16\ndimension: 4\nsizes: 2 9 7 5\n"
      + "spacings: nan 0.00125 0.0025 0.004\nkinds: vector domain domain domain\nendian: little\nencoding: raw\n\n"), raw]));
    run(["N", nrrd, source, "Initial fixture", "4", "1"]);
    const before = enrich(source), sourceBytes = fs.readFileSync(source);
    assert.deepEqual(exported(source).payload, raw, "Fixture import is not lossless");
    const coarse = exported(source, 1).payload;

    for (const [name, brickSize, overlap, options, compression] of [
      ["default", 8, 1, [], 1],
      ["zero-overlap", 4, 0, ["--no-lz4"], 0],
      ["large-bricks", 16, 2, ["--no-lz4", "--color-compression", "none"], 0]
    ]) {
      const output = filename(`${name}.data`), started = Date.now();
      run(["R", source, output, String(brickSize), String(overlap), ...options]);
      const after = metadata(output);
      preserved(before, after, started);
      assert.equal(after.interpretation, 0); assert.equal(after.width, 2);
      assert.equal(after.brickSize, brickSize); assert.equal(after.overlap, overlap);
      assert.equal(after.compression, compression);
      assert.notEqual(after.brickCount, before.brickCount, "Derived brick layout was reused");
      assert.deepEqual(after.ranges, [[0, 4095], [1000, 31000]]);
      assert.deepEqual(exported(output).payload, raw, "Full-resolution samples changed across brick boundaries");
      if (after.brickCount > 1) {
        assert.deepEqual(exported(output, 1).payload, coarse, "Derived LoD was not regenerated consistently");
      }
      checkBrickRanges(after);
      assert.deepEqual(fs.readFileSync(source), sourceBytes, "Repack modified source");
    }

    const quantized = filename("quantized.data"), started = Date.now();
    run(["R", source, quantized, "8", "1", "--quantize-8bit", "--no-lz4"]);
    const quantizedMetadata = metadata(quantized);
    preserved(before, quantizedMetadata, started);
    assert.equal(quantizedMetadata.width, 1); assert.equal(quantizedMetadata.interpretation, 0);
    assert.deepEqual(quantizedMetadata.ranges, [[0, 255], [0, 255]]);
    const expected = Buffer.from(values.flatMap(voxel => voxel.map((value, channel) => {
      const minimum = channel === 0 ? 0 : 1000, range = channel === 0 ? 4095 : 30000;
      return Math.floor(((value - minimum) * 255 + Math.floor(range / 2)) / range);
    })));
    const quantizedExport = exported(quantized);
    assert.match(quantizedExport.header, /type:\s*uint8/);
    assert.deepEqual(quantizedExport.payload, expected, "Quantization was not independent linear min/max mapping");
    checkBrickRanges(quantizedMetadata);

    for (const channels of [3, 4]) {
      const color = Buffer.from(Array.from({ length: count * channels }, (_, index) => (index * 37 + 19) % 256));
      const input = filename(`color-${channels}.${channels === 4 ? "dat" : "nrrd"}`);
      const colorSource = filename(`color-${channels}.data`);
      if (channels === 4) {
        fs.writeFileSync(filename("rgba.raw"), color);
        fs.writeFileSync(input, "ObjectFileName: rgba.raw\nResolution: 9 7 5\nSliceThickness: 0.00125 0.0025 0.004\nFormat: UCHAR4\nObjectModel: RGBA\nEndianess: LITTLE\n");
      } else {
        fs.writeFileSync(input, Buffer.concat([Buffer.from("NRRD0005\ntype: uint8\ndimension: 4\nsizes: 3 9 7 5\n"
          + "spacings: nan 0.00125 0.0025 0.004\nkinds: RGB-color domain domain domain\nencoding: raw\n\n"), color]));
      }
      const mode = channels === 4 ? "Q" : "N";
      run([mode, input, colorSource, "Color fixture", "8", "1"]);
      const colorBefore = enrich(colorSource), unchanged = fs.readFileSync(colorSource);
      assert.equal(colorBefore.interpretation, channels === 4 ? 2 : 1, "Fixture lost color interpretation");
      const output = filename(`color-${channels}-repacked.data`), started = Date.now();
      run(["R", colorSource, output, "4", "0", "--color-compression", "none"]);
      const after = metadata(output);
      preserved(colorBefore, after, started);
      assert.equal(after.interpretation, colorBefore.interpretation); assert.equal(after.compression, 1);
      assert.deepEqual(exported(output).payload, color, "Color components or alpha changed");
      checkBrickRanges(after);
      assert.deepEqual(fs.readFileSync(colorSource), unchanged);

      // Opt in where the converter has a usable Metal ASTC encoder.
      if (process.env.BORGVR_TEST_ASTC === "1") {
        for (const block of [4, 8]) {
          const astc = filename(`color-${channels}-astc${block}.data`);
          run(["R", colorSource, astc, "8", "1", "--no-lz4", "--color-compression", `astc${block}x${block}`]);
          const encoded = metadata(astc);
          assert.equal(encoded.interpretation, (block === 4 ? 3 : 5) + (channels === 4 ? 1 : 0));
          const decoded = exported(astc).payload;
          assert.equal(decoded.length, color.length);
          const plain = filename(`color-${channels}-decoded${block}.data`), started = Date.now();
          run(["R", astc, plain, "4", "0"]);
          const plainMetadata = metadata(plain);
          preserved(encoded, plainMetadata, started);
          assert.equal(plainMetadata.interpretation, colorBefore.interpretation, "Default repack retained ASTC");
          assert.deepEqual(exported(plain).payload, decoded, "Repacking stored ASTC altered decoded samples");
          checkBrickRanges(plainMetadata);
        }
      }
    }

    const sentinel = Buffer.from("Existing destination must survive failed repack\n");
    const protectedOutput = filename("protected.data"), invalidSource = filename("bad.data");
    fs.writeFileSync(invalidSource, Buffer.from("not a BorgVR dataset"));
    const failures = [
      ["R"], ["R", source], ["R", source, protectedOutput], ["R", source, protectedOutput, "8"],
      ...[["0", "0"], ["-1", "0"], ["eight", "1"], ["8", "-1"], ["8", "4"], ["8", "5"], ["8", "bad"]]
        .map(tail => ["R", source, protectedOutput, ...tail]),
      ...[["--color-compression"], ["--color-compression", "invalid"], ["--unknown-option"]]
        .map(tail => ["R", source, protectedOutput, "8", "1", ...tail]),
      ["R", filename("missing.data"), protectedOutput, "8", "1"],
      ["R", invalidSource, protectedOutput, "8", "1"]
    ];
    for (const args of failures) {
      fs.writeFileSync(protectedOutput, sentinel);
      run(args, false);
      assert.deepEqual(fs.readFileSync(protectedOutput), sentinel, "Rejected repack clobbered destination");
      assert.deepEqual(fs.readFileSync(source), sourceBytes, "Rejected repack modified source");
    }
    const absent = filename("must-not-exist.data");
    run(["R", invalidSource, absent, "8", "1"], false);
    assert.ok(!fs.existsSync(absent), "Bad source left an output file");
    const truncated = filename("truncated.data");
    fs.writeFileSync(truncated, sourceBytes.subarray(0, before.base + 10));
    run(["R", truncated, protectedOutput, "8", "1"], false);
    assert.deepEqual(fs.readFileSync(protectedOutput), sentinel, "Truncated source clobbered destination");

    const alias = filename("source-alias.data"); fs.symlinkSync(source, alias);
    const directoryAlias = filename("directory-alias"); fs.symlinkSync(root, directoryAlias, "dir");
    for (const [input, output] of [[source, source], [source, alias], [alias, source],
      [source, path.join(root, "..", path.basename(root), "source.data")],
      [source, path.join(directoryAlias, "source.data")]]) {
      run(["R", input, output, "8", "1"], false);
      assert.deepEqual(fs.readFileSync(source), sourceBytes, "Same-file repack destroyed source");
      assert.equal(fs.lstatSync(alias).isSymbolicLink(), true, "Rejected repack replaced source symlink");
    }
    console.log("DATA repack: layout/LoDs/ranges, LZ4, overlap zero, per-channel quantization, metadata/history, RGB/RGBA and safe failures passed."
      + (process.env.BORGVR_TEST_ASTC === "1" ? " ASTC round-trips passed." : " ASTC cases opt-in: BORGVR_TEST_ASTC=1."));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
