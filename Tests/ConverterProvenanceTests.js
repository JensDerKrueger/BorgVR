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
    console.log("CLI provenance date/time, repeated sources in order, automatic tool/version history, and argument validation passed.");
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
