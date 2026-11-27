// The browser gate (PRD-K, K-06), with a real browser and a local site.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { chromium } from 'playwright';
import { guard, setInternalAllowed } from '../rede.mjs';
import { newGate, allow, account, decide, beforeClick, siteOf, summarizeFields, fieldsOf } from '../portao.mjs';

test('the site is what a person recognises', () => {
  assert.equal(siteOf('www.consultas.saude.gov.br'), 'saude.gov.br');
  assert.equal(siteOf('accounts.google.com'), 'google.com');
  assert.equal(siteOf('example.com'), 'example.com');
  assert.equal(siteOf('a.b.example.co.uk'), 'example.co.uk');
  assert.equal(siteOf('127.0.0.1'), '127.0.0.1');
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
      } else {
        res.end('<title>Ok</title>ok');
      }
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}`, posts, close: () => server.close() };
}

test('reading is free; background posts need the site; a send needs a yes each time', { timeout: 120_000 }, async () => {
  setInternalAllowed((h) => h === '127.0.0.1');
  const s = await site();
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const context = await browser.newContext();
    const gate = newGate();
    await guard(context, (request) => decide(gate, request));
    const page = await context.newPage();

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
