// The dispatcher (PRD-K, K20): the only part of Supernova that holds the
// Docker socket. Each person has a computer of their own (K-04): a
// container, a volume and a network, all named by the person's hash. The
// dispatcher turns it on at the person's first call, off after 15 minutes
// idle (K18), keeps at most 4 on (K19), and deletes it on /esquecer. The
// parameters (image by id, gVisor, 1.5 GB, no capabilities, DNS) are fixed
// here; the API takes a person's hash and nothing else.
//
// It also carries Supernova's calls to a computer, so Supernova is on no
// computer's network (PRD-K, section 3.3). Each computer has its own
// network, so computers do not see each other (K-I4); the dispatcher joins
// each one, but listens only on Supernova's side.

import http from 'node:http';
import os from 'node:os';
import net from 'node:net';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { docker as dockerClient } from './docker.mjs';
import { screens, createScreenServer, SCREEN_MS } from './tela.mjs';

// The person's hash Supernova uses (PRD-S, S19): 16 hex digits.
export const PERSON = /^[0-9a-f]{16}$/;
export const LABEL = 'supernova.despachante';

// Fixed parameters of every computer (K18, K19, K20). Not from the API.
export const LIMITS = {
  memoryBytes: 1536 * 1024 * 1024,
  nanoCpus: 2_000_000_000,
  pids: 512,
  shmBytes: 512 * 1024 * 1024,
  stopSeconds: 10,
  bodyBytes: 8 * 1024 * 1024,
  proxyMs: 15 * 60_000,
  maxOn: 4,
  idleMs: 15 * 60_000,
  // A computer idle this long may be turned off for someone waiting.
  evictAfterMs: 60_000,
  // How long a call waits for a free place before giving up.
  waitMs: 60_000,
  // How long a computer may take to answer its health check after start.
  bootMs: 60_000,
};

export const containerName = (person) => `computador-${person}`;
export const volumeName = (person) => `computador-${person}`;
export const networkName = (person) => `computador-${person}`;
// Linux bridge names stop at 15 characters. The host firewall matches them
// all with `brc+` (docs/operations/COMPUTADOR.md).
export const bridgeName = (person) => `brc-${person.slice(0, 11)}`;

/// The browser's proxy credential for a person (the proxy derives the same).
export function credentialFor(master, person) {
  return createHmac('sha256', master).update(`saida:${person}`).digest('hex');
}

/// A computer's own service token, derived from the dispatcher's master.
/// Each computer holds only its own: one that leaks it opens no other.
export function computerTokenFor(master, person) {
  return createHmac('sha256', master).update(`computador:${person}`).digest('hex');
}

const HOST = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;

/// The sites a person approved for the shell (K21): plain host names.
export function sitesOf(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) throw new UserError('body must be a JSON object');
  if (Object.keys(body).join(',') !== 'sites' || !Array.isArray(body.sites) || body.sites.length > 200) {
    throw new UserError('expected {"sites": [...]}');
  }
  const sites = body.sites.map((x) => String(x).toLowerCase());
  if (!sites.every((x) => HOST.test(x) && !net.isIP(x))) throw new UserError('a site is a host name');
  return sites;
}

/// The fixed addresses on a person's network: the proxy at .2, the
/// dispatcher at .3; the computer gets the next free one.
export function fixedAddresses(subnet) {
  const [base] = subnet.split('/');
  const parts = base.split('.').map(Number);
  const at = (n) => [parts[0], parts[1], parts[2], parts[3] + n].join('.');
  return { saida: at(2), despachante: at(3) };
}

export class UserError extends Error {}
export class NoPlace extends Error {}
export class NoScreen extends Error {}

const labels = (person) => ({ [LABEL]: '1', 'supernova.pessoa': person });

/// The container a person's computer is made of. Everything but the person
/// comes from the dispatcher's own configuration.
export function computerSpec(config, person) {
  return {
    Image: config.image,
    Env: [
      `COMPUTADOR_TOKEN=${computerTokenFor(config.computerToken, person)}`,
      // The only way out (K-05): the proxy on the person's network. The
      // launcher gives the credential to the browser's user, never the
      // shell's.
      `SAIDA_URL=http://${config.saidaAddress}:3128`,
      `SAIDA_USUARIO=${person}`,
      `SAIDA_SENHA=${credentialFor(config.saida.master, person)}`,
    ],
    Labels: labels(person),
    HostConfig: {
      Runtime: config.runtime,
      Memory: LIMITS.memoryBytes,
      MemorySwap: LIMITS.memoryBytes,
      NanoCpus: LIMITS.nanoCpus,
      PidsLimit: LIMITS.pids,
      ShmSize: LIMITS.shmBytes,
      CapDrop: ['ALL'],
      // The launcher's, and nothing more: it hands the service to svc and
      // the shell to sh (K-05, K-07).
      CapAdd: ['CHOWN', 'SETUID', 'SETGID', 'KILL'],
      SecurityOpt: ['no-new-privileges:true'],
      Mounts: [
        { Type: 'volume', Source: volumeName(person), Target: '/home/pwuser' },
        // Docker's DNS does not answer inside gVisor on a user network, and
        // the computer does not run as root: public resolvers, read-only.
        { Type: 'bind', Source: config.resolvConf, Target: '/etc/resolv.conf', ReadOnly: true },
      ],
      NetworkMode: networkName(person),
      RestartPolicy: { Name: 'no' },
    },
    NetworkingConfig: { EndpointsConfig: { [networkName(person)]: {} } },
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
  return checkPerson(body.pessoa);
}

export function checkPerson(person) {
  if (typeof person !== 'string' || !PERSON.test(person)) {
    throw new UserError('pessoa must be a person hash (16 hex digits)');
  }
  return person;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function computers(config) {
  const d = config.docker;
  const clock = config.clock || (() => Date.now());
  // What the dispatcher knows of the computers it turned on: when each was
  // last used and how many calls are in flight. Lost on restart: running
  // computers then count as used at boot.
  const live = new Map();
  const waiting = [];

  const isOurs = (labelsOf) => !!labelsOf && labelsOf[LABEL] === '1';

  async function container(person) {
    const found = await d.request('GET', `/containers/${containerName(person)}/json`);
    if (found.status === 404) return null;
    if (found.status !== 200) throw new Error(`docker: ${found.status} ${found.text}`);
    // A container of that name that we did not make is not touched.
    if (!isOurs(found.body.Config && found.body.Config.Labels)) {
      throw new Error(`${containerName(person)} exists and is not a computer`);
    }
    return found.body;
  }

  async function ensure(kind, path, body) {
    const made = await d.request('POST', path, body);
    if (made.status === 201) return;
    if (made.status === 409) {
      // Already there: it must be ours.
      const listPath = kind === 'volume' ? `/volumes/${body.Name}` : `/networks/${body.Name}`;
      const found = await d.request('GET', listPath);
      if (found.status === 200 && isOurs(found.body.Labels)) return;
      throw new Error(`${body.Name} exists and is not a computer's`);
    }
    throw new Error(`docker ${kind} create: ${made.status} ${made.text}`);
  }

  async function connect(person, container, address) {
    const joined = await d.request('POST', `/networks/${networkName(person)}/connect`, {
      Container: container,
      EndpointConfig: { IPAMConfig: { IPv4Address: address } },
    });
    // 403/409: already connected.
    if (joined.status !== 200 && joined.status !== 403 && joined.status !== 409) {
      throw new Error(`docker network connect ${container}: ${joined.status} ${joined.text}`);
    }
  }

  /// The person's network with the proxy and the dispatcher on it, at their
  /// fixed addresses; the proxy told whose address it is and their sites.
  async function joinNetwork(person) {
    const found = await d.request('GET', `/networks/${networkName(person)}`);
    if (found.status !== 200) throw new Error(`docker network inspect: ${found.status} ${found.text}`);
    const ipam = found.body.IPAM && found.body.IPAM.Config && found.body.IPAM.Config[0];
    if (!ipam || !ipam.Subnet) throw new Error('the person\'s network has no subnet');
    const fixed = fixedAddresses(ipam.Subnet);
    await connect(person, config.saida.container, fixed.saida);
    if (config.self) await connect(person, config.self, fixed.despachante);
    await tellSaida(person, fixed.saida);
    return fixed;
  }

  const addresses = new Map();
  const sites = new Map();

  async function tellSaida(person, address) {
    addresses.set(person, address);
    const res = await fetch(new URL(`/v1/pessoas/${person}`, config.saida.admin), {
      method: 'PUT',
      headers: { authorization: `Bearer ${config.saida.token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ endereco: address, sites: sites.get(person) || [] }),
    });
    if (!res.ok) throw new Error(`saida: ${res.status}`);
  }

  async function forgetSaida(person) {
    addresses.delete(person);
    sites.delete(person);
    const res = await fetch(new URL(`/v1/pessoas/${person}`, config.saida.admin), {
      method: 'DELETE',
      headers: { authorization: `Bearer ${config.saida.token}` },
    });
    if (!res.ok) throw new Error(`saida: ${res.status}`);
  }

  async function create(person) {
    await ensure('network', '/networks/create', {
      Name: networkName(person),
      Driver: 'bridge',
      // No route out: everything leaves through the proxy (K-05).
      Internal: true,
      Labels: labels(person),
      Options: { 'com.docker.network.bridge.name': bridgeName(person) },
    });
    await ensure('volume', '/volumes/create', { Name: volumeName(person), Labels: labels(person) });
    const fixed = await joinNetwork(person);
    const spec = computerSpec({ ...config, saidaAddress: fixed.saida }, person);
    const made = await d.request('POST', `/containers/create?name=${containerName(person)}`, spec);
    if (made.status !== 201) throw new Error(`docker create: ${made.status} ${made.text}`);
  }

  async function healthy(person) {
    const deadline = Date.now() + LIMITS.bootMs;
    for (;;) {
      try {
        const res = await fetch(new URL('/health', config.computerUrl(person)), { signal: AbortSignal.timeout(2000) });
        if (res.ok) return;
      } catch { /* not up yet */ }
      if (Date.now() > deadline) throw new Error('the computer did not come up');
      await sleep(config.pollMs ?? 250);
    }
  }

  async function start(person) {
    if (!(await container(person))) await create(person);
    await joinNetwork(person);
    const started = await d.request('POST', `/containers/${containerName(person)}/start`);
    if (started.status !== 204 && started.status !== 304) throw new Error(`docker start: ${started.status} ${started.text}`);
    await healthy(person);
  }

  async function stop(person) {
    live.delete(person);
    if (!(await container(person))) return;
    const stopped = await d.request('POST', `/containers/${containerName(person)}/stop?t=${LIMITS.stopSeconds}`);
    if (stopped.status !== 204 && stopped.status !== 304 && stopped.status !== 404) {
      throw new Error(`docker stop: ${stopped.status} ${stopped.text}`);
    }
    wake();
  }

  function wake() {
    while (waiting.length > 0 && placeFree()) waiting.shift()();
  }

  function placeFree() {
    return live.size < LIMITS.maxOn;
  }

  /// The computer that may make room: the one idle longest, idle at least
  /// a minute, with no call in flight.
  function evictable() {
    let pick = null;
    for (const [person, state] of live) {
      if (state.inflight > 0 || state.starting) continue;
      if (clock() - state.lastUsed < LIMITS.evictAfterMs) continue;
      if (!pick || state.lastUsed < live.get(pick).lastUsed) pick = person;
    }
    return pick;
  }

  /// A place for this person's computer: theirs if it is on; a free one;
  /// the one idle longest; or wait (K19, section 3.3).
  async function place(person) {
    // Waiting is real time; the clock is for idleness.
    const deadline = Date.now() + (config.waitMs ?? LIMITS.waitMs);
    for (;;) {
      if (live.has(person)) return false;
      if (placeFree()) {
        live.set(person, { lastUsed: clock(), inflight: 0, starting: true });
        return true;
      }
      const victim = evictable();
      if (victim) {
        await stop(victim);
        continue;
      }
      const left = deadline - Date.now();
      if (left <= 0) throw new NoPlace('no free computer place; try again shortly');
      await new Promise((resolve) => {
        const waiter = () => { clearTimeout(timer); resolve(); };
        const timer = setTimeout(() => {
          // Leave the queue on our own; nothing stays behind.
          const at = waiting.indexOf(waiter);
          if (at >= 0) waiting.splice(at, 1);
          resolve();
        }, Math.min(left, 1000));
        waiting.push(waiter);
      });
    }
  }

  async function ligar(person) {
    const fresh = await place(person);
    const state = live.get(person);
    if (fresh) {
      // Calls for the same person that arrive meanwhile wait for this start.
      state.ready = start(person).then(
        () => { state.starting = false; },
        (e) => {
          if (live.get(person) === state) live.delete(person);
          wake();
          throw e;
        },
      );
    }
    await state.ready;
    return { pessoa: person, ligado: true };
  }

  /// Run a call on the person's computer, turning it on first if needed.
  async function use(person, work) {
    let state;
    // Deleted or turned off between turning on and using: turn on again.
    while (!state) {
      await ligar(person);
      state = live.get(person);
    }
    state.inflight += 1;
    state.lastUsed = clock();
    try {
      return await work();
    } finally {
      state.inflight -= 1;
      state.lastUsed = clock();
    }
  }

  /// Keep a computer on while its screen is open (K-09): it counts as a
  /// call in flight. Returns how to let go.
  async function hold(person) {
    await ligar(person);
    const state = live.get(person);
    state.inflight += 1;
    let held = true;
    return () => {
      if (!held) return;
      held = false;
      state.inflight -= 1;
      state.lastUsed = clock();
    };
  }

  /// Turn off what was idle 15 minutes (K18).
  async function reap() {
    const idle = [...live.entries()]
      .filter(([, s]) => s.inflight === 0 && !s.starting && clock() - s.lastUsed >= LIMITS.idleMs)
      .map(([person]) => person);
    for (const person of idle) await stop(person);
    return idle;
  }

  /// At boot: the running computers count as used now, but may give their
  /// place at once (more than four may be on after a restart).
  async function adopt() {
    const filters = encodeURIComponent(JSON.stringify({ label: [`${LABEL}=1`], status: ['running'] }));
    const listed = await d.request('GET', `/containers/json?filters=${filters}`);
    if (listed.status !== 200) throw new Error(`docker ps: ${listed.status} ${listed.text}`);
    for (const c of listed.body) {
      const person = c.Labels['supernova.pessoa'];
      if (PERSON.test(person || '')) {
        live.set(person, { lastUsed: clock() - LIMITS.evictAfterMs, inflight: 0, starting: false, ready: Promise.resolve() });
        await joinNetwork(person);
      }
    }
  }

  return {
    ligar,
    use,
    hold,
    reap,
    adopt,
    async desligar(person) {
      await stop(person);
      return { pessoa: person, ligado: false };
    },
    async apagar(person) {
      live.delete(person);
      // The proxy keeps only memory; a proxy that is down forgets anyway.
      await forgetSaida(person).catch(() => {});
      if (await container(person)) {
        const removed = await d.request('DELETE', `/containers/${containerName(person)}?force=true`);
        if (removed.status !== 204 && removed.status !== 404) throw new Error(`docker rm: ${removed.status} ${removed.text}`);
      }
      for (const [kind, path] of [['volume', `/volumes/${volumeName(person)}`], ['network', `/networks/${networkName(person)}`]]) {
        const found = await d.request('GET', path);
        if (found.status === 404) continue;
        if (found.status !== 200) throw new Error(`docker ${kind} inspect: ${found.status} ${found.text}`);
        // One of that name that we did not make is not touched.
        if (!isOurs(found.body.Labels)) throw new Error(`${path.split('/')[2]} exists and is not a computer's`);
        if (kind === 'network') {
          for (const member of [config.saida.container, config.self].filter(Boolean)) {
            await d.request('POST', `${path}/disconnect`, { Container: member, Force: true });
          }
        }
        const removed = await d.request('DELETE', kind === 'volume' ? `${path}?force=true` : path);
        if (removed.status !== 204 && removed.status !== 404) throw new Error(`docker ${kind} rm: ${removed.status} ${removed.text}`);
      }
      wake();
      return { pessoa: person, apagado: true };
    },
    /// The person's sites for the shell (K21), from Supernova's approvals.
    async sites(person, list) {
      sites.set(person, list);
      if (addresses.has(person)) await tellSaida(person, addresses.get(person));
      return { pessoa: person, sites: list };
    },
    async estado() {
      const filters = encodeURIComponent(JSON.stringify({ label: [`${LABEL}=1`] }));
      const listed = await d.request('GET', `/containers/json?all=true&filters=${filters}`);
      if (listed.status !== 200) throw new Error(`docker ps: ${listed.status} ${listed.text}`);
      return {
        computadores: listed.body.map((c) => {
          const person = c.Labels['supernova.pessoa'];
          const state = live.get(person);
          return {
            pessoa: person,
            ligado: c.State === 'running',
            chamadas: state ? state.inflight : 0,
            parado_ms: state ? clock() - state.lastUsed : null,
          };
        }),
        vagas: LIMITS.maxOn - live.size,
      };
    },
    live,
    waiting,
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

/// Carry a call to a person's computer, with the computer's token, which
/// Supernova does not have.
function forward(config, person, path, body) {
  return new Promise((resolve, reject) => {
    const base = new URL(config.computerUrl(person));
    const target = new URL(path, base);
    // The computer's token goes to the computer and nowhere else.
    if (target.origin !== base.origin) return reject(new Error('not the computer'));
    const req = http.request(target, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': body.length,
        authorization: `Bearer ${computerTokenFor(config.computerToken, person)}`,
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

const CALL = /^\/v1\/pessoas\/([^/]+)\/(run|mcp)$/;
const SCREEN = /^\/v1\/pessoas\/([^/]+)\/tela(\/fechar)?$/;

export function createServer(config, pcs = computers(config), held = screens(config)) {
  /// Open the person's screen and make its link (K-09).
  async function openScreen(person) {
    if (!config.screenBase) throw new NoScreen('the screen is not set up here (DESPACHANTE_TELA_URL)');
    const answer = await pcs.use(person, () => forward(config, person, '/v1/run', Buffer.from('{"op":"tela_abrir"}')));
    let opened;
    try { opened = JSON.parse(answer.body.toString('utf8')); } catch { opened = {}; }
    if (!opened.ok || typeof opened.senha !== 'string') throw new Error(opened.error || 'the screen did not open');
    const release = held.has(person) ? () => {} : await pcs.hold(person);
    const token = held.issue(person, opened.senha, () => {
      release();
      forward(config, person, '/v1/run', Buffer.from('{"op":"tela_fechar"}')).catch(() => {});
    });
    return { url: `${config.screenBase.replace(/\/$/, '')}/tela/${token}/`, expira_ms: config.screenMs || SCREEN_MS };
  }
  const SITES = /^\/v1\/pessoas\/([^/]+)\/sites$/;
  const actions = {
    '/v1/ligar': pcs.ligar,
    '/v1/desligar': pcs.desligar,
    // Forgetting ends the person's screen link too (K-I7).
    '/v1/apagar': (person) => { held.end(person); return pcs.apagar(person); },
  };
  return http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true });
    const call = req.url.match(CALL);
    const sitesCall = req.url.match(SITES);
    const screenCall = req.url.match(SCREEN);
    const known = req.url in actions || req.url === '/v1/estado' || call || sitesCall || screenCall;
    if (!known) return send(res, 404, { ok: false, error: 'not found' });
    if (req.headers['origin'] !== undefined) return send(res, 403, { ok: false, error: 'requests from a browser are refused' });
    if (!authorized(req, config.token)) return send(res, 401, { ok: false, error: 'unauthorized' });
    try {
      if (req.url === '/v1/estado') {
        if (req.method !== 'GET' && req.method !== 'POST') return send(res, 405, { ok: false, error: 'GET or POST' });
        return send(res, 200, { ok: true, ...(await pcs.estado()) });
      }
      if (screenCall) {
        const person = checkPerson(screenCall[1]);
        if (req.method === 'DELETE' || (req.method === 'POST' && screenCall[2])) {
          held.end(person);
          return send(res, 200, { ok: true, aberta: false });
        }
        if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'POST or DELETE' });
        return send(res, 200, { ok: true, ...(await openScreen(person)) });
      }
      if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'POST only' });
      const raw = await readBody(req);
      if (call) {
        const person = checkPerson(call[1]);
        const answer = await pcs.use(person, () => forward(config, person, `/v1/${call[2]}`, raw));
        res.writeHead(answer.status, { 'content-type': 'application/json', 'content-length': answer.body.length });
        return res.end(answer.body);
      }
      let body;
      try { body = JSON.parse(raw.toString('utf8')); } catch { throw new UserError('body must be JSON'); }
      if (sitesCall) {
        return send(res, 200, { ok: true, ...(await pcs.sites(checkPerson(sitesCall[1]), sitesOf(body))) });
      }
      return send(res, 200, { ok: true, ...(await actions[req.url](personOf(body))) });
    } catch (e) {
      const message = String(e && e.message ? e.message : e).split('\n')[0].slice(0, 500);
      const status = e instanceof UserError ? 400 : (e instanceof NoPlace || e instanceof NoScreen) ? 503 : 502;
      return send(res, status, { ok: false, error: message });
    }
  });
}

/// The addresses to listen on: this container's addresses on its networks
/// at boot, which are Supernova's (computer networks are joined later).
/// Asked of Docker, so a computer finds nothing to connect to on its side.
export async function listenAddresses(config) {
  if (config.listen) return [config.listen];
  const self = await config.docker.request('GET', `/containers/${config.self}/json`);
  if (self.status !== 200) throw new Error(`cannot inspect myself: ${self.status}`);
  const networks = self.body.NetworkSettings && self.body.NetworkSettings.Networks || {};
  const addresses = Object.entries(networks)
    .filter(([name]) => !name.startsWith('computador-') && name !== 'supernova_computador')
    .map(([, net]) => net.IPAddress)
    .filter(Boolean);
  if (addresses.length === 0) throw new Error('no network to listen on');
  return addresses;
}

/// Where the computers' resolv.conf is: compose mounts it into the
/// dispatcher at RESOLV_TARGET; its path on the host is what a computer's
/// bind mount needs, so it is asked of Docker.
export const RESOLV_TARGET = '/etc/computador/resolv.conf';

export async function resolvConfSource(config) {
  const self = await config.docker.request('GET', `/containers/${config.self}/json`);
  if (self.status !== 200) throw new Error(`cannot inspect myself: ${self.status}`);
  const mount = (self.body.Mounts || []).find((m) => m.Destination === RESOLV_TARGET);
  if (!mount || !mount.Source) throw new Error(`${RESOLV_TARGET} is not mounted; the computers would have no DNS`);
  return mount.Source;
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
    runtime: (env.DESPACHANTE_RUNTIME || 'runsc').trim(),
    port: Number(env.DESPACHANTE_PORTA || 7071),
    listen: (env.DESPACHANTE_ESCUTA || '').trim(),
    socket: (env.DOCKER_SOCKET || '/var/run/docker.sock').trim(),
    saida: {
      container: (env.DESPACHANTE_SAIDA || 'supernova-saida').trim(),
      admin: (env.DESPACHANTE_SAIDA_ADMIN || 'http://saida:7072').trim(),
      token: required('SAIDA_TOKEN'),
      master: required('SAIDA_CREDENCIAL'),
    },
    computerUrl: (person) => `http://${containerName(person)}:7070`,
    screenUrl: (person) => `http://${containerName(person)}:6080`,
    // Where the tunnel publishes the screens (K17); unset, no screens.
    screenBase: (env.DESPACHANTE_TELA_URL || '').trim(),
    screenPort: Number(env.DESPACHANTE_TELA_PORTA || 7073),
    self: os.hostname(),
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
  config.resolvConf = await resolvConfSource(config);
  const addresses = await listenAddresses(config);
  const pcs = computers(config);
  const held = screens(config);
  await pcs.adopt();
  setInterval(() => {
    pcs.reap().catch((e) => console.error(`despachante: reap: ${e.message}`));
  }, 60_000).unref();
  for (const address of addresses) {
    const server = createServer(config, pcs, held);
    server.on('error', (e) => {
      console.error(`despachante: cannot listen on ${address}:${config.port}: ${e.message}`);
      process.exit(1);
    });
    server.listen(config.port, address, () => {
      console.log(`despachante: listening on ${address}:${config.port}, computers run ${config.image}`);
    });
    // The screens, for the tunnel: /tela/* only (K-09).
    if (config.screenBase) {
      const screen = createScreenServer(config, held);
      screen.on('error', (e) => {
        console.error(`despachante: cannot serve screens on ${address}:${config.screenPort}: ${e.message}`);
        process.exit(1);
      });
      screen.listen(config.screenPort, address);
    }
  }
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  main().catch((e) => {
    console.error(`despachante: ${e.message}`);
    process.exit(1);
  });
}
