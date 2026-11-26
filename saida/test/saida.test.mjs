import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import {
  createProxy, createAdmin, credentialFor, hasCredential, listed, publicAddress,
  setInternalAllowed, FACTORY,
} from '../saida.mjs';

const ANA = 'a'.repeat(16);
const BIA = 'b'.repeat(16);

// A "site" on this machine: answers with what it got.
async function site() {
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ method: req.method, url: req.url, host: req.headers.host, auth: req.headers['proxy-authorization'] || null }));
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { port: server.address().port, close: () => server.close() };
}

// Names resolve to 127.0.0.1 (the local site), allowed as internal only for
// the test.
const lookup = async () => [{ address: '127.0.0.1', family: 4 }];

async function proxyFor(people) {
  const config = { master: 'mestre', people: new Map(people), lookup };
  const server = createProxy(config);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { port: server.address().port, config, close: () => server.close() };
}

function basic(person, secret) {
  return 'Basic ' + Buffer.from(`${person}:${secret}`).toString('base64');
}

// A plain-HTTP request through the proxy (absolute URL).
function viaProxy(proxyPort, url, { method = 'GET', auth } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1', port: proxyPort, method, path: url,
      headers: auth ? { 'proxy-authorization': auth } : {},
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.end();
  });
}

// A CONNECT through the proxy; the status line it answers.
function connect(proxyPort, target, auth) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(proxyPort, '127.0.0.1', () => {
      socket.write(`CONNECT ${target} HTTP/1.1\r\nhost: ${target}\r\n${auth ? `proxy-authorization: ${auth}\r\n` : ''}\r\n`);
    });
    let data = '';
    socket.on('data', (d) => {
      data += d.toString('utf8');
      if (data.includes('\r\n\r\n')) { socket.destroy(); resolve(data.split('\r\n')[0]); }
    });
    socket.on('error', reject);
  });
}

test('the list: a host matches itself and its subdomains, nothing else', () => {
  assert.ok(listed('pypi.org', FACTORY));
  assert.ok(listed('files.pythonhosted.org', FACTORY));
  assert.ok(listed('registry.npmjs.org', FACTORY));
  assert.ok(listed('raw.githubusercontent.com', FACTORY));
  assert.ok(!listed('evilpypi.org', FACTORY));
  assert.ok(!listed('pypi.org.evil.example', FACTORY));
  assert.ok(!listed('example.com', FACTORY));
  assert.ok(listed('api.example.com', ['example.com']));
});

test('the credential is the person\'s own', () => {
  const secret = credentialFor('mestre', ANA);
  assert.ok(hasCredential(basic(ANA, secret), 'mestre', ANA));
  assert.ok(!hasCredential(basic(BIA, secret), 'mestre', BIA));
  assert.ok(!hasCredential(basic(ANA, 'x'), 'mestre', ANA));
  assert.ok(!hasCredential(undefined, 'mestre', ANA));
  assert.notEqual(credentialFor('mestre', ANA), credentialFor('mestre', BIA));
});

test('nothing internal, whatever the name says', async () => {
  setInternalAllowed(() => false);
  await assert.rejects(publicAddress('localhost'), /internal/);
  await assert.rejects(publicAddress('10.0.0.1'), /internal/);
  await assert.rejects(publicAddress('[::1]'), /internal/);
  await assert.rejects(publicAddress('rebind.example', async () => [{ address: '192.168.0.10' }]), /internal/);
  assert.equal(await publicAddress('ok.example', async () => [{ address: '93.184.215.14' }]), '93.184.215.14');
});

test('the shell: factory list and the person\'s sites only, read only', async () => {
  const target = await site();
  setInternalAllowed((h) => h === '127.0.0.1');
  const proxy = await proxyFor([['127.0.0.1', { person: ANA, sites: ['liberado.example'] }]]);
  try {
    const url = (host) => `http://${host}:${target.port}/simple/`;
    assert.equal((await viaProxy(proxy.port, url('pypi.org'))).status, 200);
    assert.equal((await viaProxy(proxy.port, url('liberado.example'))).status, 200);
    const refused = await viaProxy(proxy.port, url('example.com'));
    // 407: the browser would answer with its credential; the shell has none.
    assert.equal(refused.status, 407);
    assert.match(refused.body, /not on the shell's list.*pedir_site/);
    // Reading only: no POST from the shell, even to a listed site.
    assert.equal((await viaProxy(proxy.port, url('pypi.org'), { method: 'POST' })).status, 407);
    // HTTPS: CONNECT to a listed host passes; to another, refused.
    assert.match(await connect(proxy.port, `pypi.org:${target.port}`), / 200 /);
    assert.match(await connect(proxy.port, `example.com:${target.port}`), / 407 /);
  } finally { proxy.close(); target.close(); setInternalAllowed(() => false); }
});

test('the browser: with the person\'s credential, any public site and any method', async () => {
  const target = await site();
  setInternalAllowed((h) => h === '127.0.0.1');
  const proxy = await proxyFor([['127.0.0.1', { person: ANA, sites: [] }]]);
  try {
    const auth = basic(ANA, credentialFor('mestre', ANA));
    const answer = await viaProxy(proxy.port, `http://example.com:${target.port}/form`, { method: 'POST', auth });
    assert.equal(answer.status, 200);
    // The credential stops at the proxy.
    assert.equal(JSON.parse(answer.body).auth, null);
    assert.match(await connect(proxy.port, `example.com:${target.port}`, auth), / 200 /);
    // Another person's credential is no credential here.
    const bia = basic(BIA, credentialFor('mestre', BIA));
    assert.equal((await viaProxy(proxy.port, `http://example.com:${target.port}/`, { auth: bia })).status, 407);
  } finally { proxy.close(); target.close(); setInternalAllowed(() => false); }
});

test('a site one person approved does not open for another', async () => {
  const target = await site();
  setInternalAllowed((h) => h === '127.0.0.1');
  // Bia's computer arrives on another address; here, an unknown one.
  const proxy = await proxyFor([['10.9.9.9', { person: ANA, sites: ['liberado.example'] }]]);
  try {
    const answer = await viaProxy(proxy.port, `http://liberado.example:${target.port}/`);
    assert.equal(answer.status, 403);
    assert.match(answer.body, /not a computer/);
  } finally { proxy.close(); target.close(); setInternalAllowed(() => false); }
});

test('the dispatcher\'s door: token, address and a list of plain hosts', async () => {
  const people = new Map();
  const admin = createAdmin({ token: 'adm', people });
  admin.listen(0, '127.0.0.1');
  await once(admin, 'listening');
  const call = (method, path, body, token = 'adm') => fetch(`http://127.0.0.1:${admin.address().port}${path}`, {
    method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }).then((r) => r.status);
  try {
    assert.equal(await call('PUT', `/v1/pessoas/${ANA}`, { endereco: '172.20.0.2', sites: ['Exemplo.com'] }), 200);
    assert.deepEqual(people.get('172.20.0.2'), { person: ANA, sites: ['exemplo.com'] });
    // Moving address replaces the old one.
    assert.equal(await call('PUT', `/v1/pessoas/${ANA}`, { endereco: '172.21.0.2', sites: [] }), 200);
    assert.equal(people.has('172.20.0.2'), false);
    for (const bad of [
      { endereco: 'x', sites: [] },
      { endereco: '172.20.0.2', sites: ['http://a.com'] },
      { endereco: '172.20.0.2', sites: ['10.0.0.1'] },
      { endereco: '172.20.0.2', sites: ['localhost'] },
      { endereco: '172.20.0.2', sites: [], extra: 1 },
    ]) {
      assert.equal(await call('PUT', `/v1/pessoas/${ANA}`, bad), 400, JSON.stringify(bad));
    }
    assert.equal(await call('PUT', `/v1/pessoas/${ANA}`, { endereco: '172.20.0.2', sites: [] }, 'errado'), 401);
    assert.equal(await call('PUT', '/v1/pessoas/ana', { endereco: '172.20.0.2', sites: [] }), 404);
    assert.equal(await call('DELETE', `/v1/pessoas/${ANA}`), 200);
    assert.equal(people.size, 0);
  } finally { admin.close(); }
});

test('a client that goes away does not take the proxy down', async () => {
  const target = await site();
  setInternalAllowed((h) => h === '127.0.0.1');
  const proxy = await proxyFor([['127.0.0.1', { person: ANA, sites: [] }]]);
  try {
    for (let i = 0; i < 5; i++) {
      await new Promise((resolve) => {
        const socket = net.connect(proxy.port, '127.0.0.1', () => {
          socket.write('CONNECT example.com:443 HTTP/1.1\r\nhost: example.com\r\n\r\n');
          socket.resetAndDestroy();
          resolve();
        });
        socket.on('error', () => resolve());
      });
    }
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await viaProxy(proxy.port, `http://pypi.org:${target.port}/`)).status, 200);
  } finally { proxy.close(); target.close(); setInternalAllowed(() => false); }
});
