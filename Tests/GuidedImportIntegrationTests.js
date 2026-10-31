const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { port, catalog } = require('./ServerAutoImportIntegrationTests');

async function waitFor(predicate) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    try { if (await predicate()) return; } catch {}
    await delay(25);
  }
  throw new Error('Guided import did not complete');
}

(async () => {
  assert.ok(process.argv[2], 'Pass the built TerminalServerApp executable');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'borgvr-guided-integration-'));
  const input = path.join(root, 'inbox'), output = path.join(root, 'output');
  fs.mkdirSync(input); fs.mkdirSync(output);
  const raw = Buffer.concat([Buffer.from('NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 2 2\nspacings: 1 1 1\nencoding: raw\n\n'),
    Buffer.from([0,1,2,3,4,5,6,7])]);
  fs.writeFileSync(path.join(input, 'scan.nrrd'), raw);
  fs.writeFileSync(path.join(input, 'invalid.bin'), 'not a volume');
  const manifest = path.join(input, 'import.json');
  fs.writeFileSync(manifest, JSON.stringify([
    { source: 'scan.nrrd', destination: 'named.data', description: 'Guided integration', sizeMeters: [0.2, 0.3, 0.4] },
    { source: 'invalid.bin' }
  ]));
  const webPort = await port();
  let nativePort = await port();
  while (nativePort === webPort) nativePort = await port();
  const env = { ...process.env }; delete env.BORGVR_SERVER_PASSWORD;
  const server = spawn(process.argv[2], ['-d', output, '-p', String(nativePort), '--web-port', String(webPort),
    '--web-http', '--scan-interval', '0', '--auto-import', input, '--auto-import-interval', '0.1',
    '--auto-import-mode', 'guided'], { env });
  let logs = '';
  server.stdout.on('data', bytes => { logs += bytes; });
  server.stderr.on('data', bytes => { logs += bytes; });
  const exited = once(server, 'exit');
  const watchdog = setTimeout(() => server.kill('SIGKILL'), 25000);
  let noise = 0;
  const writer = setInterval(() => fs.writeFileSync(path.join(input, 'unlisted.txt'), String(++noise)), 20);
  try {
    await waitFor(async () => !fs.existsSync(manifest) &&
      JSON.stringify(await catalog(webPort)).includes('Guided integration'));
    assert.ok(fs.existsSync(path.join(output, 'named.data')));
    assert.ok(!fs.existsSync(path.join(input, 'invalid.bin')));
    assert.ok(!fs.existsSync(path.join(input, 'scan.nrrd')));
    assert.ok(fs.existsSync(path.join(input, 'unlisted.txt')));
    clearInterval(writer);
    const untouched = path.join(input, 'untouched.nrrd');
    fs.writeFileSync(untouched, raw);
    fs.writeFileSync(manifest, JSON.stringify([
      { source: 'untouched.nrrd' }, { source: '../untouched.nrrd', destination: '../escape.data' }
    ]));
    await waitFor(() => !fs.existsSync(manifest));
    assert.deepEqual(fs.readFileSync(untouched), raw);
    assert.ok(!fs.existsSync(path.join(root, 'escape.data')));
    fs.writeFileSync(manifest, 'invalid JSON');
    await waitFor(() => !fs.existsSync(manifest));
    const audit = fs.readFileSync(path.join(input, 'log.txt'), 'utf8');
    assert.ok(audit.includes('[SUCCESS] scan.nrrd'));
    assert.ok(audit.includes('[FAILED] invalid.bin'));
    assert.ok(audit.includes('[REJECTED] import.json'));
    console.log('Guided CLI: mode, live catalog, manifest cleanup, noise isolation, and unsafe request rejection passed');
  } catch (error) {
    console.error(logs); throw error;
  } finally {
    clearInterval(writer);
    server.stdin.end('q\n');
    await exited;
    clearTimeout(watchdog);
    fs.rmSync(root, { recursive: true });
  }
  assert.equal(server.exitCode, 0);
})().catch(error => { console.error(error); process.exitCode = 1; });
