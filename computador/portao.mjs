// The browser gate (PRD-K, K10, K-06). Every request of a browser context
// passes here after the internal-address check (rede.mjs):
//
// - reading (GET, HEAD, OPTIONS) is free;
// - anything else on a site (background posts: searches, likes, carts)
//   needs the site allowed (level 1: "usar o site", an hour, a day or for
//   good, as the person chose);
// - sending a form (a POST navigation, or a click on a send button) needs a
//   one-use grant for that site every time (level 2), with a summary of
//   what goes (passwords masked);
// - the probes' contexts never send anything and never ask (section 3.3).
//
// Supernova says, with each call, what is allowed; the gate answers what
// it refused and what it used, so a one-use grant is spent only when used.

import net from 'node:net';

const READING = new Set(['GET', 'HEAD', 'OPTIONS']);
const SENSITIVE = /(senha|password|passwd|pass|pwd|token|secret|segredo|cvv|cvc|cart[aã]o|card|pin|cpf)/i;
// Second-level names under a country code: example.com.br is the site,
// not com.br.
const SECOND_LEVEL = new Set(['com', 'gov', 'org', 'net', 'edu', 'co', 'ac', 'mil', 'nom', 'art', 'blog', 'app', 'leg', 'jus', 'mp', 'ind', 'inf', 'eco', 'tv']);
export const SEND_WORDS = /^\s*(enviar|envie|mandar|confirmar|confirme|concluir|finalizar|pagar|comprar|agendar|marcar|assinar|cadastrar|registrar|publicar|postar|submeter|solicitar|transferir|send|submit|confirm|pay|buy|order|book|sign up|register|post|publish|place order|checkout)\b/i;

// Shared hosting: under these, each name is someone else's site, so
// approving one blog never approves the whole platform. Not the whole
// Public Suffix List; the platforms a person meets most.
const SHARED = [
  'github.io', 'gitlab.io', 'wordpress.com', 'blogspot.com', 'blogspot.com.br', 'tumblr.com',
  'medium.com', 'substack.com', 'wixsite.com', 'weebly.com', 'webnode.page', 'neocities.org',
  'netlify.app', 'vercel.app', 'pages.dev', 'workers.dev', 'web.app', 'firebaseapp.com',
  'herokuapp.com', 'onrender.com', 'fly.dev', 'glitch.me', 'repl.co', 'surge.sh',
  'azurewebsites.net', 'cloudfront.net', 's3.amazonaws.com', 'appspot.com', 'myshopify.com',
  'carrd.co', 'notion.site', 'sites.google.com', 'webflow.io', 'framer.website',
];

/// The site of a host: what a person recognises and approves.
export function siteOf(host) {
  const bare = String(host || '').toLowerCase().replace(/\.$/, '').replace(/^\[|\]$/g, '');
  if (net.isIP(bare)) return bare;
  const shared = SHARED.find((suffix) => bare.endsWith(`.${suffix}`));
  if (shared) {
    const owner = bare.slice(0, -(shared.length + 1)).split('.').pop();
    return `${owner}.${shared}`;
  }
  const labels = bare.split('.');
  if (labels.length <= 2) return labels.join('.');
  const last = labels[labels.length - 1];
  const second = labels[labels.length - 2];
  const take = last.length === 2 && SECOND_LEVEL.has(second) ? 3 : 2;
  return labels.slice(-take).join('.');
}

/// What a form sends, as a person reads it: name = value, secrets masked.
export function summarizeFields(pairs, max = 8) {
  const shown = pairs
    .filter(([name]) => name && !/^(_|csrf|authenticity_token|__)/i.test(name))
    .slice(0, max)
    .map(([name, value]) => {
      const v = SENSITIVE.test(name) ? '••••' : String(value).replace(/\s+/g, ' ').slice(0, 40);
      return `${name} = ${v}`;
    });
  return shown.join('; ');
}

/// The fields of a request body: urlencoded, JSON or multipart (names only
/// for files).
export function fieldsOf(postData, contentType = '') {
  if (!postData) return [];
  const type = contentType.toLowerCase();
  try {
    if (type.includes('application/json')) {
      const body = JSON.parse(postData);
      return body && typeof body === 'object' ? Object.entries(body).map(([k, v]) => [k, typeof v === 'object' ? JSON.stringify(v) : v]) : [];
    }
    if (type.includes('multipart/form-data')) {
      return [...postData.matchAll(/name="([^"]+)"(?:; filename="([^"]*)")?\r?\n(?:[^\r\n]*\r?\n)*?\r?\n([^\r\n]*)/g)]
        .map((m) => [m[1], m[2] !== undefined ? `(arquivo ${m[2]})` : m[3]]);
    }
  } catch { return []; }
  return [...new URLSearchParams(postData).entries()];
}

/// The gate's state for one browser context.
export function newGate({ probe = false } = {}) {
  return {
    probe,
    sites: new Set(),
    envios: new Set(),
    armed: new Set(),
    refused: [],
    used: [],
  };
}

/// What Supernova allowed for this call; and a fresh account of it.
export function allow(gate, liberado) {
  const lower = (list) => (Array.isArray(list) ? list.map((s) => String(s).toLowerCase()) : []);
  gate.sites = new Set(lower(liberado && liberado.sites));
  gate.envios = new Set(lower(liberado && liberado.envios));
  gate.armed = new Set();
  gate.refused = [];
  gate.used = [];
}

/// The account of a call: what was refused and which one-use grants went.
export function account(gate) {
  if (gate.refused.length === 0 && gate.used.length === 0) return {};
  return { portao: { recusas: gate.refused.slice(0, 3), usados: [...new Set(gate.used)] } };
}

/// Decide one request. true: let it go.
export function decide(gate, request) {
  const method = request.method().toUpperCase();
  if (READING.has(method)) return true;
  let url;
  try { url = new URL(request.url()); } catch { return false; }
  const site = siteOf(url.hostname);
  if (gate.probe) {
    gate.refused.push({ tipo: 'sonda', site, metodo: method });
    return false;
  }
  // A send button the person allowed in this call: what it sends goes.
  if (gate.armed.has(site)) return true;
  const navigation = request.isNavigationRequest();
  if (navigation) {
    if (gate.envios.has(site)) { gate.envios.delete(site); gate.used.push(site); return true; }
    const headers = request.headers();
    gate.refused.push({
      tipo: 'envio', site, metodo: method, url: `${url.origin}${url.pathname}`,
      campos: summarizeFields(fieldsOf(request.postData() || '', headers['content-type'] || '')),
    });
    return false;
  }
  if (gate.sites.has(site)) return true;
  gate.refused.push({ tipo: 'site', site, metodo: method, url: `${url.origin}${url.pathname}` });
  return false;
}

/// Decide one WebSocket. It can carry anything both ways, so it is a
/// write: it needs the site, like a background request. A probe never
/// opens one. true: let it connect.
export function decideSocket(gate, url) {
  const site = siteOf(url.hostname);
  if (gate.probe) {
    gate.refused.push({ tipo: 'sonda', site, metodo: 'WEBSOCKET' });
    return false;
  }
  if (gate.sites.has(site) || gate.armed.has(site)) return true;
  gate.refused.push({ tipo: 'site', site, metodo: 'WEBSOCKET', url: `${url.origin}${url.pathname}` });
  return false;
}

/// Before a click: a send button needs a one-use grant for its form's
/// site. Returns null to go on, or the refusal.
export async function beforeClick(gate, page, target) {
  if (gate.probe) return null;
  const info = await target.evaluate((el, words) => {
    // Buttons only: a link that says "Comprar" is still reading.
    const node = el.closest('button, input[type=submit], input[type=image], input[type=button], [role=button]');
    if (!node) return null;
    const form = node.form || node.closest('form');
    const type = (node.getAttribute('type') || '').toLowerCase();
    const tag = node.tagName.toLowerCase();
    const name = (node.getAttribute('aria-label') || node.innerText || node.value || '').trim().slice(0, 80);
    const submits = (tag === 'button' && form && (type === '' || type === 'submit'))
      || (tag === 'input' && (type === 'submit' || type === 'image'))
      || new RegExp(words, 'i').test(name);
    if (!submits) return null;
    const fields = form
      ? [...form.elements].filter((f) => f.name && f.type !== 'submit' && f.type !== 'button' && f.type !== 'hidden')
        .map((f) => [f.name, f.type === 'password' ? '••••' : (f.type === 'checkbox' || f.type === 'radio') ? (f.checked ? f.value || 'sim' : null) : f.value])
        .filter(([, v]) => v !== null)
      : [];
    const action = form && form.action ? form.action : location.href;
    return { name, action, fields };
  }, SEND_WORDS.source).catch(() => null);
  if (!info) return null;
  // A form whose action has no host (`javascript:`, as Google's login has)
  // sends from the page itself: its site is the page's, never empty.
  let site = '';
  try { site = siteOf(new URL(info.action).hostname); } catch { /* the page's below */ }
  if (!site) site = siteOf(new URL(page.url()).hostname);
  if (gate.envios.has(site)) {
    gate.envios.delete(site);
    gate.armed.add(site);
    gate.used.push(site);
    return null;
  }
  const refusal = { tipo: 'envio', site, metodo: 'POST', url: info.action, botao: info.name, campos: summarizeFields(info.fields) };
  gate.refused.push(refusal);
  return refusal;
}
