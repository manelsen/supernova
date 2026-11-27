// Which addresses the computer's browsers may not reach: this machine, the
// Docker networks it sits on (where Supernova and the other services
// listen), the LAN, link-local and cloud metadata. The host firewall only
// filters traffic leaving the bridge; traffic inside it, and loopback, are
// up to this check. Both browsers (`agent.mjs` and the probes' contexts in
// `mcp.mjs`) route every request through `guard`.
//
// Without the egress proxy, a name is resolved here and again by Chromium,
// and a name that changes address in between (DNS rebinding) can slip
// through. With it (PRD-K, K-05), the computer cannot resolve or reach
// anything itself: names go to the proxy, which resolves them once and
// refuses internal addresses; here only literal addresses and localhost
// are checked.

import dns from 'node:dns/promises';
import net from 'node:net';

const CACHE_MS = 60_000;
const cache = new Map();

// Tests point the browser at a local page; production never sets this.
let allowInternal = () => false;
export function setInternalAllowed(fn) { allowInternal = fn; }

function v4Internal(ip) {
  const [a, b] = ip.split('.').map(Number);
  return a === 0 || a === 10 || a === 127 || a >= 224
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168)
    || (a === 198 && (b === 18 || b === 19));
}

function v6Internal(ip) {
  const lower = ip.toLowerCase();
  // An IPv4 address inside IPv6 (::ffff:a.b.c.d, or the same in hex).
  const mapped = lower.match(/^(?:0*:)*:?ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return v4Internal(mapped[1]);
  const hex = lower.match(/^(?:0*:)*:?ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (hex) {
    const hi = parseInt(hex[1], 16);
    const lo = parseInt(hex[2], 16);
    return v4Internal(`${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`);
  }
  if (lower === '::' || lower === '::1') return true;
  const first = parseInt(lower.split(':')[0] || '0', 16);
  return (first & 0xfe00) === 0xfc00 // unique local fc00::/7
    || (first & 0xffc0) === 0xfe80 // link-local fe80::/10
    || (first & 0xff00) === 0xff00; // multicast
}

/// Whether an IP address is internal (loopback, private, link-local, …).
export function internalAddress(ip) {
  const kind = net.isIP(ip);
  if (kind === 4) return v4Internal(ip);
  if (kind === 6) return v6Internal(ip);
  return true;
}

/// Whether a URL's host may not be reached. Names are resolved; a name that
/// does not resolve is refused too (it could not be checked).
export async function hostBlocked(hostname) {
  const host = hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (allowInternal(host)) return false;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (net.isIP(host)) return internalAddress(host);
  if (process.env.SAIDA_URL) return false;
  const hit = cache.get(host);
  if (hit && hit.until > Date.now()) return hit.blocked;
  let blocked;
  try {
    const addresses = await dns.lookup(host, { all: true, verbatim: true });
    blocked = addresses.length === 0 || addresses.some((a) => internalAddress(a.address));
  } catch {
    blocked = true;
  }
  cache.set(host, { blocked, until: Date.now() + CACHE_MS });
  return blocked;
}

/// The way out for the browsers, when the computer has one (PRD-K, K-05):
/// the proxy, with the person's credential.
export function proxyOption(env = process.env) {
  if (!env.SAIDA_URL) return {};
  return { proxy: { server: env.SAIDA_URL, username: env.SAIDA_USUARIO || '', password: env.SAIDA_SENHA || '' } };
}

/// Options every browser context of the computer is made with. Service
/// workers are blocked: what a worker fetches does not pass `route`, so a
/// page could send through one behind the gate.
export function contextOptions(extra = {}) {
  return { ...extra, serviceWorkers: 'block' };
}

/// Route every request of a browser context through the check. Non-network
/// schemes (data:, blob:, about:) pass; http(s) to an internal host is
/// aborted; then `gate` decides (the browser gate). WebSockets do not pass
/// `route`: they get the same internal check and then `socketGate`, and a
/// refused one is closed before it reaches the server.
export async function guard(context, gate = () => true, socketGate = () => true) {
  await context.routeWebSocket(/.*/, async (ws) => {
    let url;
    try { url = new URL(ws.url()); } catch { return ws.close({ code: 1008, reason: 'blocked' }); }
    if (url.protocol !== 'ws:' && url.protocol !== 'wss:') return ws.close({ code: 1008, reason: 'blocked' });
    if (await hostBlocked(url.hostname)) return ws.close({ code: 1008, reason: 'blocked' });
    if (!socketGate(url)) return ws.close({ code: 1008, reason: 'blocked' });
    ws.connectToServer();
  });
  await context.route('**/*', async (route) => {
    let url;
    try { url = new URL(route.request().url()); } catch { return route.abort('blockedbyclient'); }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return route.continue();
    if (await hostBlocked(url.hostname)) return route.abort('blockedbyclient');
    // Then the browser gate (portao.mjs, PRD-K, K-06).
    if (!gate(route.request())) return route.abort('blockedbyclient');
    return route.continue();
  });
}
