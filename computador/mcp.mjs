// MCP servers for Supernova's probes (PRD-S, S-03), behind the same
// authenticated door as the rest of this service (POST /v1/mcp).
//
// Two servers, from a fixed list; Supernova never chooses a command or its
// arguments:
//
// - "playwright": a browser for the web probe. One headless Chromium is
//   shared by every probe; each session gets its own browser context
//   (cookies, storage and cache apart), closed with the session, and keeps
//   at most two tabs. The MCP server runs inside this process
//   (`createConnection`), so no port is opened.
// - "filesystem": files for the disk probe, a process over stdio, confined
//   to the person's folder (~/pessoas/<person>/).
//
// Requests (JSON):
//   {"acao": "abrir", "sessao": "<id>", "servidor": "playwright"|"filesystem",
//    "pessoa": "<hex>", "sonda": <n>}
//   {"acao": "chamar", "sessao": "<id>", "mensagem": <JSON-RPC message>}
//      → {"resposta": <JSON-RPC answer>} (none for a notification)
//   {"acao": "fechar", "sessao": "<id>"}
//   {"acao": "apagar_pessoa", "pessoa": "<hex>"}   (for /esquecer)
//   {"acao": "guardar_resultado", "pessoa": "<hex>", "sonda": <n>,
//    "texto": "..."}   (the probe's whole result, in resultado.md)
//
// What the browser may do is narrower than what the Playwright MCP offers:
// no running code in this process (`browser_run_code_unsafe`), no sending
// files from this machine to a site (`browser_file_upload`, `browser_drop`),
// and only http(s) URLs. The shell of this machine belongs to admins; a
// member's web probe must not reach it, nor other people's files.

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { guard, proxyOption, contextOptions } from './rede.mjs';
import { newGate, decide, decideSocket } from './portao.mjs';

export const MCP_LIMITS = {
  idleMs: 5 * 60_000,
  callMs: 120_000,
  maxTabs: 2,
  sessions: 40,
};

const HOME = process.env.HOME || os.homedir();
export const PEOPLE_DIR = process.env.COMPUTADOR_PEOPLE_DIR || path.join(HOME, 'pessoas');

export const BROWSER_TOOLS = new Set([
  'browser_close',
  'browser_resize',
  'browser_console_messages',
  'browser_handle_dialog',
  'browser_emulate_media',
  'browser_evaluate',
  'browser_find',
  'browser_fill_form',
  'browser_press_key',
  'browser_type',
  'browser_navigate',
  'browser_navigate_back',
  'browser_network_requests',
  'browser_network_request',
  'browser_take_screenshot',
  'browser_snapshot',
  'browser_click',
  'browser_drag',
  'browser_hover',
  'browser_select_option',
  'browser_tabs',
  'browser_wait_for',
]);

export class McpUserError extends Error {}

// ------------------------------------------------------------------ paths

export function personDir(person) {
  if (typeof person !== 'string' || !/^[a-f0-9]{8,64}$/.test(person)) {
    throw new McpUserError('pessoa must be 8 to 64 lowercase hex characters');
  }
  return path.join(PEOPLE_DIR, person);
}

export function probeDir(person, probe) {
  if (!Number.isInteger(probe) || probe < 1) throw new McpUserError('sonda must be a positive integer');
  return path.join(personDir(person), 'sondas', String(probe));
}

function sessionId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(value)) {
    throw new McpUserError('sessao must be 1 to 80 letters, digits, _ or -');
  }
  return value;
}

/// Whether every URL in a tool call's arguments is http(s).
export function urlsAllowed(args) {
  let ok = true;
  const visit = (value, key) => {
    if (typeof value === 'string') {
      if (key === 'url' && !/^https?:\/\//i.test(value.trim())) ok = false;
    } else if (Array.isArray(value)) {
      value.forEach((item) => visit(item, key));
    } else if (value && typeof value === 'object') {
      for (const [k, v] of Object.entries(value)) visit(v, k);
    }
  };
  visit(args, '');
  return ok;
}

// --------------------------------------------------------------- sessions

const sessions = new Map();
// Sessions being opened, by id; and how many times each person was
// forgotten, so a session that finished opening after that is closed.
const opening = new Set();
const forgotten = new Map();
let now = () => Date.now();

/// For tests: a fake clock.
export function setClock(clock) { now = clock; }

export function openSessions() { return [...sessions.keys()]; }

function errorAnswer(id, message) {
  return { jsonrpc: '2.0', id, error: { code: -32000, message } };
}

/// The browser shared by every web session; launched on first use, and
/// again after it crashes.
let sharedBrowser = null;
let launchingBrowser = null;

async function browser() {
  if (sharedBrowser && sharedBrowser.isConnected()) return sharedBrowser;
  if (!launchingBrowser) {
    launchingBrowser = (async () => {
      const { chromium } = await import('playwright');
      const launched = await chromium.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
        // Out only through the proxy, like the agent's own browser (K-05).
        ...proxyOption(),
      });
      launched.on('disconnected', () => {
        if (sharedBrowser === launched) sharedBrowser = null;
        // Every web session on the crashed browser is over.
        for (const [id, session] of sessions) {
          if (session.kind === 'playwright') {
            sessions.delete(id);
            session.close().catch(() => {});
          }
        }
      });
      sharedBrowser = launched;
      return launched;
    })().finally(() => { launchingBrowser = null; });
  }
  return launchingBrowser;
}

/// For tests: whether the shared browser is up, and how many contexts it has.
export function browserContexts() {
  return sharedBrowser && sharedBrowser.isConnected() ? sharedBrowser.contexts().length : 0;
}

// An in-process MCP transport: messages to the server go through
// `onmessage`; its answers come back through `send`.
function memoryTransport() {
  const waiting = new Map();
  const transport = {
    onmessage: undefined,
    onclose: undefined,
    onerror: undefined,
    async start() {},
    async close() { transport.onclose?.(); },
    async send(message) {
      if (message.id !== undefined && waiting.has(message.id)) {
        waiting.get(message.id)(message);
        waiting.delete(message.id);
      }
    },
    exchange(message) {
      if (message.id === undefined) {
        transport.onmessage(message);
        return Promise.resolve(null);
      }
      if (waiting.has(message.id)) return Promise.resolve(errorAnswer(message.id, 'a request with this id is already waiting'));
      return new Promise((resolve) => {
        waiting.set(message.id, resolve);
        transport.onmessage(message);
      });
    },
    forget(id) { waiting.delete(id); },
  };
  return transport;
}

async function openPlaywright(person, probe) {
  const folder = probeDir(person, probe);
  await fs.mkdir(folder, { recursive: true });
  const shared = await browser();
  const context = await shared.newContext(contextOptions({
    viewport: { width: 1280, height: 800 },
    locale: 'pt-BR',
    timezoneId: process.env.TZ || 'America/Sao_Paulo',
  }));
  // Nothing internal: this machine, the Docker networks, the LAN.
  // The probes never send anything, and never ask (PRD-K, section 3.3).
  const probeGate = newGate({ probe: true });
  await guard(context, (request) => decide(probeGate, request), (url) => decideSocket(probeGate, url));
  // At most two tabs: a third closes the oldest.
  context.on('page', () => {
    const pages = context.pages();
    while (pages.length > MCP_LIMITS.maxTabs) pages.shift().close().catch(() => {});
  });
  const { createConnection } = await import('@playwright/mcp');
  const server = await createConnection(
    {
      capabilities: ['core'],
      snapshot: { mode: 'full' },
      imageResponses: 'omit',
      webmcp: false,
      outputDir: folder,
      network: { blockedOrigins: ['http://localhost:*', 'http://127.0.0.1:*', 'https://localhost:*', 'https://127.0.0.1:*'] },
    },
    async () => context,
  );
  const transport = memoryTransport();
  await server.connect(transport);
  return {
    kind: 'playwright',
    async call(message) {
      if (message.method === 'tools/call') {
        const name = message.params?.name;
        if (!BROWSER_TOOLS.has(name)) return errorAnswer(message.id, `tool ${name} is not available here`);
        if (!urlsAllowed(message.params?.arguments ?? {})) return errorAnswer(message.id, 'only http:// and https:// URLs');
      }
      const answer = await transport.exchange(message);
      if (message.method === 'tools/list' && answer?.result?.tools) {
        answer.result.tools = answer.result.tools.filter((tool) => BROWSER_TOOLS.has(tool.name));
      }
      return answer;
    },
    forget(id) { transport.forget(id); },
    async close() {
      await server.close().catch(() => {});
      await context.close().catch(() => {});
    },
  };
}

function filesystemCommand() {
  const require = createRequire(import.meta.url);
  const manifest = require.resolve('@modelcontextprotocol/server-filesystem/package.json');
  const bin = require(manifest).bin;
  const entry = typeof bin === 'string' ? bin : bin['mcp-server-filesystem'];
  return path.join(path.dirname(manifest), entry);
}

async function openFilesystem(person) {
  const root = personDir(person);
  await fs.mkdir(root, { recursive: true });
  const child = spawn(process.execPath, [filesystemCommand(), root], {
    cwd: root,
    // Nothing of this service's environment, the token least of all.
    env: { PATH: process.env.PATH || '/usr/bin:/bin', HOME: root },
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  const waiting = new Map();
  let buffer = '';
  let dead = false;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let line;
    while ((line = buffer.indexOf('\n')) >= 0) {
      const text = buffer.slice(0, line).trim();
      buffer = buffer.slice(line + 1);
      if (!text) continue;
      try {
        const message = JSON.parse(text);
        if (message.id !== undefined && waiting.has(message.id)) {
          waiting.get(message.id)(message);
          waiting.delete(message.id);
        }
      } catch { /* not a protocol line */ }
    }
  });
  child.on('exit', () => {
    dead = true;
    for (const [id, resolve] of waiting) resolve(errorAnswer(id, 'the file server stopped'));
    waiting.clear();
  });
  return {
    kind: 'filesystem',
    call(message) {
      if (dead) return Promise.resolve(errorAnswer(message.id ?? null, 'the file server stopped'));
      if (message.id !== undefined && waiting.has(message.id)) {
        return Promise.resolve(errorAnswer(message.id, 'a request with this id is already waiting'));
      }
      child.stdin.write(JSON.stringify(message) + '\n');
      if (message.id === undefined) return Promise.resolve(null);
      return new Promise((resolve) => waiting.set(message.id, resolve));
    },
    forget(id) { waiting.delete(id); },
    async close() {
      if (!dead) child.kill('SIGKILL');
    },
  };
}

// A call that gets no answer in time gives up, and the server's late answer
// has nowhere to go: `forget` drops its slot.
function bounded(promise, ms, id, forget = () => {}) {
  let timer;
  const expired = new Promise((resolve) => {
    timer = setTimeout(() => {
      if (id !== undefined) forget(id);
      resolve(errorAnswer(id ?? null, `no answer within ${ms / 1000} s`));
    }, ms);
  });
  return Promise.race([promise, expired]).finally(() => clearTimeout(timer));
}

async function closeSession(id) {
  const session = sessions.get(id);
  if (!session) return false;
  sessions.delete(id);
  await session.close().catch(() => {});
  return true;
}

/// Close the sessions nobody used for `MCP_LIMITS.idleMs`.
export async function sweepIdle() {
  const limit = now() - MCP_LIMITS.idleMs;
  const idle = [...sessions].filter(([, session]) => session.lastUsed < limit).map(([id]) => id);
  for (const id of idle) await closeSession(id);
  return idle;
}

/// Close every session and the shared browser (tests, shutdown).
export async function shutdown() {
  for (const id of [...sessions.keys()]) await closeSession(id);
  const open = sharedBrowser;
  sharedBrowser = null;
  if (open) await open.close().catch(() => {});
}

export async function mcp(body, opener = { playwright: openPlaywright, filesystem: openFilesystem }) {
  const action = typeof body.acao === 'string' ? body.acao : '';
  switch (action) {
    case 'abrir': {
      const id = sessionId(body.sessao);
      const server = body.servidor;
      if (!Object.hasOwn(opener, server)) throw new McpUserError('servidor must be playwright or filesystem');
      if (sessions.has(id) || opening.has(id)) throw new McpUserError(`session ${id} is already open`);
      if (sessions.size + opening.size >= MCP_LIMITS.sessions) throw new McpUserError('too many open sessions');
      // Reserved before the first await: a second `abrir` with the same id,
      // or a burst past the limit, is refused instead of racing.
      opening.add(id);
      const epoch = forgotten.get(body.pessoa) ?? 0;
      try {
        const session = server === 'playwright'
          ? await opener.playwright(body.pessoa, body.sonda)
          : await opener.filesystem(body.pessoa, body.sonda);
        // The person was forgotten while this session opened: nothing of
        // theirs may stay alive.
        if ((forgotten.get(body.pessoa) ?? 0) !== epoch) {
          await session.close().catch(() => {});
          throw new McpUserError('the person was forgotten while the session opened');
        }
        session.lastUsed = now();
        session.person = body.pessoa;
        sessions.set(id, session);
        return {};
      } finally {
        opening.delete(id);
      }
    }
    case 'chamar': {
      const id = sessionId(body.sessao);
      const session = sessions.get(id);
      if (!session) throw new McpUserError(`no session ${id}`);
      const message = body.mensagem;
      if (!message || typeof message !== 'object' || typeof message.method !== 'string') {
        throw new McpUserError('mensagem must be a JSON-RPC request or notification');
      }
      session.lastUsed = now();
      const answer = await bounded(session.call(message), MCP_LIMITS.callMs, message.id, (id) => session.forget?.(id));
      session.lastUsed = now();
      return answer === null ? {} : { resposta: answer };
    }
    case 'fechar':
      return { fechada: await closeSession(sessionId(body.sessao)) };
    case 'apagar_pessoa': {
      const folder = personDir(body.pessoa);
      forgotten.set(body.pessoa, (forgotten.get(body.pessoa) ?? 0) + 1);
      for (const [id, session] of [...sessions]) {
        if (session.person === body.pessoa) await closeSession(id);
      }
      await fs.rm(folder, { recursive: true, force: true });
      return {};
    }
    case 'guardar_resultado': {
      const folder = probeDir(body.pessoa, body.sonda);
      if (typeof body.texto !== 'string') throw new McpUserError('texto must be a string');
      await fs.mkdir(folder, { recursive: true });
      await fs.writeFile(path.join(folder, 'resultado.md'), body.texto, 'utf8');
      return {};
    }
    default:
      throw new McpUserError('acao must be abrir, chamar, fechar, apagar_pessoa or guardar_resultado');
  }
}
