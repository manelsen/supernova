// The person's screen link (PRD-K, K-09): one use, 15 minutes, that
// person's computer only; the screen server serves /tela/* and nothing else.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { screens, createScreenServer } from '../tela.mjs';

const ANA = 'a'.repeat(16);
const BIA = 'b'.repeat(16);

// Each person's "computer" answers its noVNC files with its own name, and
// echoes on its WebSocket.
async function computerFor(name) {
  const server = http.createServer((req, res) => { res.end(`${name}:${req.url}`); });
  server.on('upgrade', (req, socket) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n\r\n');
    socket.write(`vnc-de-${name}`);
    socket.end();
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server;
}

const servers = [];
after(() => servers.forEach((s) => s.close()));

async function setup(extra = {}) {
  const ana = await computerFor('ana');
  const bia = await computerFor('bia');
  servers.push(ana, bia);
  let now = 0;
  const config = {
    clock: () => now,
    screenUrl: (person) => `http://127.0.0.1:${(person === ANA ? ana : bia).address().port}`,
    ...extra,
  };
  const held = screens(config);
  const server = createScreenServer(config, held);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  servers.push(server);
  const base = `http://127.0.0.1:${server.address().port}`;
  return { held, base, advance: (ms) => { now += ms; }, port: server.address().port };
}

const get = (url, cookie) => fetch(url, { redirect: 'manual', headers: cookie ? { cookie } : {} });

function upgrade(port, path, cookie) {
  return new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1', () => {
      socket.write(`GET ${path} HTTP/1.1\r\nhost: x\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n${cookie ? `cookie: ${cookie}\r\n` : ''}\r\n`);
    });
    let data = '';
    socket.on('data', (d) => { data += d; });
    socket.on('close', () => resolve(data));
    socket.on('error', () => resolve(data));
  });
}

test('the link opens once, for one browser, on that person\'s screen', async () => {
  const { held, base, port } = await setup();
  let ended = 0;
  const token = held.issue(ANA, 'abc12345', () => { ended += 1; });
  // Opening the link shows a button and uses nothing: a chat app's link
  // preview fetches it first, and must not burn it.
  for (let i = 0; i < 2; i += 1) {
    const landing = await get(`${base}/tela/${token}/`);
    assert.equal(landing.status, 200);
    assert.equal(landing.headers.get('set-cookie'), null);
    const html = await landing.text();
    assert.match(html, /<form method="post"/);
    assert.match(html, /Abrir a tela/);
    assert.doesNotMatch(html, /abc12345/);
  }
  // The button uses the link, for this browser only. The password goes in
  // the page, never in a header.
  const first = await fetch(`${base}/tela/${token}/`, { method: 'POST', redirect: 'manual' });
  assert.equal(first.status, 200);
  assert.equal(first.headers.get('location'), null);
  assert.equal(first.headers.get('referrer-policy'), 'no-referrer');
  const opened = await first.text();
  assert.match(opened, new RegExp(`/tela/${token}/vnc\\.html#[^"']*password=abc12345`));
  const cookie = first.headers.get('set-cookie').split(';')[0];
  assert.match(first.headers.get('set-cookie'), /HttpOnly; Secure; SameSite=Strict/);
  // This browser gets Ana's screen.
  const files = await get(`${base}/tela/${token}/vnc.html`, cookie);
  assert.equal(await files.text(), 'ana:/vnc.html');
  assert.match(await upgrade(port, `/tela/${token}/websockify`, cookie), /vnc-de-ana/);
  // Used: no second browser gets in, by the button or otherwise.
  assert.equal((await fetch(`${base}/tela/${token}/`, { method: 'POST' })).status, 403);
  assert.equal((await get(`${base}/tela/${token}/`)).status, 403);
  assert.equal((await get(`${base}/tela/${token}/vnc.html`)).status, 403);
  assert.doesNotMatch(await upgrade(port, `/tela/${token}/websockify`), /vnc-de/);
  assert.equal(ended, 0);
});

test('the link expires; ending it ends the screen', async () => {
  const { held, base, advance } = await setup();
  let ended = 0;
  const token = held.issue(BIA, 'x', () => { ended += 1; });
  advance(15 * 60_000 + 1);
  assert.equal((await get(`${base}/tela/${token}/`)).status, 410);
  assert.equal(ended, 1);
  const again = held.issue(BIA, 'y', () => { ended += 1; });
  held.end(BIA);
  assert.equal(ended, 2);
  assert.equal((await get(`${base}/tela/${again}/`)).status, 410);
});

test('a new link replaces the old one; the screen goes on', async () => {
  const { held, base } = await setup();
  let ended = 0;
  const old = held.issue(ANA, 'p', () => { ended += 1; });
  const fresh = held.issue(ANA, 'p', () => { ended += 100; });
  assert.equal((await get(`${base}/tela/${old}/`)).status, 410);
  assert.equal((await get(`${base}/tela/${fresh}/`)).status, 200);
  held.end(ANA);
  // The first end (the screen's) runs once.
  assert.equal(ended, 1);
});

test('only /tela/<token>/ is served', async () => {
  const { base } = await setup();
  for (const path of ['/', '/v1/estado', '/tela/', '/tela/curto/', '/vnc.html', '/tela/../v1/ligar']) {
    assert.equal((await get(base + path)).status, 404, path);
  }
  const put = await fetch(`${base}/tela/${'x'.repeat(32)}/`, { method: 'PUT' });
  assert.equal(put.status, 404);
  const post = await fetch(`${base}/tela/${'x'.repeat(32)}/`, { method: 'POST' });
  assert.equal(post.status, 410);
});
