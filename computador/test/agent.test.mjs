// Tests for the computer service. They need no network; the browser test
// opens a data: URL, so it runs wherever Chromium runs (the image itself):
//   docker run --rm --runtime=runsc supernova-computador npm test --prefix /opt/computador
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { browserOpen, clip, createServer, LIMITS, resolvePath, run, runShell, WORK_DIR, UserError } from '../agent.mjs';
import http from 'node:http';
import { promises as fs } from 'node:fs';
import path from 'node:path';

await fs.mkdir(WORK_DIR, { recursive: true });

async function post(server, body, headers = {}) {
  const { port } = server.address();
  const res = await fetch(`http://127.0.0.1:${port}/v1/run`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  return { status: res.status, json: await res.json() };
}

async function withServer(token, fn) {
  const server = createServer(token);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try { await fn(server); } finally { server.close(); }
}

test('clip marks truncation', () => {
  assert.deepEqual(clip('abc', 5), { text: 'abc', truncated: false });
  assert.deepEqual(clip('abcdef', 3), { text: 'abc', truncated: true });
});

test('relative paths resolve inside the work dir', () => {
  assert.equal(resolvePath('a/b.txt'), path.join(WORK_DIR, 'a/b.txt'));
  assert.equal(resolvePath('/etc/hostname'), '/etc/hostname');
  assert.throws(() => resolvePath(''), UserError);
});

test('exec runs a real shell with pipes and reports the exit code', async () => {
  const r = await runShell('echo olá | tr a-z A-Z; exit 3', 10);
  assert.equal(r.stdout.trim(), 'OLá');
  assert.equal(r.exit_code, 3);
  assert.equal(r.timed_out, false);
});

test('exec does not leak the service token', async () => {
  process.env.COMPUTADOR_TOKEN = 'segredo';
  const r = await runShell('printf "%s" "$COMPUTADOR_TOKEN"', 10);
  assert.equal(r.stdout, '');
  delete process.env.COMPUTADOR_TOKEN;
});

test('exec stops at the timeout, children included', async () => {
  const started = Date.now();
  const r = await runShell('sleep 30 & sleep 30', 1);
  assert.equal(r.timed_out, true);
  assert.ok(Date.now() - started < 10_000);
});

test('exec returns while a background server keeps running', async () => {
  const started = Date.now();
  const r = await runShell('nohup sleep 20 >/dev/null 2>&1 & echo $!', 15);
  const pid = r.stdout.trim();
  assert.match(pid, /^\d+$/);
  assert.equal(r.timed_out, false);
  assert.ok(Date.now() - started < 5_000);
  // Check that exact process, not a command line that mentions it.
  const still = await runShell(`kill -0 ${pid} && echo alive`, 5);
  assert.equal(still.stdout.trim(), 'alive');
  await runShell(`kill ${pid}; true`, 5);
});

test('exec decodes UTF-8 split across output chunks', async () => {
  const r = await runShell("printf '\\303'; sleep 0.3; printf '\\241'", 10);
  assert.equal(r.stdout, 'á');
});

test('exec returns even when a background job keeps the output open', async () => {
  const started = Date.now();
  const r = await runShell('sleep 20 & echo started', 15);
  assert.equal(r.stdout.trim(), 'started');
  assert.ok(Date.now() - started < 5_000);
  await runShell('pkill -f "sleep 20"; true', 5);
});

test('write, read and list files', async () => {
  await run({ op: 'write_file', path: 'teste/nota.txt', content: 'oi' });
  const read = await run({ op: 'read_file', path: 'teste/nota.txt' });
  assert.equal(read.content, 'oi');
  const listed = await run({ op: 'list', path: 'teste' });
  assert.deepEqual(listed.entries, ['nota.txt']);
});

test('unknown op is a user error', async () => {
  await assert.rejects(run({ op: 'formatar_disco' }), UserError);
});

test('http: token, bad JSON and errors', async () => {
  await withServer('t0k', async (server) => {
    assert.equal((await post(server, { op: 'list' })).status, 401);
    const ok = await post(server, { op: 'exec', command: 'echo 1' }, { authorization: 'Bearer t0k' });
    assert.equal(ok.json.ok, true);
    assert.equal(ok.json.stdout, '1\n');
    const bad = await post(server, '{', { authorization: 'Bearer t0k' });
    assert.equal(bad.status, 400);
    const missing = await post(server, { op: 'read_file', path: 'nao/existe' }, { authorization: 'Bearer t0k' });
    assert.equal(missing.json.ok, false);
    assert.match(missing.json.error, /ENOENT/);
  });
});

test('http: a browser cannot drive the service', async () => {
  await withServer('', async (server) => {
    const page = await post(server, { op: 'exec', command: 'echo pwned' }, { origin: 'http://evil.example' });
    assert.equal(page.status, 403);
    const simple = await post(server, { op: 'exec', command: 'echo pwned' }, { 'content-type': 'text/plain' });
    assert.equal(simple.status, 403);
    const supernova = await post(server, { op: 'exec', command: 'echo ok' });
    assert.equal(supernova.json.stdout, 'ok\n');
  });
});

test('http: UTF-8 split across request chunks survives', async () => {
  await withServer('', async (server) => {
    const body = Buffer.from(JSON.stringify({ op: 'write_file', path: 'utf8.txt', content: 'á' }));
    const cut = body.indexOf(Buffer.from('á')) + 1;
    const answer = await new Promise((resolve, reject) => {
      const req = http.request({
        host: '127.0.0.1', port: server.address().port, path: '/v1/run', method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': body.length },
      }, (res) => { let d = ''; res.on('data', (c) => { d += c; }); res.on('end', () => resolve(JSON.parse(d))); });
      req.on('error', reject);
      req.write(body.subarray(0, cut));
      setTimeout(() => req.end(body.subarray(cut)), 100);
    });
    assert.equal(answer.ok, true);
    const read = await run({ op: 'read_file', path: 'utf8.txt' });
    assert.equal(read.content, 'á');
  });
});

test('browser: open a page, read it, click, screenshot', { timeout: 120_000 }, async () => {
  const html = '<title>Teste</title><h1>Olá</h1><button onclick="document.title=\'clicado\'">ok</button>';
  // goto refuses non-http URLs, so serve the page from a local server.
  const pageServer = (await import('node:http')).createServer((_, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(html);
  });
  pageServer.listen(0, '127.0.0.1');
  await once(pageServer, 'listening');
  try {
    const url = `http://127.0.0.1:${pageServer.address().port}/`;
    const opened = await run({ op: 'goto', url });
    assert.equal(opened.title, 'Teste');
    const text = await run({ op: 'text' });
    assert.match(text.text, /Olá/);
    const clicked = await run({ op: 'click', selector: 'button' });
    assert.equal(clicked.title, 'clicado');
    const shot = await run({ op: 'screenshot' });
    assert.match(shot.image, /^data:image\/jpeg;base64,/);
    await assert.rejects(run({ op: 'goto', url: 'file:///etc/passwd' }), UserError);

    // A script that never settles must not block the browser for good.
    const limit = LIMITS.browserOpMs;
    LIMITS.browserOpMs = 3_000;
    try {
      await assert.rejects(run({ op: 'evaluate', script: 'new Promise(() => {})' }), /restarted/);
    } finally {
      LIMITS.browserOpMs = limit;
    }
    const again = await run({ op: 'goto', url });
    assert.equal(again.title, 'Teste');

    // A launch that outlives its deadline must not become the browser.
    await run({ op: 'close' });
    LIMITS.browserOpMs = 50;
    try {
      await assert.rejects(run({ op: 'goto', url }), /restarted/);
    } finally {
      LIMITS.browserOpMs = limit;
    }
    await new Promise((resolve) => setTimeout(resolve, 8_000));
    assert.equal(browserOpen(), false);
    const fresh = await run({ op: 'goto', url });
    assert.equal(fresh.title, 'Teste');
  } finally {
    await run({ op: 'close' });
    pageServer.close();
  }
});
