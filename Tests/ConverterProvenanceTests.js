const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

async function main() {
  const converter = process.argv[2];
  assert.ok(converter, "Usage: node Tests/ConverterProvenanceTests.js CONVERTER");
  const lz4Source = fs.readFileSync(path.join(__dirname, "../web/src/lz4.js"), "utf8");
  const { decodeAppleLZ4 } = await import(`data:text/javascript;base64,${Buffer.from(lz4Source).toString("base64")}`);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "borgvr-cli-provenance-"));
  try {
    const source = path.join(root, "tiny.nrrd");
    fs.writeFileSync(source, Buffer.concat([Buffer.from("NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 2 2\nspacings: 1 1 1\nencoding: raw\n\n"), Buffer.from([0, 1, 2, 3, 4, 5, 6, 7])]));
    function run(extra, output = "result.data", ok = true) {
      const args = ["N", source, path.join(root, output), "Provenance test", "8", "1", ...extra];
      const result = spawnSync(converter, args, { encoding: "utf8" });
      assert.equal(result.status === 0, ok, result.stdout + result.stderr);
      return path.join(root, output);
    }
    function readHistory(file) {
      const bytes = fs.readFileSync(file), base = Number(bytes.readBigUInt64LE());
      assert.equal(bytes.readBigInt64LE(base + 6), 5n);
      const channels = Number(bytes.readBigInt64LE(base + 38));
      const width = Number(bytes.readBigInt64LE(base + 46));
      let offset = base + 92 + (2 + 2 * channels) * width;
      function readString(buffer) {
        const count = Number(buffer.readBigInt64LE(offset)); offset += 8;
        const text = buffer.subarray(offset, offset + count).toString("utf8"); offset += count;
        return text;
      }
      for (let i = 0; i < 3; ++i) readString(bytes);
      const codec = bytes[offset], raw = Number(bytes.readBigUInt64LE(offset + 1));
      const stored = Number(bytes.readBigUInt64LE(offset + 9));
      const payload = bytes.subarray(offset + 17, offset + 17 + stored);
      const block = codec ? Buffer.from(decodeAppleLZ4(payload, raw)) : payload;
      offset = 8;
      const count = Number(block.readBigUInt64LE());
      return Array.from({ length: count }, () => {
        const time = Number(block.readBigInt64LE(offset)); offset += 8;
        return { time, text: readString(block) };
      });
    }
    const started = Date.now();
    const file = run(["--source-info", "2026-11-01T12:30:45.123+02:00", "Downloaded from https://example.org/scan"]);
    const history = readHistory(file);
    assert.deepEqual(history[0], { time: 1793529045123, text: "Downloaded from https://example.org/scan" });
    assert.match(history.at(-1).text, /^converted by BorgVR Converter 3\.5 /);
    assert.ok(history.at(-1).time >= started && history.at(-1).time <= Date.now());
    assert.ok(readHistory(run([], "no-source.data")).at(-1).text.startsWith("converted by "));
    const multiple = readHistory(run([
      "--source-info", "2026-10-01T08:00:00Z", "Acquired at scanner",
      "--source-info", "2026-10-02T11:00:00+02:00", "Anonymized",
      "--source-info", "2026-10-03T12:30:45.123Z", "Downloaded from archive"
    ], "multiple.data"));
    assert.deepEqual(multiple.slice(0, 3), [
      { time: Date.parse("2026-10-01T08:00:00Z"), text: "Acquired at scanner" },
      { time: Date.parse("2026-10-02T11:00:00+02:00"), text: "Anonymized" },
      { time: Date.parse("2026-10-03T12:30:45.123Z"), text: "Downloaded from archive" }
    ]);
    assert.match(multiple.at(-1).text, /^converted by BorgVR Converter 3\.5 /);
    run(["--source-info", "invalid", "source"], "bad-date.data", false);
    run(["--source-info", "2026-11-01T12:00:00Z", ""], "empty-text.data", false);
    run(["--source-info"], "missing.data", false);
    for (const tail of [["--source-info"], ["--source-info", "invalid", "source"], ["--source-info", "2026-11-01T12:00:00Z", "   "]]) {
      const output = "invalid-history.data";
      run(["--source-info", "2026-11-01T12:00:00Z", "Valid first entry", ...tail], output, false);
      assert.ok(!fs.existsSync(path.join(root, output)), "Invalid history created an output file");
    }
    const rejectedExport = spawnSync(converter, ["E", file, path.join(root, "export.nrrd"), "0", "--source-info", "2026-11-01T12:00:00Z", "source"], { encoding: "utf8" });
    assert.notEqual(rejectedExport.status, 0);
    assert.match(rejectedExport.stdout + rejectedExport.stderr, /not applicable to export/);
    const dicomDirectory = path.join(root, "dicom");
    fs.mkdirSync(dicomDirectory);
    function element(group, tag, vr, value) {
      let payload = Buffer.isBuffer(value) ? value : Buffer.from(value);
      if (payload.length % 2) payload = Buffer.concat([payload, Buffer.from([32])]);
      const header = Buffer.alloc(8);
      header.writeUInt16LE(group); header.writeUInt16LE(tag, 2);
      header.write(vr, 4); header.writeUInt16LE(payload.length, 6);
      return Buffer.concat([header, payload]);
    }
    function uint16(value) { const bytes = Buffer.alloc(2); bytes.writeUInt16LE(value); return bytes; }
    fs.writeFileSync(path.join(dicomDirectory, "slice.dcm"), Buffer.concat([
      Buffer.alloc(128), Buffer.from("DICM"), element(2, 0x10, "UI", "1.2.840.10008.1.2.1\0"),
      element(8, 0x2a, "DT", "20261101123045.123+0200"),
      element(8, 0x23, "DA", "20261102"), element(8, 0x2111, "ST", "Reconstructed from scan"),
      ...[[0x10, 2], [0x11, 2], [2, 1], [0x100, 8], [0x101, 8], [0x103, 0]]
        .map(([tag, value]) => element(0x28, tag, "US", uint16(value))),
      element(0x7fe0, 0x10, "US", Buffer.from([0, 20, 40, 60]))
    ]));
    const dicomOutput = path.join(root, "dicom.data");
    const dicomResult = spawnSync(converter, ["D", dicomDirectory, dicomOutput, "DICOM history test", "8", "1"], { encoding: "utf8" });
    assert.equal(dicomResult.status, 0, dicomResult.stdout + dicomResult.stderr);
    const dicomHistory = readHistory(dicomOutput);
    assert.ok(dicomHistory.some(entry => entry.time === 1793529045123 && entry.text.includes("DICOM acquisition")));
    assert.ok(dicomHistory.some(entry => entry.time === Date.parse("2026-11-02T00:00:00Z") && entry.text.includes("date only: 2026-11-02") && entry.text.includes("Reconstructed from scan")));
    assert.equal(dicomHistory.filter(entry => entry.text.startsWith("Import DICOM:")).length, 1);
    const nrrdOutput = path.join(root, "export.nrrd");
    const exportResult = spawnSync(converter, ["E", dicomOutput, nrrdOutput, "0"], { encoding: "utf8" });
    assert.equal(exportResult.status, 0, exportResult.stdout + exportResult.stderr);
    const nrrd = fs.readFileSync(nrrdOutput);
    const header = nrrd.subarray(0, nrrd.indexOf("\n\n")).toString("ascii");
    const prefix = "# BorgVR provenance: ";
    const exportedHistory = header.split("\n").filter(line => line.startsWith(prefix)).map(line => JSON.parse(line.slice(prefix.length)));
    assert.deepEqual(exportedHistory.slice(0, -1).map(entry => ({ time: entry.timestampMilliseconds, text: entry.text })), dicomHistory);
    assert.ok(exportedHistory.at(-1).text.startsWith("Exported to NRRD"));
    console.log("CLI provenance date/time, repeated sources in order, automatic tool/version history, and argument validation passed.");
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
