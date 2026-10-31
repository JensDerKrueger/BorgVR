const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

async function port() {
  const listener = net.createServer().listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const result = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return result;
}

function catalog(port) {
  return new Promise((resolve, reject) => {
    const request = http.get({ hostname: '127.0.0.1', port, path: '/web-data/datasets.json', agent: false }, response => {
      let body = '';
      response.on('data', data => { body += data; });
      response.on('end', () => {
        try { assert.equal(response.statusCode, 200); resolve(JSON.parse(body)); }
        catch (error) { reject(error); }
      });
    });
    request.on('error', reject);
    request.setTimeout(1000, () => request.destroy(new Error('HTTP timeout')));
  });
}

function dicom() {
  function element(group, tag, vr, value) {
    if (typeof value === 'number') { const bytes = Buffer.alloc(2); bytes.writeUInt16LE(value); value = bytes; }
    if (typeof value === 'string') value = Buffer.from(value + (value.length % 2 ? (vr === 'UI' ? '\0' : ' ') : ''));
    const long = vr === 'OW';
    const header = Buffer.alloc(long ? 12 : 8);
    header.writeUInt16LE(group); header.writeUInt16LE(tag, 2); header.write(vr, 4);
    if (long) header.writeUInt32LE(value.length, 8); else header.writeUInt16LE(value.length, 6);
    return Buffer.concat([header, value]);
  }
  return Buffer.concat([Buffer.alloc(128), Buffer.from('DICM'),
    element(2, 0x10, 'UI', '1.2.840.10008.1.2.1'),
    element(8, 0x60, 'CS', 'CT'), element(0x18, 0x50, 'DS', '1'),
    element(0x20, 0x0e, 'UI', '1.2.3'), element(0x20, 0x13, 'IS', '1'),
    element(0x20, 0x32, 'DS', '0\\0\\0'), element(0x20, 0x37, 'DS', '1\\0\\0\\0\\1\\0'),
    element(0x28, 2, 'US', 1), element(0x28, 4, 'CS', 'MONOCHROME2'),
    element(0x28, 0x10, 'US', 2), element(0x28, 0x11, 'US', 2),
    element(0x28, 0x30, 'DS', '1\\1'), element(0x28, 0x100, 'US', 16),
    element(0x28, 0x101, 'US', 16), element(0x28, 0x102, 'US', 15),
    element(0x28, 0x103, 'US', 0), element(0x7fe0, 0x10, 'OW', Buffer.from([10,0,20,0,30,0,40,0]))]);
}

async function run() {
  assert.ok(process.argv[2], 'Pass the built TerminalServerApp executable');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'borgvr-auto-import-integration-'));
  const input = path.join(root, 'inbox'), output = path.join(root, 'datasets');
  fs.mkdirSync(input); fs.mkdirSync(output);
  fs.writeFileSync(path.join(input, 'scan.nrrd'), Buffer.concat([
    Buffer.from('NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 2 2\nspacings: 1 1 1\nencoding: raw\n\n'),
    Buffer.from([0,1,2,3,4,5,6,7]) ]));
  fs.mkdirSync(path.join(input, 'dicom-series'));
  fs.writeFileSync(path.join(input, 'dicom-series', 'slice.dcm'), dicom());
  fs.writeFileSync(path.join(input, 'dicom-series', 'unrelated.txt'), 'must remain');
  fs.writeFileSync(path.join(input, 'invalid.txt'), 'not a volume');
  const webPort = await port();
  let nativePort = await port();
  while (nativePort === webPort) nativePort = await port();
  const environment = { ...process.env }; delete environment.BORGVR_SERVER_PASSWORD;
  const server = spawn(process.argv[2], ['-d', output, '-p', String(nativePort), '--web-port', String(webPort),
    '--web-http', '--scan-interval', '0', '--auto-import', input, '--auto-import-interval', '0.1'], { env: environment });
  let logs = '';
  server.stdout.on('data', bytes => { logs += bytes; });
  server.stderr.on('data', bytes => { logs += bytes; });
  const exited = once(server, 'exit');
  const watchdog = setTimeout(() => server.kill('SIGKILL'), 25000);
  try {
    const deadline = Date.now() + 20000;
    let ready = false;
    while (!ready && Date.now() < deadline) {
      try {
        const datasets = await catalog(webPort);
        ready = JSON.stringify(datasets).includes('scan') && JSON.stringify(datasets).includes('dicom-series') &&
          !fs.existsSync(path.join(input, 'invalid.txt')) && !fs.existsSync(path.join(input, 'dicom-series'));
      } catch {}
      if (!ready) await delay(50);
    }
    assert.ok(ready, `Imported datasets did not enter the catalog: ${logs}`);
    assert.ok(fs.existsSync(path.join(output, 'scan.data')));
    assert.ok(fs.existsSync(path.join(output, 'dicom-series.data')));
    assert.ok(!fs.existsSync(path.join(input, 'scan.nrrd')));
    assert.ok(!fs.existsSync(path.join(input, 'dicom-series', 'slice.dcm')));
    assert.ok(!fs.existsSync(path.join(input, 'dicom-series')));
    assert.ok(!fs.existsSync(path.join(input, 'invalid.txt')));
    const audit = fs.readFileSync(path.join(input, 'log.txt'), 'utf8');
    assert.equal((audit.match(/\[SUCCESS\]/g) || []).length, 2);
    assert.ok(audit.includes('[FAILED] invalid.txt'));
    console.log('CLI auto-import: NRRD, DICOM, live catalog, cleanup, and log.txt passed');
  } finally {
    server.stdin.end('q\n');
    await exited;
    clearTimeout(watchdog);
    fs.rmSync(root, { recursive: true });
  }
  assert.equal(server.exitCode, 0);
}

module.exports = { port, catalog };
if (require.main === module) run().catch(error => { console.error(error); process.exitCode = 1; });
