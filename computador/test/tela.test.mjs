// The person's screen (PRD-K, K-09), in the image: Xvfb, x11vnc with a
// password, noVNC; the browser moves to it and back.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import http from 'node:http';
import { once } from 'node:events';
import { run } from '../agent.mjs';
import { setInternalAllowed } from '../rede.mjs';

function rfbSecurity() {
  // The VNC handshake: the server's version, then the security types it
  // offers. 1 is "None"; 2 is a password.
  return new Promise((resolve, reject) => {
    const socket = net.connect(5900, '127.0.0.1');
    let buf = Buffer.alloc(0);
    socket.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      if (buf.length === 12) socket.write(buf);
      if (buf.length > 12) {
        const types = [...buf.subarray(13, 13 + buf[12])];
        socket.destroy();
        resolve(types);
      }
    });
    socket.on('error', reject);
  });
}

function x11Answer() {
  // The X11 connection setup with no authorization: little endian,
  // protocol 11.0, empty name and data. The first byte of the answer:
  // 0 refused, 1 accepted.
  return new Promise((resolve, reject) => {
    const socket = net.connect('/tmp/.X11-unix/X99');
    socket.on('connect', () => socket.write(Buffer.from([0x6c, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0])));
    socket.once('data', (d) => { socket.destroy(); resolve(d[0]); });
    socket.on('error', reject);
  });
}

test('the screen opens with a password, shows the page, and closes', { timeout: 180_000 }, async () => {
  const server = http.createServer((_, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end('<title>Captcha</title><div class="g-recaptcha">não sou um robô</div>');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  setInternalAllowed((h) => h === '127.0.0.1');
  try {
    const url = `http://127.0.0.1:${server.address().port}/`;
    const opened = await run({ op: 'goto', url });
    // A captcha is told, not solved.
    assert.equal(opened.captcha, true);
    const screen = await run({ op: 'tela_abrir' });
    assert.equal(screen.aberta, true);
    assert.equal(screen.senha.length, 8);
    // noVNC is served; VNC asks for the password, never "None".
    const page = await fetch('http://127.0.0.1:6080/vnc.html');
    assert.equal(page.status, 200);
    const types = await rfbSecurity();
    assert.ok(types.includes(2));
    assert.ok(!types.includes(1));
    // The display wants its cookie: another user on this computer (the
    // shell's) cannot watch it or type into it.
    assert.equal(await x11Answer(), 0);
    // The browser is on the screen, on the same page.
    const shot = await run({ op: 'screenshot' });
    assert.equal(shot.title, 'Captcha');
    // Opening again gives the same password.
    assert.equal((await run({ op: 'tela_abrir' })).senha, screen.senha);
    const closed = await run({ op: 'tela_fechar' });
    assert.equal(closed.aberta, false);
    await assert.rejects(fetch('http://127.0.0.1:6080/vnc.html'));
    assert.equal((await run({ op: 'text' })).title, 'Captcha');
  } finally {
    await run({ op: 'tela_fechar' }).catch(() => {});
    await run({ op: 'close' }).catch(() => {});
    server.close();
    setInternalAllowed(() => false);
  }
});
