import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import {
  createServer, computers, computerSpec, personOf, listenAddresses, pinImage,
  configFromEnv, bridgeName, resolvConfSource, UserError, LIMITS, LABEL,
} from '../despachante.mjs';
import { docker } from '../docker.mjs';

const ANA = 'a'.repeat(16);
const BIA = 'b'.repeat(16);
const people = ['1', '2', '3', '4', '5'].map((c) => c.repeat(16));

// A fake Docker Engine on a Unix socket: containers, volumes and networks
// in memory, every request recorded.
async function fakeDocker() {
  if (saida) saida.close();
  saida = await fakeSaida();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'docker-'));
  const socketPath = path.join(dir, 'docker.sock');
  const state = {
    containers: new Map(), volumes: new Map(), networks: new Map(), requests: [],
  };
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      const body = text ? JSON.parse(text) : null;
      state.requests.push({ method: req.method, url: req.url, body });
      const reply = (status, json) => {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(json === undefined ? '' : JSON.stringify(json));
      };
      const url = new URL(req.url, 'http://docker');
      let m;
      if (req.method === 'POST' && url.pathname === '/containers/create') {
        const name = url.searchParams.get('name');
        if (state.containers.has(name)) return reply(409, { message: 'conflict' });
        state.containers.set(name, { spec: body, running: false });
        return reply(201, { Id: name });
      }
      if (req.method === 'POST' && (url.pathname === '/volumes/create' || url.pathname === '/networks/create')) {
        const store = url.pathname.startsWith('/volumes') ? state.volumes : state.networks;
        if (store.has(body.Name)) {
          return url.pathname.startsWith('/networks') ? reply(409, {}) : reply(201, { Name: body.Name });
        }
        const n = store.size + 20;
        store.set(body.Name, {
          Labels: body.Labels || {}, Options: body.Options || {}, Internal: !!body.Internal,
          subnet: `172.${n}.0.0/16`, members: new Map(),
        });
        return reply(201, { Name: body.Name });
      }
      if ((m = url.pathname.match(/^\/networks\/([^/]+)\/(connect|disconnect)$/))) {
        const n = state.networks.get(m[1]);
        if (!n) return reply(404, {});
        if (m[2] === 'connect') {
          if (n.members.has(body.Container)) return reply(403, {});
          n.members.set(body.Container, body.EndpointConfig && body.EndpointConfig.IPAMConfig && body.EndpointConfig.IPAMConfig.IPv4Address);
        } else n.members.delete(body.Container);
        return reply(200);
      }
      if ((m = url.pathname.match(/^\/(volumes|networks)\/([^/]+)$/))) {
        const store = m[1] === 'volumes' ? state.volumes : state.networks;
        if (req.method === 'GET') {
          if (!store.has(m[2])) return reply(404, {});
          const found = store.get(m[2]);
          return reply(200, { Name: m[2], Labels: found.Labels, IPAM: { Config: [{ Subnet: found.subnet }] } });
        }
        if (req.method === 'DELETE') return reply(store.delete(m[2]) ? 204 : 404, {});
      }
      if ((m = url.pathname.match(/^\/containers\/([^/]+)\/json$/))) {
        if (m[1] === 'eu') {
          return reply(200, { Mounts: [{ Destination: '/etc/computador/resolv.conf', Source: '/srv/supernova/computador/resolv.conf' }], NetworkSettings: { Networks: {
            [`computador-${ANA}`]: { IPAddress: '172.30.0.2' },
            supernova_computador: { IPAddress: '172.29.0.2' },
            supernova_default: { IPAddress: '172.18.0.5' },
          } } });
        }
        const c = state.containers.get(m[1]);
        if (!c) return reply(404, { message: 'no such container' });
        return reply(200, { Config: { Labels: c.spec.Labels }, State: { Running: c.running } });
      }
      if ((m = url.pathname.match(/^\/containers\/([^/]+)\/(start|stop)$/))) {
        const c = state.containers.get(m[1]);
        if (!c) return reply(404, {});
        const on = m[2] === 'start';
        if (c.running === on) return reply(304);
        c.running = on;
        return reply(204);
      }
      if (req.method === 'DELETE' && (m = url.pathname.match(/^\/containers\/([^/]+)$/))) {
        return reply(state.containers.delete(m[1]) ? 204 : 404, {});
      }
      if (url.pathname === '/containers/json') {
        const filters = JSON.parse(url.searchParams.get('filters') || '{}');
        const list = [...state.containers.entries()]
          .filter(([, c]) => c.spec.Labels && c.spec.Labels[LABEL] === '1')
          .filter(([, c]) => !(filters.status || []).includes('running') || c.running)
          .map(([name, c]) => ({ Names: [`/${name}`], Labels: c.spec.Labels, State: c.running ? 'running' : 'exited' }));
        return reply(200, list);
      }
      if ((m = url.pathname.match(/^\/images\/(.+)\/json$/))) {
        if (decodeURIComponent(m[1]) === 'supernova-computador:latest') return reply(200, { Id: 'sha256:abc' });
        return reply(404, { message: 'no such image' });
      }
      reply(404, { message: `unknown ${req.method} ${req.url}` });
    });
  });
  server.listen(socketPath);
  await once(server, 'listening');
  return { socketPath, state, close: () => server.close() };
}

// Fake computers: one HTTP service per person, answering /health and
// echoing calls.
async function fakeComputers() {
  const servers = new Map();
  const calls = [];
  const release = [];
  let hold = false;
  async function urlFor(person) {
    if (!servers.has(person)) {
      const server = http.createServer((req, res) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', async () => {
          if (req.url === '/health') { res.end('{"ok":true}'); return; }
          calls.push({ person, url: req.url, auth: req.headers.authorization, body: Buffer.concat(chunks).toString('utf8') });
          if (hold) await new Promise((r) => release.push(r));
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ ok: true, pessoa: person }));
        });
      });
      server.listen(0, '127.0.0.1');
      await once(server, 'listening');
      servers.set(person, server);
    }
    return `http://127.0.0.1:${servers.get(person).address().port}`;
  }
  for (const p of [ANA, BIA, ...people]) await urlFor(p);
  return {
    url: (person) => `http://127.0.0.1:${servers.get(person).address().port}`,
    calls,
    holdCalls: () => { hold = true; },
    releaseCalls: () => { hold = false; release.splice(0).forEach((r) => r()); },
    close: () => servers.forEach((s) => s.close()),
  };
}

// A fake proxy admin door: what the dispatcher told it.
async function fakeSaida() {
  const told = new Map();
  const calls = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      calls.push({ method: req.method, url: req.url, auth: req.headers.authorization });
      const person = req.url.split('/').pop();
      if (req.method === 'PUT') told.set(person, JSON.parse(Buffer.concat(chunks).toString('utf8')));
      if (req.method === 'DELETE') told.delete(person);
      res.end('{"ok":true}');
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}`, told, calls, close: () => server.close() };
}

let saida;
after(() => { if (saida) saida.close(); });

function setup(fake, pcs, extra = {}) {
  let now = 1_000_000;
  const cfg = {
    token: 'segredo',
    computerToken: 'do-computador',
    image: 'sha256:abc',
    runtime: 'runsc',
    docker: docker(fake.socketPath),
    computerUrl: pcs.url,
    self: 'eu',
    clock: () => now,
    saida: { container: 'saida', admin: saida.url, token: 'adm', master: 'mestre' },
    pollMs: 5,
    waitMs: 300,
    ...extra,
  };
  return { cfg, advance: (ms) => { now += ms; } };
}

async function serve(cfg, machines) {
  const server = createServer(cfg, machines);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, url, body, headers = {}) => {
    const res = await fetch(base + url, {
      method,
      headers: { authorization: 'Bearer segredo', 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
    });
    return { status: res.status, body: await res.json() };
  };
  return { call, close: () => server.close() };
}

test('a person hash and nothing else', () => {
  assert.equal(personOf({ pessoa: ANA }), ANA);
  for (const bad of [
    {}, { pessoa: 'ana' }, { pessoa: ANA.toUpperCase() }, { pessoa: ANA + 'a' },
    { pessoa: '../etc/passwd/xx' }, { pessoa: ANA, imagem: 'alpine' },
    { pessoa: ANA, runtime: 'runc' }, [ANA], null, { pessoa: 7 },
  ]) {
    assert.throws(() => personOf(bad), UserError, JSON.stringify(bad));
  }
});

test('a computer is made with the fixed parameters only, on its own network', () => {
  const spec = computerSpec({
    image: 'sha256:abc', computerToken: 't', runtime: 'runsc', resolvConf: '/srv/r.conf',
    saida: { master: 'mestre' }, saidaAddress: '172.20.0.2',
  }, ANA);
  assert.equal(spec.Image, 'sha256:abc');
  assert.equal(spec.HostConfig.Runtime, 'runsc');
  assert.equal(spec.HostConfig.Memory, 1536 * 1024 * 1024);
  assert.deepEqual(spec.HostConfig.CapDrop, ['ALL']);
  assert.deepEqual(spec.HostConfig.SecurityOpt, ['no-new-privileges:true']);
  assert.equal(spec.HostConfig.NetworkMode, `computador-${ANA}`);
  // The person's volume, and the resolver list, read-only. Nothing else of
  // the host.
  assert.deepEqual(spec.HostConfig.Mounts, [
    { Type: 'volume', Source: `computador-${ANA}`, Target: '/home/pwuser' },
    { Type: 'bind', Source: '/srv/r.conf', Target: '/etc/resolv.conf', ReadOnly: true },
  ]);
  assert.equal(spec.HostConfig.Binds, undefined);
  assert.equal(spec.HostConfig.Privileged, undefined);
  assert.equal(spec.Labels[LABEL], '1');
  assert.ok(bridgeName(ANA).length <= 15);
  assert.ok(bridgeName(ANA).startsWith('brc-'));
});

test('two people, two computers, two volumes, two networks (K-I4)', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  const api = await serve(cfg);
  try {
    assert.deepEqual((await api.call('POST', `/v1/pessoas/${ANA}/run`, { op: 'exec' })).body, { ok: true, pessoa: ANA });
    assert.deepEqual((await api.call('POST', `/v1/pessoas/${BIA}/mcp`, { acao: 'abrir' })).body, { ok: true, pessoa: BIA });
    assert.deepEqual(pcs.calls.map((c) => [c.person, c.url]), [[ANA, '/v1/run'], [BIA, '/v1/mcp']]);
    // The computer's token, which Supernova does not have.
    assert.ok(pcs.calls.every((c) => c.auth === 'Bearer do-computador'));
    // The proxy knows whose address is whose.
    assert.deepEqual([...saida.told.keys()].sort(), [ANA, BIA]);
    const ana = fake.state.containers.get(`computador-${ANA}`).spec;
    const proxyAt = saida.told.get(ANA).endereco;
    assert.ok(ana.Env.includes(`SAIDA_URL=http://${proxyAt}:3128`));
    assert.ok(ana.Env.includes(`SAIDA_USUARIO=${ANA}`));
    assert.ok(ana.Env.some((e) => e.startsWith('SAIDA_SENHA=') && e.length > 30));
    assert.deepEqual(ana.HostConfig.CapAdd, ['CHOWN', 'SETUID', 'SETGID', 'KILL']);
    assert.ok(saida.calls.every((c) => c.auth === 'Bearer adm'));
    assert.deepEqual([...fake.state.volumes.keys()].sort(), [`computador-${ANA}`, `computador-${BIA}`]);
    assert.deepEqual([...fake.state.networks.keys()].sort(), [`computador-${ANA}`, `computador-${BIA}`]);
    for (const [name, n] of fake.state.networks) {
      // Each network: internal (no way out but the proxy), with the proxy
      // at .2 and the dispatcher at .3; nothing else joined.
      assert.equal(n.Internal, true);
      const base = n.subnet.split('.').slice(0, 2).join('.');
      assert.deepEqual([...n.members.entries()], [['saida', `${base}.0.2`], ['eu', `${base}.0.3`]]);
      assert.equal(n.Labels[LABEL], '1');
      assert.ok(n.Options['com.docker.network.bridge.name'].startsWith('brc-'), name);
      const owner = name.slice('computador-'.length);
      assert.equal(fake.state.containers.get(`computador-${owner}`).spec.HostConfig.NetworkMode, name);
    }
    // A second call does not make anything new.
    await api.call('POST', `/v1/pessoas/${ANA}/run`, { op: 'exec' });
    assert.equal(fake.state.requests.filter((r) => r.url.startsWith('/containers/create')).length, 2);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('calls at once for one person start one computer', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  const api = await serve(cfg);
  try {
    const answers = await Promise.all([1, 2, 3].map(() => api.call('POST', `/v1/pessoas/${ANA}/run`, {})));
    assert.ok(answers.every((a) => a.status === 200));
    assert.equal(fake.state.requests.filter((r) => r.url.startsWith('/containers/create')).length, 1);
    assert.equal(fake.state.requests.filter((r) => r.url.endsWith('/start')).length, 1);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('idle 15 minutes, turned off; the next call turns it on again with its files', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg, advance } = setup(fake, pcs);
  const machines = computers(cfg);
  const api = await serve(cfg, machines);
  try {
    await api.call('POST', `/v1/pessoas/${ANA}/run`, {});
    advance(LIMITS.idleMs - 1000);
    assert.deepEqual(await machines.reap(), []);
    advance(1000);
    assert.deepEqual(await machines.reap(), [ANA]);
    assert.equal(fake.state.containers.get(`computador-${ANA}`).running, false);
    // Same container, same volume: the files are where they were.
    await api.call('POST', `/v1/pessoas/${ANA}/run`, {});
    assert.equal(fake.state.containers.get(`computador-${ANA}`).running, true);
    assert.equal(fake.state.requests.filter((r) => r.url.startsWith('/containers/create')).length, 1);
    assert.ok(fake.state.volumes.has(`computador-${ANA}`));
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('a computer with a call in flight is never turned off', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg, advance } = setup(fake, pcs);
  const machines = computers(cfg);
  const api = await serve(cfg, machines);
  try {
    pcs.holdCalls();
    const pending = api.call('POST', `/v1/pessoas/${ANA}/run`, {});
    while (pcs.calls.length === 0) await new Promise((r) => setTimeout(r, 5));
    advance(LIMITS.idleMs * 2);
    assert.deepEqual(await machines.reap(), []);
    pcs.releaseCalls();
    assert.equal((await pending).status, 200);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('four on: a fifth takes the place of one idle, or waits for a place', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg, advance } = setup(fake, pcs);
  const machines = computers(cfg);
  const api = await serve(cfg, machines);
  try {
    for (const p of people.slice(0, 4)) await api.call('POST', `/v1/pessoas/${p}/run`, {});
    assert.equal(machines.live.size, 4);

    // All four busy: the fifth waits, then gives up (503).
    pcs.holdCalls();
    const busy = people.slice(0, 4).map((p) => api.call('POST', `/v1/pessoas/${p}/run`, {}));
    while (pcs.calls.length < 8) await new Promise((r) => setTimeout(r, 5));
    const fifth = await api.call('POST', `/v1/pessoas/${people[4]}/run`, {});
    assert.equal(fifth.status, 503);
    // Who gave up left the queue.
    assert.equal(machines.waiting.length, 0);
    pcs.releaseCalls();
    await Promise.all(busy);

    // Recently used: still no place (a minute of grace).
    assert.equal((await api.call('POST', `/v1/pessoas/${people[4]}/run`, {})).status, 503);

    // One idle a while: the fifth takes its place; that one is off.
    advance(LIMITS.evictAfterMs);
    await api.call('POST', `/v1/pessoas/${people[1]}/run`, {});
    const answer = await api.call('POST', `/v1/pessoas/${people[4]}/run`, {});
    assert.equal(answer.status, 200);
    assert.equal(machines.live.size, 4);
    assert.equal(machines.live.has(people[4]), true);
    assert.equal(machines.live.has(people[1]), true);
    const off = people.slice(0, 4).filter((p) => !machines.live.has(p));
    assert.equal(off.length, 1);
    assert.equal(fake.state.containers.get(`computador-${off[0]}`).running, false);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('a fifth waiting gets the place as soon as one is turned off', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs, { waitMs: 5000 });
  const machines = computers(cfg);
  const api = await serve(cfg, machines);
  try {
    for (const p of people.slice(0, 4)) await api.call('POST', `/v1/pessoas/${p}/run`, {});
    const fifth = api.call('POST', `/v1/pessoas/${people[4]}/run`, {});
    await new Promise((r) => setTimeout(r, 50));
    await api.call('POST', '/v1/desligar', { pessoa: people[0] });
    assert.equal((await fifth).status, 200);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('delete: container, volume and network go; the others stay', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  const api = await serve(cfg);
  try {
    await api.call('POST', `/v1/pessoas/${ANA}/run`, {});
    await api.call('POST', `/v1/pessoas/${BIA}/run`, {});
    assert.deepEqual((await api.call('POST', '/v1/apagar', { pessoa: ANA })).body, { ok: true, pessoa: ANA, apagado: true });
    assert.equal(fake.state.containers.has(`computador-${ANA}`), false);
    assert.equal(fake.state.volumes.has(`computador-${ANA}`), false);
    assert.equal(fake.state.networks.has(`computador-${ANA}`), false);
    assert.equal(saida.told.has(ANA), false);
    assert.equal(fake.state.containers.has(`computador-${BIA}`), true);
    assert.equal((await api.call('POST', '/v1/apagar', { pessoa: ANA })).status, 200);
    const estado = (await api.call('GET', '/v1/estado')).body;
    assert.deepEqual(estado.computadores.map((c) => c.pessoa), [BIA]);
    assert.equal(estado.vagas, 3);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('the API refuses extra parameters, bad names, no token and browsers', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  const api = await serve(cfg);
  try {
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: ANA, imagem: 'alpine' })).status, 400);
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: 'ana' })).status, 400);
    assert.equal((await api.call('POST', '/v1/ligar', 'not json')).status, 400);
    assert.equal((await api.call('POST', '/v1/pessoas/ana/run', {})).status, 400);
    assert.equal((await api.call('POST', `/v1/pessoas/${ANA}/../../x`, {})).status, 404);
    assert.equal((await api.call('POST', `/v1/pessoas/${ANA}/run`, {}, { authorization: 'Bearer do-computador' })).status, 401);
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: ANA }, { origin: 'https://evil.example' })).status, 403);
    assert.equal((await api.call('POST', '/v1/run', {})).status, 404);
    assert.equal((await api.call('GET', '/v1/ligar')).status, 405);
    assert.equal(fake.state.requests.length, 0);
    assert.equal(pcs.calls.length, 0);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('an empty token refuses everything', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs, { token: '' });
  const api = await serve(cfg);
  try {
    assert.equal((await api.call('GET', '/v1/estado', undefined, { authorization: 'Bearer ' })).status, 401);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('what has the name but is not ours is never touched', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  const api = await serve(cfg);
  try {
    fake.state.containers.set(`computador-${ANA}`, { spec: { Labels: {} }, running: true });
    assert.equal((await api.call('POST', '/v1/apagar', { pessoa: ANA })).status, 502);
    assert.equal((await api.call('POST', `/v1/pessoas/${ANA}/run`, {})).status, 502);
    assert.equal(fake.state.containers.has(`computador-${ANA}`), true);
    fake.state.volumes.set(`computador-${BIA}`, { Labels: {}, members: new Set() });
    assert.equal((await api.call('POST', '/v1/apagar', { pessoa: BIA })).status, 502);
    assert.equal(fake.state.volumes.has(`computador-${BIA}`), true);
    assert.equal(fake.state.requests.some((r) => r.method === 'DELETE'), false);
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('at boot, running computers are adopted and their networks joined', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  try {
    const first = computers(cfg);
    await first.ligar(ANA);
    fake.state.networks.get(`computador-${ANA}`).members.clear();
    saida.told.clear();
    const after = computers(cfg);
    await after.adopt();
    assert.equal(after.live.has(ANA), true);
    assert.equal(saida.told.has(ANA), true);
    assert.deepEqual([...fake.state.networks.get(`computador-${ANA}`).members.keys()], ['saida', 'eu']);
    // Not used since the restart: it may give its place at once, so more
    // than four on after a restart never blocks the queue.
    for (const p of people.slice(0, 3)) await after.ligar(p);
    await after.ligar(people[3]);
    assert.equal(after.live.has(ANA), false);
    assert.equal(after.live.size, 4);
  } finally { pcs.close(); fake.close(); }
});

test('it listens only off the computers\' networks', async () => {
  const fake = await fakeDocker();
  try {
    assert.deepEqual(await listenAddresses({ docker: docker(fake.socketPath), self: 'eu' }), ['172.18.0.5']);
  } finally { fake.close(); }
});

test('the computers\' resolv.conf is found where compose mounts it', async () => {
  const fake = await fakeDocker();
  try {
    assert.equal(await resolvConfSource({ docker: docker(fake.socketPath), self: 'eu' }), '/srv/supernova/computador/resolv.conf');
  } finally { fake.close(); }
});

test('the image is pinned by id at boot', async () => {
  const fake = await fakeDocker();
  try {
    assert.equal(await pinImage(docker(fake.socketPath), 'supernova-computador:latest'), 'sha256:abc');
    await assert.rejects(pinImage(docker(fake.socketPath), 'alpine'));
  } finally { fake.close(); }
});

test('the person\'s sites reach the proxy, plain hosts only', async () => {
  const fake = await fakeDocker();
  const pcs = await fakeComputers();
  const { cfg } = setup(fake, pcs);
  const api = await serve(cfg);
  try {
    // Before the computer is on, kept for when it is.
    assert.equal((await api.call('POST', `/v1/pessoas/${ANA}/sites`, { sites: ['Exemplo.com'] })).status, 200);
    assert.equal(saida.told.has(ANA), false);
    await api.call('POST', `/v1/pessoas/${ANA}/run`, {});
    assert.deepEqual(saida.told.get(ANA).sites, ['exemplo.com']);
    await api.call('POST', `/v1/pessoas/${ANA}/sites`, { sites: ['exemplo.com', 'outro.org'] });
    assert.deepEqual(saida.told.get(ANA).sites, ['exemplo.com', 'outro.org']);
    for (const bad of [{ sites: ['10.0.0.1'] }, { sites: ['http://a.com'] }, { sites: 'a.com' }, { sites: [], x: 1 }]) {
      assert.equal((await api.call('POST', `/v1/pessoas/${ANA}/sites`, bad)).status, 400, JSON.stringify(bad));
    }
  } finally { api.close(); pcs.close(); fake.close(); }
});

test('configuration: tokens and image are required', () => {
  const env = {
    DESPACHANTE_TOKEN: 'a', COMPUTADOR_TOKEN: 'b', DESPACHANTE_IMAGEM: 'img',
    SAIDA_TOKEN: 'c', SAIDA_CREDENCIAL: 'd',
  };
  const cfg = configFromEnv(env);
  assert.equal(cfg.runtime, 'runsc');
  assert.equal(cfg.computerUrl(ANA), `http://computador-${ANA}:7070`);
  for (const key of Object.keys(env)) {
    assert.throws(() => configFromEnv({ ...env, [key]: ' ' }), new RegExp(key));
  }
});
