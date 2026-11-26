import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import {
  createServer, computerSpec, personOf, listenAddresses, pinImage, configFromEnv,
  UserError, LIMITS, LABEL,
} from '../despachante.mjs';
import { docker } from '../docker.mjs';

const ANA = 'a'.repeat(32);
const BIA = 'b'.repeat(32);

// A fake Docker Engine on a Unix socket: containers and volumes in memory,
// every request recorded.
async function fakeDocker() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'docker-'));
  const socketPath = path.join(dir, 'docker.sock');
  const state = { containers: new Map(), volumes: new Set(), requests: [] };
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      const body = text ? JSON.parse(text) : null;
      state.requests.push({ method: req.method, url: req.url, body });
      const reply = (status, json) => {
        const out = json === undefined ? '' : JSON.stringify(json);
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(out);
      };
      const url = new URL(req.url, 'http://docker');
      let m;
      if (req.method === 'POST' && url.pathname === '/containers/create') {
        const name = url.searchParams.get('name');
        if (state.containers.has(name)) return reply(409, { message: 'conflict' });
        state.containers.set(name, { spec: body, running: false });
        for (const mount of body.HostConfig.Mounts) state.volumes.add(mount.Source);
        return reply(201, { Id: name });
      }
      if ((m = url.pathname.match(/^\/containers\/([^/]+)\/json$/))) {
        if (m[1] === 'eu') {
          return reply(200, { NetworkSettings: { Networks: {
            supernova_computador: { IPAddress: '172.30.0.2' },
            supernova_default: { IPAddress: '172.18.0.5' },
          } } });
        }
        const c = state.containers.get(m[1]);
        if (!c) return reply(404, { message: 'no such container' });
        return reply(200, { Config: { Labels: c.spec.Labels }, State: { Running: c.running } });
      }
      if ((m = url.pathname.match(/^\/containers\/([^/]+)\/start$/))) {
        const c = state.containers.get(m[1]);
        if (!c) return reply(404, {});
        if (c.running) return reply(304);
        c.running = true;
        return reply(204);
      }
      if ((m = url.pathname.match(/^\/containers\/([^/]+)\/stop$/))) {
        const c = state.containers.get(m[1]);
        if (!c) return reply(404, {});
        if (!c.running) return reply(304);
        c.running = false;
        return reply(204);
      }
      if (req.method === 'DELETE' && (m = url.pathname.match(/^\/containers\/([^/]+)$/))) {
        return reply(state.containers.delete(m[1]) ? 204 : 404, {});
      }
      if (req.method === 'DELETE' && (m = url.pathname.match(/^\/volumes\/([^/]+)$/))) {
        return reply(state.volumes.delete(m[1]) ? 204 : 404, {});
      }
      if (url.pathname === '/containers/json') {
        const list = [...state.containers.entries()]
          .filter(([, c]) => c.spec.Labels && c.spec.Labels[LABEL] === '1')
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

function config(fake, extra = {}) {
  return {
    token: 'segredo',
    computerToken: 'do-computador',
    image: 'sha256:abc',
    network: 'supernova_computador',
    runtime: 'runsc',
    computerUrl: '',
    docker: docker(fake.socketPath),
    ...extra,
  };
}

async function serve(cfg) {
  const server = createServer(cfg);
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
    { pessoa: '../etc/passwd'.padEnd(32, 'a') }, { pessoa: ANA, imagem: 'alpine' },
    { pessoa: ANA, runtime: 'runc' }, [ANA], null, { pessoa: 7 },
  ]) {
    assert.throws(() => personOf(bad), UserError, JSON.stringify(bad));
  }
});

test('a computer is made with the fixed parameters only', () => {
  const spec = computerSpec({ image: 'sha256:abc', computerToken: 't', network: 'rede', runtime: 'runsc' }, ANA);
  assert.equal(spec.Image, 'sha256:abc');
  assert.equal(spec.HostConfig.Runtime, 'runsc');
  assert.equal(spec.HostConfig.Memory, 1536 * 1024 * 1024);
  assert.deepEqual(spec.HostConfig.CapDrop, ['ALL']);
  assert.deepEqual(spec.HostConfig.SecurityOpt, ['no-new-privileges:true']);
  assert.equal(spec.HostConfig.NetworkMode, 'rede');
  assert.deepEqual(spec.HostConfig.Mounts, [{ Type: 'volume', Source: `computador-${ANA}`, Target: '/home/pwuser' }]);
  // Nothing of the host: no bind mounts, no privileges, no host network.
  assert.equal(spec.HostConfig.Binds, undefined);
  assert.equal(spec.HostConfig.Privileged, undefined);
  assert.equal(spec.Labels[LABEL], '1');
});

test('on, on again, off, delete: one container and one volume per person', async () => {
  const fake = await fakeDocker();
  const api = await serve(config(fake));
  try {
    assert.deepEqual((await api.call('POST', '/v1/ligar', { pessoa: ANA })).body, { ok: true, pessoa: ANA, ligado: true });
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: ANA })).status, 200);
    await api.call('POST', '/v1/ligar', { pessoa: BIA });
    assert.equal(fake.state.containers.size, 2);
    const creates = fake.state.requests.filter((r) => r.url.startsWith('/containers/create'));
    assert.equal(creates.length, 2);
    // Two people, two volumes: neither computer sees the other's (K-I4).
    assert.deepEqual([...fake.state.volumes].sort(), [`computador-${ANA}`, `computador-${BIA}`]);

    await api.call('POST', '/v1/desligar', { pessoa: ANA });
    const estado = (await api.call('GET', '/v1/estado')).body.computadores;
    assert.deepEqual(estado.sort((a, b) => a.pessoa.localeCompare(b.pessoa)), [
      { pessoa: ANA, ligado: false }, { pessoa: BIA, ligado: true },
    ]);

    assert.deepEqual((await api.call('POST', '/v1/apagar', { pessoa: ANA })).body, { ok: true, pessoa: ANA, apagado: true });
    assert.equal(fake.state.containers.has(`computador-${ANA}`), false);
    assert.equal(fake.state.volumes.has(`computador-${ANA}`), false);
    assert.equal(fake.state.containers.has(`computador-${BIA}`), true);
    // Deleting what is gone is fine; turning off what is gone too.
    assert.equal((await api.call('POST', '/v1/apagar', { pessoa: ANA })).status, 200);
    assert.equal((await api.call('POST', '/v1/desligar', { pessoa: ANA })).status, 200);
  } finally { api.close(); fake.close(); }
});

test('the API refuses extra parameters, bad names, no token and browsers', async () => {
  const fake = await fakeDocker();
  const api = await serve(config(fake));
  try {
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: ANA, imagem: 'alpine' })).status, 400);
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: 'ana' })).status, 400);
    assert.equal((await api.call('POST', '/v1/ligar', 'not json')).status, 400);
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: ANA }, { authorization: 'Bearer errado' })).status, 401);
    assert.equal((await api.call('POST', '/v1/ligar', { pessoa: ANA }, { origin: 'https://evil.example' })).status, 403);
    assert.equal((await api.call('POST', '/v1/qualquer', { pessoa: ANA })).status, 404);
    assert.equal((await api.call('GET', '/v1/ligar')).status, 405);
    assert.equal(fake.state.requests.length, 0);
  } finally { api.close(); fake.close(); }
});

test('an empty token refuses everything', async () => {
  const fake = await fakeDocker();
  const api = await serve(config(fake, { token: '' }));
  try {
    assert.equal((await api.call('GET', '/v1/estado', undefined, { authorization: 'Bearer ' })).status, 401);
  } finally { api.close(); fake.close(); }
});

test('a container of that name that is not a computer is never touched', async () => {
  const fake = await fakeDocker();
  fake.state.containers.set(`computador-${ANA}`, { spec: { Labels: {}, HostConfig: { Mounts: [] } }, running: true });
  const api = await serve(config(fake));
  try {
    assert.equal((await api.call('POST', '/v1/apagar', { pessoa: ANA })).status, 502);
    assert.equal(fake.state.containers.has(`computador-${ANA}`), true);
    assert.equal(fake.state.requests.some((r) => r.method === 'DELETE'), false);
  } finally { api.close(); fake.close(); }
});

test('calls to the computer carry its token, which Supernova does not have', async () => {
  const fake = await fakeDocker();
  let seen;
  const computer = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      seen = { url: req.url, auth: req.headers.authorization, body: Buffer.concat(chunks).toString('utf8') };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, out: 'Olá' }));
    });
  });
  computer.listen(0, '127.0.0.1');
  await once(computer, 'listening');
  const api = await serve(config(fake, { computerUrl: `http://127.0.0.1:${computer.address().port}` }));
  try {
    const answer = await api.call('POST', '/v1/run', { op: 'exec', cmd: 'echo ção' });
    assert.deepEqual(answer.body, { ok: true, out: 'Olá' });
    assert.equal(seen.url, '/v1/run');
    assert.equal(seen.auth, 'Bearer do-computador');
    assert.equal(JSON.parse(seen.body).cmd, 'echo ção');
    await api.call('POST', '/v1/mcp', { op: 'listar' });
    assert.equal(seen.url, '/v1/mcp');
    // Without the dispatcher's token, nothing reaches the computer.
    seen = undefined;
    assert.equal((await api.call('POST', '/v1/run', {}, { authorization: 'Bearer do-computador' })).status, 401);
    assert.equal(seen, undefined);
  } finally { api.close(); computer.close(); fake.close(); }
});

test('it listens only off the computers\' network', async () => {
  const fake = await fakeDocker();
  const original = os.hostname;
  try {
    const cfg = { ...config(fake), listen: '' };
    // os.hostname() is the container id; the fake answers for "eu".
    os.hostname = () => 'eu';
    assert.deepEqual(await listenAddresses(cfg), ['172.18.0.5']);
  } finally { os.hostname = original; fake.close(); }
});

test('the image is pinned by id at boot', async () => {
  const fake = await fakeDocker();
  try {
    assert.equal(await pinImage(docker(fake.socketPath), 'supernova-computador:latest'), 'sha256:abc');
    await assert.rejects(pinImage(docker(fake.socketPath), 'alpine'));
  } finally { fake.close(); }
});

test('configuration: tokens, image and network are required', () => {
  const env = { DESPACHANTE_TOKEN: 'a', COMPUTADOR_TOKEN: 'b', DESPACHANTE_IMAGEM: 'img', DESPACHANTE_REDE: 'rede' };
  assert.equal(configFromEnv(env).runtime, 'runsc');
  for (const key of Object.keys(env)) {
    assert.throws(() => configFromEnv({ ...env, [key]: ' ' }), new RegExp(key));
  }
  assert.ok(LIMITS.memoryBytes === 1536 * 1024 * 1024);
});
