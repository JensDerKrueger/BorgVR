const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

async function unusedPort() {
  const listener = net.createServer();
  listener.listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return port;
}

function status(port, password) {
  return new Promise((resolve, reject) => {
    const request = http.get({
      hostname: '127.0.0.1', port, path: '/', agent: false,
      headers: password === undefined ? {} : {
        Authorization: `Basic ${Buffer.from(`test:${password}`).toString('base64')}`
      }
    }, response => { response.resume(); resolve(response.statusCode); });
    request.setTimeout(1000, () => request.destroy(new Error('HTTP timeout')));
    request.on('error', reject);
  });
}

async function checkServer(binary, directory, name, environmentPassword, args, expectedPassword) {
  const environment = { ...process.env };
  delete environment.BORGVR_SERVER_PASSWORD;
  if (environmentPassword !== undefined) environment.BORGVR_SERVER_PASSWORD = environmentPassword;
  const port = await unusedPort();
  let nativePort = await unusedPort();
  while (nativePort === port) nativePort = await unusedPort();
  const server = spawn(binary, ['--directory', directory, '--port', String(nativePort),
    '--web-port', String(port), '--web-http', '--scan-interval', '0', ...args], { env: environment });
  let output = '';
  server.stdout.on('data', data => { output += data; });
  server.stderr.on('data', data => { output += data; });
  const exited = once(server, 'exit');
  const watchdog = setTimeout(() => server.kill('SIGKILL'), 20000);
  try {
    let initialStatus;
    const deadline = Date.now() + 15000;
    while (initialStatus === undefined) {
      assert.equal(server.exitCode, null, 'Server exited before becoming ready');
      try { initialStatus = await status(port); }
      catch (error) {
        if (Date.now() >= deadline) throw error;
        await delay(50);
      }
    }
    assert.equal(initialStatus, expectedPassword ? 401 : 200, name);
    if (expectedPassword) {
      assert.equal(await status(port, expectedPassword), 200, `${name}: correct password`);
      assert.equal(await status(port, 'incorrect-test-password'), 401, `${name}: wrong password`);
      if (environmentPassword && environmentPassword !== expectedPassword) {
        assert.equal(await status(port, environmentPassword), 401, `${name}: environment overridden`);
      }
    }
  } finally {
    server.stdin.end('q\n');
    await exited;
    clearTimeout(watchdog);
  }
  assert.equal(server.exitCode, 0, `${name}: clean shutdown`);
  for (const secret of [environmentPassword, expectedPassword].filter(Boolean)) {
    assert.ok(!output.includes(secret), `${name}: password must not appear in logs`);
  }
  console.log(`Passed: ${name}`);
}

(async () => {
  const binary = process.argv[2];
  assert.ok(binary, 'Usage: node Tests/TerminalServerEnvironmentTests.js /path/to/TerminalServerApp');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'borgvr-server-env-'));
  try {
    await checkServer(binary, directory, 'unset environment', undefined, [], '');
    await checkServer(binary, directory, 'empty environment', '', [], '');
    await checkServer(binary, directory, 'environment password', 'env-test-secret', [], 'env-test-secret');
    await checkServer(binary, directory, 'CLI overrides environment', 'env-test-secret',
      ['--password', 'cli-test-secret'], 'cli-test-secret');
    await checkServer(binary, directory, 'empty CLI overrides environment', 'env-test-secret', ['--password', ''], '');
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
