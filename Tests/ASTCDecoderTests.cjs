const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

(async () => {
  const source = fs.readFileSync(path.join(__dirname, "../web/src/astc.js"), "utf8");
  const { decodeASTCBrick, colorInterpretation, astcBlockSize } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
  const directory = process.argv[2];
  const fixtures = fs.readdirSync(directory).filter(name => name.endsWith(".json"));
  assert.equal(fixtures.length, 20);
  for (const name of fixtures) {
    const fixture = JSON.parse(fs.readFileSync(path.join(directory, name)));
    const encoded = new Uint8Array(Buffer.from(fixture.encoded, "base64"));
    const actual = decodeASTCBrick(encoded, fixture.side, fixture.components, fixture.block);
    assert.deepEqual(Buffer.from(actual), Buffer.from(fixture.decoded, "base64"), name);
  }
  for (const color of ["rgb", "rgba"]) for (const block of [4, 8]) {
    assert.equal(colorInterpretation(`${color}ASTC${block}x${block}`), color);
    assert.equal(astcBlockSize(`${color}ASTC${block}x${block}`), block);
  }
  assert.throws(() => decodeASTCBrick(new Uint8Array(1), 8, 4, 8));
  assert.throws(() => decodeASTCBrick(new Uint8Array(128), 8, 4, 8));
  console.log("ASTC WebGPU software decoding matches Swift for all Metal-validated 4x4/8x8 fixtures; malformed blocks rejected");
})().catch(error => { console.error(error); process.exitCode = 1; });
