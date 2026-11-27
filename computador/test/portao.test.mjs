// The browser gate (PRD-K, K-06), with a real browser and a local site.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { chromium } from 'playwright';
import { createHash } from 'node:crypto';
import { guard, setInternalAllowed, contextOptions } from '../rede.mjs';
import { newGate, allow, account, decide, decideSocket, beforeClick, siteOf, summarizeFields, fieldsOf } from '../portao.mjs';

test('the site is what a person recognises', () => {
  assert.equal(siteOf('www.consultas.saude.gov.br'), 'saude.gov.br');
  assert.equal(siteOf('accounts.google.com'), 'google.com');
  assert.equal(siteOf('example.com'), 'example.com');
  assert.equal(siteOf('a.b.example.co.uk'), 'example.co.uk');
  assert.equal(siteOf('127.0.0.1'), '127.0.0.1');
});

test('a site on shared hosting is its owner, not the whole platform', () => {
  assert.equal(siteOf('meublog.wordpress.com'), 'meublog.wordpress.com');
  assert.equal(siteOf('www.meublog.wordpress.com'), 'meublog.wordpress.com');
  assert.equal(siteOf('ana.github.io'), 'ana.github.io');
  assert.equal(siteOf('loja.netlify.app'), 'loja.netlify.app');
  assert.equal(siteOf('x.blogspot.com.br'), 'x.blogspot.com.br');
  assert.equal(siteOf('github.io'), 'github.io');
  assert.equal(siteOf('wordpress.com'), 'wordpress.com');
});

test('what a form sends, secrets masked', () => {
  const fields = fieldsOf('nome=Ana&senha=segredo123&cpf=12345678900&csrf=xyz', 'application/x-www-form-urlencoded');
  const text = summarizeFields(fields);
  assert.match(text, /nome = Ana/);
  assert.doesNotMatch(text, /segredo123/);
  assert.doesNotMatch(text, /12345678900/);
  assert.doesNotMatch(text, /csrf/);
  assert.match(summarizeFields(fieldsOf('{"email":"a@b.c","password":"x"}', 'application/json')), /email = a@b\.c; password = ••••/);
});

async function site() {
  const posts = [];
  const sockets = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      if (req.method === 'POST') posts.push({ url: req.url, body: Buffer.concat(chunks).toString('utf8') });
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      if (req.url === '/form') {
        res.end(`<title>Form</title>
          <form method="post" action="/enviar">
            <input name="nome" value="Ana"><input type="password" name="senha" value="segredo123">
            <button id="enviar">Enviar</button>
          </form>
          <button id="curtir" onclick="fetch('/curtir',{method:'POST',body:'x'}).then(()=>document.title='curtido').catch(()=>document.title='barrado')">Curtir</button>
          <a id="comprar" href="/produto">Comprar</a>`);
      } else if (req.url === '/socket') {
        res.end(`<title>Socket</title><script>
          const ws = new WebSocket(location.origin.replace('http', 'ws') + '/ws');
          ws.onopen = () => { ws.send('curtir'); document.title = 'aberto'; };
          ws.onclose = () => { if (document.title === 'Socket') document.title = 'fechado'; };
        </script>`);
      } else if (req.url === '/worker') {
        res.end(`<title>Worker</title><script>
          navigator.serviceWorker.register('/sw.js')
            .then(() => { document.title = 'registrado'; })
            .catch(() => { document.title = 'barrado'; });
        </script>`);
      } else if (req.url === '/sw.js') {
        res.writeHead(200, { 'content-type': 'text/javascript' });
        res.end("self.addEventListener('install', () => fetch('/curtir', { method: 'POST', body: 'sw' }));");
      } else {
        res.end('<title>Ok</title>ok');
      }
    });
  });
  // A WebSocket handshake, by hand: enough to count who got through.
  server.on('upgrade', (req, socket) => {
    sockets.push(req.url);
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on('error', () => {});
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}`, posts, sockets, close: () => { server.closeAllConnections?.(); server.close(); } };
}

test('reading is free; background posts need the site; a send needs a yes each time', { timeout: 120_000 }, async () => {
  setInternalAllowed((h) => h === '127.0.0.1');
  const s = await site();
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const context = await browser.newContext();
    const gate = newGate();
    await guard(context, (request) => decide(gate, request));
    let page = await context.newPage();

    // Nothing allowed: reading works, a background post is refused.
    allow(gate, {});
    await page.goto(`${s.url}/form`);
    await page.click('#curtir');
    await page.waitForFunction(() => document.title !== 'Form');
    assert.equal(await page.title(), 'barrado');
    assert.equal(account(gate).portao.recusas[0].tipo, 'site');
    assert.equal(account(gate).portao.recusas[0].site, '127.0.0.1');
    assert.equal(s.posts.length, 0);

    // The site allowed (level 1): the background post goes.
    allow(gate, { sites: ['127.0.0.1'] });
    await page.reload();
    await page.click('#curtir');
    await page.waitForFunction(() => document.title !== 'Form');
    assert.equal(await page.title(), 'curtido');
    assert.equal(s.posts.length, 1);

    // A link that says "Comprar" is reading: no question.
    assert.equal(await beforeClick(gate, page, await page.$('#comprar')), null);

    // Sending the form, even with the site allowed: refused, with what it
    // would send, the password masked; nothing reaches the site.
    await page.goto(`${s.url}/form`);
    const refusal = await beforeClick(gate, page, await page.$('#enviar'));
    assert.equal(refusal.tipo, 'envio');
    assert.equal(refusal.botao, 'Enviar');
    assert.match(refusal.campos, /nome = Ana; senha = ••••/);
    assert.equal(s.posts.length, 1);
    // Pressing Enter in the form is refused at the network too.
    await page.focus('input[name=nome]');
    await page.keyboard.press('Enter');
    await page.waitForTimeout(500);
    assert.equal(s.posts.length, 1);
    assert.ok(account(gate).portao.recusas.some((r) => r.tipo === 'envio'));
    // A blocked navigation leaves Chromium's error page in the tab; like the
    // service (agent.mjs, goto), go on in a fresh tab.
    const fresh = await context.newPage();
    await page.close();
    page = fresh;

    // A one-use yes: the send goes once, and is accounted as used.
    allow(gate, { envios: ['127.0.0.1'] });
    await page.goto(`${s.url}/form`);
    assert.equal(await beforeClick(gate, page, await page.$('#enviar')), null);
    await Promise.all([page.waitForNavigation(), page.click('#enviar')]);
    assert.equal(s.posts.length, 2);
    assert.match(s.posts[1].body, /nome=Ana/);
    assert.deepEqual(account(gate).portao.usados, ['127.0.0.1']);
    // Spent: the next send asks again.
    allow(gate, {});
    await page.goto(`${s.url}/form`);
    assert.equal((await beforeClick(gate, page, await page.$('#enviar'))).tipo, 'envio');
  } finally {
    await browser.close();
    s.close();
    setInternalAllowed(() => false);
  }
});

test('a probe never sends, and never asks', { timeout: 120_000 }, async () => {
  setInternalAllowed((h) => h === '127.0.0.1');
  const s = await site();
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const context = await browser.newContext();
    const gate = newGate({ probe: true });
    await guard(context, (request) => decide(gate, request));
    const page = await context.newPage();
    allow(gate, { sites: ['127.0.0.1'], envios: ['127.0.0.1'] });
    await page.goto(`${s.url}/form`);
    await page.click('#curtir');
    await page.waitForFunction(() => document.title !== 'Form');
    assert.equal(await page.title(), 'barrado');
    assert.equal(await beforeClick(gate, page, await page.$('#enviar')), null);
    await page.click('#enviar').catch(() => {});
    await page.waitForTimeout(500);
    assert.equal(s.posts.length, 0);
    assert.ok(account(gate).portao.recusas.every((r) => r.tipo === 'sonda'));
  } finally {
    await browser.close();
    s.close();
    setInternalAllowed(() => false);
  }
});

test('a WebSocket needs the site, like any other write; a probe never opens one', { timeout: 120_000 }, async () => {
  setInternalAllowed((h) => h === '127.0.0.1');
  const s = await site();
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const context = await browser.newContext(contextOptions());
    const gate = newGate();
    await guard(context, (request) => decide(gate, request), (url) => decideSocket(gate, url));
    const page = await context.newPage();

    allow(gate, {});
    await page.goto(`${s.url}/socket`);
    await page.waitForFunction(() => document.title !== 'Socket');
    assert.equal(await page.title(), 'fechado');
    assert.equal(s.sockets.length, 0);
    const refusal = account(gate).portao.recusas[0];
    assert.equal(refusal.tipo, 'site');
    assert.equal(refusal.metodo, 'WEBSOCKET');

    allow(gate, { sites: ['127.0.0.1'] });
    await page.goto(`${s.url}/socket`);
    await page.waitForFunction(() => document.title !== 'Socket');
    assert.equal(await page.title(), 'aberto');
    assert.equal(s.sockets.length, 1);

    const probeContext = await browser.newContext(contextOptions());
    const probe = newGate({ probe: true });
    await guard(probeContext, (request) => decide(probe, request), (url) => decideSocket(probe, url));
    allow(probe, { sites: ['127.0.0.1'] });
    const probePage = await probeContext.newPage();
    await probePage.goto(`${s.url}/socket`);
    await probePage.waitForFunction(() => document.title !== 'Socket');
    assert.equal(await probePage.title(), 'fechado');
    assert.equal(s.sockets.length, 1);
    assert.equal(account(probe).portao.recusas[0].tipo, 'sonda');
  } finally {
    await browser.close();
    s.close();
    setInternalAllowed(() => false);
  }
});

test('a page cannot install a service worker to send behind the gate', { timeout: 120_000 }, async () => {
  setInternalAllowed((h) => h === '127.0.0.1');
  const s = await site();
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const context = await browser.newContext(contextOptions());
    const gate = newGate();
    await guard(context, (request) => decide(gate, request), (url) => decideSocket(gate, url));
    allow(gate, {});
    const page = await context.newPage();
    await page.goto(`${s.url}/worker`);
    await page.waitForFunction(() => document.title !== 'Worker');
    await page.waitForTimeout(1000);
    assert.equal(context.serviceWorkers().length, 0);
    assert.equal(s.posts.length, 0);
  } finally {
    await browser.close();
    s.close();
    setInternalAllowed(() => false);
  }
});
