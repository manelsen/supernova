// The computers' only way out (PRD-K, K5, K-05). Every person's computer is
// on an internal network with no route outside; this proxy is on each of
// those networks, with a fixed address, and on a network of its own that
// reaches the internet.
//
// - Whose connection it is comes from the address it arrived at: one
//   address per person's network, told by the dispatcher.
// - The browser (user svc) has the person's credential: anything public
//   passes (what it may send is the browser gate's business, K-06).
// - The shell (user sh) has no credential: only CONNECT, GET and HEAD, and
//   only to the factory list (package indexes, GitHub) and the sites the
//   person approved (K21).
// - Nothing internal, whatever the credential: names are resolved here,
//   once, and the connection goes to that address (no DNS rebinding).

import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import dns from 'node:dns/promises';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { internalAddress } from './rede.mjs';

// Where the shell may download from without asking (K21: pip, npm, apt,
// GitHub). A host matches itself and its subdomains.
export const FACTORY = [
  'pypi.org', 'files.pythonhosted.org', 'pythonhosted.org',
  'registry.npmjs.org', 'npmjs.org', 'registry.yarnpkg.com',
  'github.com', 'githubusercontent.com', 'codeload.github.com', 'objects.githubusercontent.com',
  'deb.debian.org', 'security.debian.org', 'archive.ubuntu.com', 'security.ubuntu.com', 'ports.ubuntu.com',
  'dl-cdn.alpinelinux.org',
  'crates.io', 'static.crates.io', 'index.crates.io',
  'proxy.golang.org', 'sum.golang.org',
  'rubygems.org',
];

export const PERSON = /^[0-9a-f]{16}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;

/// The browser's credential for a person: derived from the master secret,
/// so the dispatcher and the proxy agree without storing one per person.
export function credentialFor(master, person) {
  return createHmac('sha256', master).update(`saida:${person}`).digest('hex');
}

export function listed(host, sites) {
  const h = host.toLowerCase().replace(/\.$/, '');
  return sites.some((site) => h === site || h.endsWith(`.${site}`));
}

export function validSite(site) {
  return typeof site === 'string' && HOST.test(site) && !net.isIP(site);
}

function sameSecret(given, wanted) {
  const a = Buffer.from(given);
  const b = Buffer.from(wanted);
  return a.length === b.length && timingSafeEqual(a, b);
}

/// Who sent this request through the proxy: the browser (with the
/// person's credential) or the shell (without).
export function hasCredential(header, master, person) {
  if (!header || !header.startsWith('Basic ')) return false;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const colon = decoded.indexOf(':');
  if (colon < 0) return false;
  return decoded.slice(0, colon) === person && sameSecret(decoded.slice(colon + 1), credentialFor(master, person));
}

// Tests point at local servers; production never sets this.
let allowInternal = () => false;
export function setInternalAllowed(fn) { allowInternal = fn; }

/// The public address to connect to, or an error saying why not.
export async function publicAddress(host, lookup = dns.lookup) {
  const bare = host.replace(/^\[|\]$/g, '').toLowerCase();
  if (allowInternal(bare)) return bare;
  if (bare === 'localhost' || bare.endsWith('.localhost')) throw new Error('internal address');
  const internal = (ip) => internalAddress(ip) && !allowInternal(ip);
  if (net.isIP(bare)) {
    if (internal(bare)) throw new Error('internal address');
    return bare;
  }
  const addresses = await lookup(bare, { all: true, verbatim: true });
  if (addresses.length === 0) throw new Error('no address');
  if (addresses.some((a) => internal(a.address))) throw new Error('internal address');
  return addresses[0].address;
}

export function createProxy(config) {
  // address on a person's network -> { person, sites }
  const people = config.people;
  const log = config.log || (() => {});

  function decide(req, host) {
    const who = people.get(normalise(req.socket.localAddress));
    if (!who) return { ok: false, status: 403, why: 'not a computer' };
    if (hasCredential(req.headers['proxy-authorization'], config.master, who.person)) {
      return { ok: true, who, via: 'navegador' };
    }
    // 407 asks for the credential: Chromium sends it only when asked. The
    // shell has none, so for it this is a refusal, with the reason.
    const method = req.method;
    if (method !== 'CONNECT' && method !== 'GET' && method !== 'HEAD') {
      return { ok: false, status: 407, why: 'the shell only reads and downloads', who };
    }
    if (!listed(host, FACTORY) && !listed(host, who.sites)) {
      return { ok: false, status: 407, why: `${host} is not on the shell's list; ask your person for it (pedir_site)`, who };
    }
    return { ok: true, who, via: 'shell' };
  }

  function refuse(socketOrRes, status, why) {
    const text = `${why}\n`;
    if (socketOrRes instanceof http.ServerResponse) {
      socketOrRes.writeHead(status, {
        'content-type': 'text/plain; charset=utf-8',
        'x-supernova-saida': 'recusado',
        ...(status === 407 ? { 'proxy-authenticate': 'Basic realm="saida"' } : {}),
      });
      socketOrRes.end(text);
    } else {
      const ask = status === 407 ? 'proxy-authenticate: Basic realm="saida"\r\n' : '';
      socketOrRes.end(`HTTP/1.1 ${status} Refused\r\ncontent-type: text/plain; charset=utf-8\r\nx-supernova-saida: recusado\r\n${ask}content-length: ${Buffer.byteLength(text)}\r\n\r\n${text}`);
    }
  }

  const server = http.createServer(async (req, res) => {
    // A client that goes away must never take the proxy down with it.
    req.on('error', () => {});
    res.on('error', () => {});
    let url;
    try { url = new URL(req.url); } catch { return refuse(res, 400, 'absolute URL expected'); }
    if (url.protocol !== 'http:') return refuse(res, 400, 'only http here; https goes through CONNECT');
    const verdict = decide(req, url.hostname);
    log({ via: verdict.via || 'shell', pessoa: verdict.who && verdict.who.person, host: url.hostname, metodo: req.method, ok: verdict.ok });
    if (!verdict.ok) return refuse(res, verdict.status, verdict.why);
    let address;
    try { address = await publicAddress(url.hostname, config.lookup); } catch (e) { return refuse(res, 403, `${url.hostname}: ${e.message}`); }
    const headers = { ...req.headers };
    delete headers['proxy-authorization'];
    delete headers['proxy-connection'];
    const upstream = http.request({
      host: address,
      port: url.port || 80,
      method: req.method,
      path: url.pathname + url.search,
      headers: { ...headers, host: url.host },
    }, (answer) => {
      res.writeHead(answer.statusCode, answer.headers);
      answer.pipe(res);
    });
    upstream.on('error', (e) => refuse(res, 502, e.message));
    req.pipe(upstream);
  });

  server.on('connect', async (req, client, head) => {
    // A client that goes away (a refused curl closes at once) must never
    // take the proxy down with it.
    client.on('error', () => {});
    const [host, portText] = req.url.split(/:(?=\d+$)/);
    const port = Number(portText || 443);
    const verdict = decide(req, host);
    log({ via: verdict.via || 'shell', pessoa: verdict.who && verdict.who.person, host, metodo: 'CONNECT', ok: verdict.ok });
    if (!verdict.ok) return refuse(client, verdict.status, verdict.why);
    let address;
    try { address = await publicAddress(host, config.lookup); } catch (e) { return refuse(client, 403, `${host}: ${e.message}`); }
    const upstream = net.connect(port, address, () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head && head.length) upstream.write(head);
      upstream.pipe(client);
      client.pipe(upstream);
    });
    upstream.on('error', () => client.destroy());
    client.on('error', () => upstream.destroy());
    client.on('close', () => upstream.destroy());
  });
  server.on('clientError', (_e, socket) => socket.destroy());
  return server;
}

const normalise = (address) => String(address || '').replace(/^::ffff:/, '');

/// The dispatcher's door: which address is whose, and the person's list.
export function createAdmin(config) {
  const people = config.people;
  const send = (res, status, body) => {
    const text = JSON.stringify(body);
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(text);
  };
  return http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true });
    const given = String(req.headers.authorization || '');
    if (!config.token || !sameSecret(given, `Bearer ${config.token}`)) return send(res, 401, { ok: false, error: 'unauthorized' });
    const m = req.url.match(/^\/v1\/pessoas\/([^/]+)$/);
    if (!m || !PERSON.test(m[1])) return send(res, 404, { ok: false, error: 'not found' });
    const person = m[1];
    if (req.method === 'DELETE') {
      for (const [address, who] of people) if (who.person === person) people.delete(address);
      return send(res, 200, { ok: true });
    }
    if (req.method !== 'PUT') return send(res, 405, { ok: false, error: 'PUT or DELETE' });
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return send(res, 400, { ok: false, error: 'JSON' }); }
      const keys = Object.keys(body || {}).sort().join(',');
      const sites = Array.isArray(body && body.sites) ? body.sites.map((s) => String(s).toLowerCase()) : null;
      if (keys !== 'endereco,sites' || !net.isIPv4(body.endereco) || !sites
        || sites.length > 200 || !sites.every(validSite)) {
        return send(res, 400, { ok: false, error: 'expected {endereco, sites}' });
      }
      for (const [address, who] of people) if (who.person === person) people.delete(address);
      people.set(body.endereco, { person, sites });
      send(res, 200, { ok: true });
    });
  });
}

/// The admin door listens only on the address this container had at boot
/// (Supernova's network); people's networks are joined later.
export function bootAddresses() {
  return Object.values(os.networkInterfaces()).flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
}

async function main() {
  const required = (name) => {
    const value = (process.env[name] || '').trim();
    if (!value) { console.error(`saida: ${name} is required`); process.exit(1); }
    return value;
  };
  const config = {
    token: required('SAIDA_TOKEN'),
    master: required('SAIDA_CREDENCIAL'),
    people: new Map(),
    log: (entry) => { if (!entry.ok) console.log(JSON.stringify({ saida: 'recusado', ...entry })); },
  };
  const admin = (process.env.SAIDA_ESCUTA_ADMIN || '').trim().split(',').filter(Boolean);
  const adminAddresses = admin.length ? admin : bootAddresses();
  for (const address of adminAddresses) {
    createAdmin(config).listen(7072, address, () => console.log(`saida: admin on ${address}:7072`));
  }
  const proxy = createProxy(config);
  proxy.on('error', (e) => { console.error(`saida: ${e.message}`); process.exit(1); });
  // Accepts on every address; a connection on an address that is not a
  // person's is refused (`not a computer`).
  proxy.listen(3128, '0.0.0.0', () => console.log('saida: proxy on :3128'));
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) main();
