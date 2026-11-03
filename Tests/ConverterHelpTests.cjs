const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");

const converter = process.argv[2];
assert.ok(converter, "Usage: node Tests/ConverterHelpTests.cjs CONVERTER");

function run(args) {
  const result = spawnSync(converter, args, { encoding: "utf8", timeout: 10000 });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  assert.doesNotMatch(result.stdout + result.stderr, /\\u\{[a-f\d]+\}/i,
    "Help must contain real line breaks, not log-escaped control characters");
  return result;
}

function checkHelp(text) {
  for (const section of ["USAGE", "MODES", "PARAMETERS", "OPTIONS", "EXAMPLES"]) {
    assert.match(text, new RegExp(`(?:^|\\n)${section}(?:\\n|  )`));
  }
  assert.match(text, /R  Repack/);
  assert.match(text, /--quantize-8bit/);
  assert.match(text, /S <folder> <output\.data> <description> \\\n/,
    "Long command examples need a literal shell continuation followed by a newline");
  assert.ok(text.split("\n").every(line => line.length <= 100),
    "Help lines should fit a normal terminal without uncontrolled wrapping");
}

for (const flag of ["--help", "-h"]) {
  const result = run([flag]);
  assert.equal(result.status, 0);
  assert.equal(result.stderr, "");
  assert.doesNotMatch(result.stdout, /\[ERROR\]|Invalid parameters/);
  checkHelp(result.stdout);
}

for (const args of [[], ["unknown"], ...["D", "S", "Q", "N", "P", "I", "Z", "E", "R", "C"].map(mode => [mode])]) {
  const result = run(args);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /^Error: [^\n]+\n\nUSAGE\n/);
  assert.doesNotMatch(result.stdout, /USAGE|\[ERROR\]/);
  checkHelp(result.stderr);
}

const version = run(["--version"]);
assert.equal(version.status, 0);
assert.match(version.stdout, /Volume Converter \d+\.\d+/);
assert.doesNotMatch(version.stdout, /USAGE/);
console.log("Converter help formatting, output streams, error paths and version output passed.");
