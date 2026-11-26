// The dispatcher (PRD-K, K20): the only part of Supernova that holds the
// Docker socket. It turns people's computers on and off and deletes them,
// with parameters fixed here (image by id, gVisor, 1.5 GB, no capabilities,
// the computers' network, one volume per person); the API takes a person's
// hash and nothing else. It also carries Supernova's calls to a computer,
// so Supernova is not on the computers' network (PRD-K, section 3.3).
//
// It listens only on its side of Supernova's network: a computer, on the
// other network, cannot reach it.

import http from 'node:http';
import os from 'node:os';
import { timingSafeEqual } from 'node:crypto';
import { docker as dockerClient } from './docker.mjs';

export const PERSON = /^[0-9a-f]{32}$/;
export const LABEL = 'supernova.despachante';

// Fixed parameters of every computer (K19, K20). Not from the API.
export const LIMITS = {
  memoryBytes: 1536 * 1024 * 1024,
  nanoCpus: 2_000_000_000,
  pids: 512,
  shmBytes: 512 * 1024 * 1024,
  stopSeconds: 10,
  bodyBytes: 8 * 1024 * 1024,
  proxyMs: 15 * 60_000,
};

export const containerName = (person) => `computador-${person}`;
export const volumeName = (person) => `computador-${person}`;

export class UserError extends Error {}

/// The container a person's computer is made of. Everything but the person
/// comes from the dispatcher's own configuration.
export function computerSpec(config, person) {
  return {
    Image: config.image,
    Env: [`COMPUTADOR_TOKEN=${config.computerToken}`],
    Labels: { [LABEL]: '1', 'supernova.pessoa': person },
    HostConfig: {
      Runtime: config.runtime,
      Memory: LIMITS.memoryBytes,
      MemorySwap: LIMITS.memoryBytes,
      NanoCpus: LIMITS.nanoCpus,
      PidsLimit: LIMITS.pids,
      ShmSize: LIMITS.shmBytes,
      CapDrop: ['ALL'],
      SecurityOpt: ['no-new-privileges:true'],
      // Docker's DNS does not answer inside gVisor on this network.
      Dns: ['1.1.1.1', '8.8.8.8'],
      Mounts: [{ Type: 'volume', Source: volumeName(person), Target: '/home/pwuser' }],
      NetworkMode: config.network,
      RestartPolicy: { Name: 'no' },
    },
    NetworkingConfig: { EndpointsConfig: { [config.network]: {} } },
  };
}

/// The person named by a request body: exactly {"pessoa": "<hash>"}.
export function personOf(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new UserError('body must be a JSON object');
  }
  const keys = Object.keys(body);
  if (keys.length !== 1 || keys[0] !== 'pessoa') {
    throw new UserError('the only parameter is pessoa');
  }
  if (typeof body.pessoa !== 'string' || !PERSON.test(body.pessoa)) {
    throw new UserError('pessoa must be a person hash (32 hex digits)');
  }
  return body.pessoa;
}

export function computers(config) {
  const d = config.docker;

  async function ours(person) {
    const found = await d.request('GET', `/containers/${containerName(person)}/json`);
    if (found.status === 404) return null;
    if (found.status !== 200) throw new Error(`docker: ${found.status} ${found.text}`);
    // A container of that name that we did not make is not touched.
    if (!found.body.Config || !found.body.Config.Labels || found.body.Config.Labels[LABEL] !== '1') {
      throw new Error(`${containerName(person)} exists and is not a computer`);
    }
    return found.body;
  }

  return {
    async ligar(person) {
      let existing = await ours(person);
      if (!existing) {
        const made = await d.request('POST', `/containers/create?name=${containerName(person)}`, computerSpec(config, person));
        if (made.status !== 201) throw new Error(`docker create: ${made.status} ${made.text}`);
      }
      const started = await d.request('POST', `/containers/${containerName(person)}/start`);
      if (started.status !== 204 && started.status !== 304) throw new Error(`docker start: ${started.status} ${started.text}`);
      return { pessoa: person, ligado: true };
    },
    async desligar(person) {
      if (!(await ours(person))) return { pessoa: person, ligado: false };
      const stopped = await d.request('POST', `/containers/${containerName(person)}/stop?t=${LIMITS.stopSeconds}`);
      if (stopped.status !== 204 && stopped.status !== 304) throw new Error(`docker stop: ${stopped.status} ${stopped.text}`);
      return { pessoa: person, ligado: false };
    },
    async apagar(person) {
      if (await ours(person)) {
        const removed = await d.request('DELETE', `/containers/${containerName(person)}?force=true`);
        if (removed.status !== 204 && removed.status !== 404) throw new Error(`docker rm: ${removed.status} ${removed.text}`);
      }
      const volume = await d.request('DELETE', `/volumes/${volumeName(person)}?force=true`);
      if (volume.status !== 204 && volume.status !== 404) throw new Error(`docker volume rm: ${volume.status} ${volume.text}`);
      return { pessoa: person, apagado: true };
    },
    async estado() {
      const filters = encodeURIComponent(JSON.stringify({ label: [`${LABEL}=1`] }));
      const listed = await d.request('GET', `/containers/json?all=true&filters=${filters}`);
      if (listed.status !== 200) throw new Error(`docker ps: ${listed.status} ${listed.text}`);
      return {
        computadores: listed.body.map((c) => ({
          pessoa: c.Labels['supernova.pessoa'],
          ligado: c.State === 'running',
        })),
      };
    },
  };
}

export function authorized(req, token) {
  if (!token) return false;
  const given = Buffer.from(String(req.headers['authorization'] || ''));
  const wanted = Buffer.from(`Bearer ${token}`);
  return given.length === wanted.length && timingSafeEqual(given, wanted);
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > LIMITS.bodyBytes) { req.destroy(); reject(new UserError('body too large')); return; }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/// Carry a call to the computer, with the computer's token, which Supernova
/// does not have.
function forward(config, path, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(path, config.computerUrl);
    const req = http.request(target, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': body.length,
        authorization: `Bearer ${config.computerToken}`,
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.setTimeout(LIMITS.proxyMs, () => req.destroy(new Error('the computer did not answer')));
    req.end(body);
  });
}

export function createServer(config) {
  const pcs = computers(config);
  const actions = {
    '/v1/ligar': pcs.ligar,
    '/v1/desligar': pcs.desligar,
    '/v1/apagar': pcs.apagar,
  };
  return http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true });
    const known = req.url in actions || req.url === '/v1/estado' || req.url === '/v1/run' || req.url === '/v1/mcp';
    if (!known) return send(res, 404, { ok: false, error: 'not found' });
    if (req.headers['origin'] !== undefined) return send(res, 403, { ok: false, error: 'requests from a browser are refused' });
    if (!authorized(req, config.token)) return send(res, 401, { ok: false, error: 'unauthorized' });
    try {
      if (req.url === '/v1/estado') {
        if (req.method !== 'GET') return send(res, 405, { ok: false, error: 'GET only' });
        return send(res, 200, { ok: true, ...(await pcs.estado()) });
      }
      if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'POST only' });
      const raw = await readBody(req);
      if (req.url === '/v1/run' || req.url === '/v1/mcp') {
        if (!config.computerUrl) return send(res, 503, { ok: false, error: 'no computer configured' });
        const answer = await forward(config, req.url, raw);
        res.writeHead(answer.status, { 'content-type': 'application/json', 'content-length': answer.body.length });
        return res.end(answer.body);
      }
      let body;
      try { body = JSON.parse(raw.toString('utf8')); } catch { throw new UserError('body must be JSON'); }
      return send(res, 200, { ok: true, ...(await actions[req.url](personOf(body))) });
    } catch (e) {
      const message = String(e && e.message ? e.message : e).split('\n')[0].slice(0, 500);
      return send(res, e instanceof UserError ? 400 : 502, { ok: false, error: message });
    }
  });
}

/// The addresses to listen on: this container's addresses on every network
/// but the computers'. Asked of Docker, so a computer finds nothing to
/// connect to on its side.
export async function listenAddresses(config) {
  if (config.listen) return [config.listen];
  const self = await config.docker.request('GET', `/containers/${os.hostname()}/json`);
  if (self.status !== 200) throw new Error(`cannot inspect myself: ${self.status}`);
  const networks = self.body.NetworkSettings && self.body.NetworkSettings.Networks || {};
  const addresses = Object.entries(networks)
    .filter(([name]) => name !== config.network)
    .map(([, net]) => net.IPAddress)
    .filter(Boolean);
  if (addresses.length === 0) throw new Error('no network besides the computers\' to listen on');
  return addresses;
}

/// The image every computer runs, pinned to its id at boot (K20).
export async function pinImage(d, name) {
  const found = await d.request('GET', `/images/${encodeURIComponent(name)}/json`);
  if (found.status !== 200) throw new Error(`image ${name} not found: ${found.status}`);
  return found.body.Id;
}

export function configFromEnv(env) {
  const required = (name) => {
    const value = (env[name] || '').trim();
    if (!value) throw new Error(`${name} is required`);
    return value;
  };
  return {
    token: required('DESPACHANTE_TOKEN'),
    computerToken: required('COMPUTADOR_TOKEN'),
    imageName: required('DESPACHANTE_IMAGEM'),
    network: required('DESPACHANTE_REDE'),
    runtime: (env.DESPACHANTE_RUNTIME || 'runsc').trim(),
    computerUrl: (env.DESPACHANTE_COMPUTADOR_URL || '').trim(),
    port: Number(env.DESPACHANTE_PORTA || 7071),
    listen: (env.DESPACHANTE_ESCUTA || '').trim(),
    socket: (env.DOCKER_SOCKET || '/var/run/docker.sock').trim(),
  };
}

async function main() {
  let config;
  try {
    config = configFromEnv(process.env);
  } catch (e) {
    console.error(`despachante: ${e.message}`);
    process.exit(1);
  }
  config.docker = dockerClient(config.socket);
  config.image = await pinImage(config.docker, config.imageName);
  const addresses = await listenAddresses(config);
  for (const address of addresses) {
    createServer(config).listen(config.port, address, () => {
      console.log(`despachante: listening on ${address}:${config.port}, computers run ${config.image}`);
    });
  }
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  main().catch((e) => {
    console.error(`despachante: ${e.message}`);
    process.exit(1);
  });
}
