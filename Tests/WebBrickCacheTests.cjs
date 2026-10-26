const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

async function main() {
  const records = new Map();
  const requests = [];
  let networkData = new Uint8Array(8).fill(42);
  const db = {
    close() {},
    transaction() {
      const transaction = { objectStore: () => ({ delete: (key) => records.delete(key) }) };
      queueMicrotask(() => transaction.oncomplete?.());
      return transaction;
    }
  };
  const cfg = {
    baseURL: "http://localhost/", bricks: [{ index: 0 }, { index: 1 }],
    persistentCacheEnabled: true, cacheNamespace: "test", cacheEpoch: 1,
    datasetCompression: "none", uncompressedBrickByteLength: 8
  };
  const context = vm.createContext({
    self: { addEventListener() {}, postMessage() {}, indexedDB: {} },
    performance, URL, Uint8Array, ArrayBuffer, DataView, Map, Set, console, cfg,
    fetch: async (url) => {
      requests.push(url.href);
      return { ok: true, arrayBuffer: async () => networkData.buffer };
    }
  });
  const source = fs.readFileSync(path.join(__dirname, "../web/src/brick-worker.js"), "utf8")
    .replace(/^import .*;\n/, "");
  vm.runInContext(source, context);
  context.testDB = db;
  context.testRecords = records;
  vm.runInContext(`
    config = cfg;
    openPersistentCacheDB = async () => testDB;
    idbGet = async (_, key) => testRecords.get(key);
    idbGetMany = async (_, keys) => keys.map(key => testRecords.get(key));
    idbPutMany = async (_, entries) => { for (const entry of entries) testRecords.set(entry.key, entry); };
  `, context);
  const fetchSingle = () => vm.runInContext("fetchSingleBrick(config, 0, createProfile())", context);
  records.set("test|0", { data: new Uint8Array([1]).buffer });
  assert.equal((await fetchSingle()).get(0)[0], 42);
  assert.equal(requests.length, 1, "Corrupt cache did not refetch");
  assert.equal(records.get("test|0").data.byteLength, 8, "Refetch did not repair cache");
  await fetchSingle();
  assert.equal(requests.length, 1, "Healthy cache unnecessarily fetched again");

  records.delete("test|0");
  networkData = new Uint8Array([1]);
  await assert.rejects(fetchSingle());
  assert.equal(records.has("test|0"), false, "Invalid response poisoned the persistent cache");

  records.set("test|0", { data: new Uint8Array(8).fill(7).buffer });
  records.set("test|1", { data: new Uint8Array([1]).buffer });
  const batch = new Uint8Array(28);
  const view = new DataView(batch.buffer);
  view.setUint32(0, 0x31425642, true); view.setUint32(4, 1, true);
  view.setUint32(8, 1, true); view.setUint32(12, 20, true); view.setUint32(16, 8, true);
  batch.fill(99, 20);
  networkData = batch;
  const result = await vm.runInContext("fetchBatchBricks(config, [0, 1], createProfile())", context);
  assert.equal(result.get(0)[0], 7, "Recovery changed a healthy neighbor");
  assert.equal(result.get(1)[0], 99);
  assert.equal(new URL(requests.at(-1)).searchParams.get("ids"), "1", "Batch refetched healthy cached bricks");
  console.log("WebGPU persistent brick-cache recovery tests passed");
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
