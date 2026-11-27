// The person's screen, served (PRD-K, K16, K17, K-09). Supernova asks for a
// screen; the dispatcher opens it in the person's computer and makes a
// link: one use, 15 minutes, that person's computer only. The tunnel
// (cloudflared) publishes this server and nothing else, under /tela/.
//
// The first visit to the link uses it: it sets a cookie for that browser
// and every later request of the screen (noVNC's files, its WebSocket)
// needs it. Opening the link again, from anywhere, finds it used.

import http from 'node:http';
import net from 'node:net';
import { randomBytes, timingSafeEqual } from 'node:crypto';

export const SCREEN_MS = 15 * 60_000;
const TOKEN = /^[A-Za-z0-9_-]{32}$/;

export function screens(config) {
  const byToken = new Map();
  const clock = config.clock || (() => Date.now());

  function find(person) {
    for (const [token, s] of byToken) if (s.person === person) return [token, s];
    return null;
  }

  function finish(token, s) {
    clearTimeout(s.timer);
    byToken.delete(token);
    s.onEnd();
  }

  return {
    has(person) { return find(person) !== null; },
    /// A new link for an open screen. An older link of the person stops
    /// working; the screen itself goes on (its end moves to the new link).
    issue(person, password, onEnd) {
      const old = find(person);
      let end = onEnd;
      if (old) {
        clearTimeout(old[1].timer);
        byToken.delete(old[0]);
        end = old[1].onEnd;
      }
      const token = randomBytes(24).toString('base64url');
      const ms = config.screenMs || SCREEN_MS;
      const entry = { person, password, expires: clock() + ms, session: null, onEnd: end };
      entry.timer = setTimeout(() => finish(token, entry), ms);
      entry.timer.unref?.();
      byToken.set(token, entry);
      return token;
    },
    /// The screen ends now (the person, the agent, or /esquecer).
    end(person) {
      const found = find(person);
      if (found) finish(found[0], found[1]);
    },
    get(token) {
      const s = byToken.get(token);
      if (!s) return null;
      if (clock() > s.expires) { finish(token, s); return null; }
      return s;
    },
    byToken,
  };
}

const HEADERS = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'referrer-policy': 'no-referrer',
};

function page(res, status, text) {
  res.writeHead(status, HEADERS);
  res.end(`<!doctype html><html lang="pt-BR"><title>Tela</title><p>${text}</p></html>`);
}

// What the link shows: one button. Opening the link uses nothing, so a chat
// app's link preview (which fetches it from its own servers) cannot burn
// it; the button, which no preview presses, does.
function landing(res) {
  res.writeHead(200, HEADERS);
  res.end(`<!doctype html><html lang="pt-BR"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tela do seu computador</title>
<style>body{font:1.25rem system-ui,sans-serif;margin:2rem auto;max-width:32rem;padding:0 1rem}
button{font:inherit;padding:1rem 2rem;min-width:12rem}</style>
<h1>Tela do seu computador</h1>
<p>Este link abre a tela uma vez só, neste aparelho, por 15 minutos.</p>
<form method="post"><button type="submit" autofocus>Abrir a tela</button></form></html>`);
}

// After the button: the page goes to noVNC with the password in the
// fragment. It rides in this page's body, never in a header.
function opening(res, cookie, target) {
  res.writeHead(200, { ...HEADERS, 'set-cookie': cookie });
  const json = JSON.stringify(target).replace(/</g, '\\u003c');
  res.end(`<!doctype html><html lang="pt-BR"><title>Abrindo a tela</title>
<p>Abrindo a tela…</p><script>location.replace(${json});</script></html>`);
}

function cookieOf(req, name) {
  const header = String(req.headers.cookie || '');
  for (const part of header.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return v.join('=');
  }
  return null;
}

function same(a, b) {
  const x = Buffer.from(String(a || ''));
  const y = Buffer.from(String(b || ''));
  return x.length === y.length && timingSafeEqual(x, y);
}

/// Which screen a request is for, and the path inside it.
function route(url) {
  const m = String(url).match(/^\/tela\/([A-Za-z0-9_-]+)\/(.*)$/);
  if (!m || !TOKEN.test(m[1])) return null;
  return { token: m[1], rest: m[2] };
}

export function createScreenServer(config, held) {
  const server = http.createServer((req, res) => {
    const r = route(req.url);
    const opens = req.method === 'POST' && r && r.rest === '';
    if (!r || (req.method !== 'GET' && !opens)) return page(res, 404, 'Não há nada aqui.');
    const s = held.get(r.token);
    if (!s) return page(res, 410, 'Este link não vale mais. Peça um novo à sua agente.');
    const cookie = `tela_${r.token.slice(0, 8)}`;
    if (!s.session) {
      if (r.rest !== '') return page(res, 403, 'Abra o link que você recebeu.');
      if (!opens) return landing(res);
      // The button uses the link, for this browser only.
      s.session = randomBytes(24).toString('base64url');
      const target = `/tela/${r.token}/vnc.html#autoconnect=true&resize=scale&reconnect=true&path=tela/${r.token}/websockify&password=${encodeURIComponent(s.password)}`;
      return opening(res,
        `${cookie}=${s.session}; Path=/tela/${r.token}/; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.ceil(SCREEN_MS / 1000)}`,
        target);
    }
    if (opens) return page(res, 403, 'Este link já foi aberto.');
    if (!same(cookieOf(req, cookie), s.session)) return page(res, 403, 'Este link já foi aberto.');
    // noVNC's files, from the person's computer.
    const target = new URL(`/${r.rest.split('#')[0]}`, config.screenUrl(s.person));
    const upstream = http.get(target, (answer) => {
      res.writeHead(answer.statusCode, { 'content-type': answer.headers['content-type'] || 'application/octet-stream', 'cache-control': 'no-store' });
      answer.pipe(res);
    });
    upstream.on('error', () => page(res, 502, 'A tela não respondeu.'));
  });
  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {});
    const r = route(req.url);
    const s = r && held.get(r.token);
    const cookie = r && `tela_${r.token.slice(0, 8)}`;
    if (!r || r.rest !== 'websockify' || !s || !s.session || !same(cookieOf(req, cookie), s.session)) {
      socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
      return;
    }
    const target = new URL(config.screenUrl(s.person));
    const upstream = net.connect(Number(target.port || 80), target.hostname, () => {
      const headers = Object.entries(req.headers)
        .filter(([k]) => k !== 'cookie' && k !== 'host')
        .map(([k, v]) => `${k}: ${v}`)
        .join('\r\n');
      upstream.write(`GET /websockify HTTP/1.1\r\nhost: ${target.host}\r\n${headers}\r\n\r\n`);
      if (head && head.length) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('close', () => upstream.destroy());
  });
  return server;
}
