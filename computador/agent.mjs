// The agent's computer: a small HTTP service that runs inside its own
// sandbox (a gVisor container by default) and does what Supernova's
// `computador` tool asks: run shell commands, read and write files, and
// drive one persistent browser.
//
// This process holds no secrets of Supernova's. Everything it returns is
// data for the agent to read, never instructions for Supernova.
//
// Protocol: POST /v1/run with a JSON body {"op": "...", ...}. Every answer is
// JSON: {"ok": true, ...} or {"ok": false, "error": "..."}. GET /health
// answers {"ok": true}.

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

export const LIMITS = {
  bodyBytes: 4 * 1024 * 1024,
  outputChars: 20_000,
  pageTextChars: 15_000,
  fileReadBytes: 200_000,
  listEntries: 200,
  execDefaultS: 60,
  execMaxS: 300,
  browserTimeoutMs: 30_000,
};

const HOME = process.env.HOME || os.homedir();
export const WORK_DIR = process.env.COMPUTADOR_WORK_DIR || path.join(HOME, 'trabalho');
const PROFILE_DIR = process.env.COMPUTADOR_PROFILE_DIR || path.join(HOME, '.navegador');
const VIEWPORT = { width: 1280, height: 800 };

// ---------------------------------------------------------------- helpers

export function clip(text, max) {
  if (text.length <= max) return { text, truncated: false };
  return { text: text.slice(0, max), truncated: true };
}

export function resolvePath(p) {
  if (typeof p !== 'string' || p.trim() === '') throw new UserError('path is required');
  return path.isAbsolute(p) ? path.normalize(p) : path.resolve(WORK_DIR, p);
}

export class UserError extends Error {}

function requireString(args, name) {
  const v = args[name];
  if (typeof v !== 'string' || v === '') throw new UserError(`${name} is required`);
  return v;
}

function requireNumber(args, name) {
  const v = args[name];
  if (typeof v !== 'number' || !Number.isFinite(v)) throw new UserError(`${name} must be a number`);
  return v;
}

// ------------------------------------------------------------------ shell

export function runShell(command, timeoutS) {
  const limit = Math.min(Math.max(Number(timeoutS) || LIMITS.execDefaultS, 1), LIMITS.execMaxS);
  return new Promise((resolve) => {
    const child = spawn('bash', ['-lc', command], {
      cwd: WORK_DIR,
      env: { ...process.env, COMPUTADOR_TOKEN: '' },
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const cap = LIMITS.outputChars * 2;
    child.stdout.on('data', (d) => { if (stdout.length < cap) stdout += d; });
    child.stderr.on('data', (d) => { if (stderr.length < cap) stderr += d; });
    const timer = setTimeout(() => {
      timedOut = true;
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
    }, limit * 1000);
    // Resolve when the command itself ends, not when every process that
    // inherited its output does: a server started in the background
    // (`nohup ... &`) keeps running and must not hold the answer.
    let settled = false;
    const finish = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdout.destroy();
      child.stderr.destroy();
      const out = clip(stdout, LIMITS.outputChars);
      const err = clip(stderr, LIMITS.outputChars);
      resolve({
        exit_code: code === null ? -1 : code,
        signal: signal || null,
        timed_out: timedOut,
        stdout: out.text,
        stderr: err.text,
        truncated: out.truncated || err.truncated,
      });
    };
    child.on('exit', (code, signal) => setTimeout(() => finish(code, signal), 100));
    child.on('close', (code, signal) => finish(code, signal));
    child.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ exit_code: -1, signal: null, timed_out: false, stdout: '', stderr: String(e.message), truncated: false });
    });
  });
}

// ------------------------------------------------------------------ files

async function readFile(args) {
  const p = resolvePath(args.path);
  const handle = await fs.open(p, 'r');
  try {
    const { size } = await handle.stat();
    const length = Math.min(size, LIMITS.fileReadBytes);
    const buf = Buffer.alloc(length);
    await handle.read(buf, 0, length, 0);
    return { path: p, size, content: buf.toString('utf8'), truncated: size > length };
  } finally {
    await handle.close();
  }
}

async function writeFile(args) {
  const p = resolvePath(args.path);
  const content = typeof args.content === 'string' ? args.content : '';
  await fs.mkdir(path.dirname(p), { recursive: true });
  await fs.writeFile(p, content, 'utf8');
  return { path: p, bytes: Buffer.byteLength(content) };
}

async function listDir(args) {
  const p = resolvePath(args.path || '.');
  const entries = await fs.readdir(p, { withFileTypes: true });
  const shown = entries.slice(0, LIMITS.listEntries).map((e) => (e.isDirectory() ? e.name + '/' : e.name));
  return { path: p, entries: shown, truncated: entries.length > shown.length };
}

// ---------------------------------------------------------------- browser

let browserContext = null;
let chain = Promise.resolve();

// Browser operations share one page, so they run one at a time.
function serial(task) {
  const next = chain.then(task, task);
  chain = next.catch(() => {});
  return next;
}

async function page() {
  if (!browserContext) {
    const { chromium } = await import('playwright');
    browserContext = await chromium.launchPersistentContext(PROFILE_DIR, {
      headless: true,
      viewport: VIEWPORT,
      locale: 'pt-BR',
      timezoneId: process.env.TZ || 'America/Sao_Paulo',
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    });
    browserContext.setDefaultTimeout(LIMITS.browserTimeoutMs);
    browserContext.on('close', () => { browserContext = null; });
  }
  const pages = browserContext.pages();
  return pages.length > 0 ? pages[pages.length - 1] : browserContext.newPage();
}

async function where(p) {
  let title = '';
  try { title = await p.title(); } catch { /* page navigating */ }
  return { url: p.url(), title };
}

const BROWSER_OPS = {
  async goto(p, args) {
    const url = requireString(args, 'url');
    if (!/^https?:\/\//i.test(url)) throw new UserError('url must start with http:// or https://');
    const res = await p.goto(url, { waitUntil: 'domcontentloaded' });
    return { status: res ? res.status() : null };
  },
  async back(p) { await p.goBack({ waitUntil: 'domcontentloaded' }); return {}; },
  async click(p, args) {
    if (typeof args.selector === 'string' && args.selector !== '') {
      await p.click(args.selector);
    } else {
      await p.mouse.click(requireNumber(args, 'x'), requireNumber(args, 'y'));
    }
    await p.waitForLoadState('domcontentloaded').catch(() => {});
    return {};
  },
  async type(p, args) {
    const text = typeof args.text === 'string' ? args.text : '';
    if (typeof args.selector === 'string' && args.selector !== '') {
      await p.fill(args.selector, text);
    } else {
      await p.keyboard.type(text);
    }
    return {};
  },
  async press(p, args) {
    await p.keyboard.press(requireString(args, 'key'));
    await p.waitForLoadState('domcontentloaded').catch(() => {});
    return {};
  },
  async scroll(p, args) {
    const dy = typeof args.y === 'number' ? args.y : 600;
    await p.mouse.wheel(0, dy);
    return {};
  },
  async text(p) {
    const body = await p.evaluate(() => (document.body ? document.body.innerText : ''));
    const clipped = clip(body, LIMITS.pageTextChars);
    return { text: clipped.text, truncated: clipped.truncated };
  },
  async screenshot(p) {
    const buf = await p.screenshot({ type: 'jpeg', quality: 70 });
    return { image: 'data:image/jpeg;base64,' + buf.toString('base64'), width: VIEWPORT.width, height: VIEWPORT.height };
  },
  async evaluate(p, args) {
    const script = requireString(args, 'script');
    const value = await p.evaluate(script);
    const asText = value === undefined ? 'undefined' : JSON.stringify(value);
    const clipped = clip(asText ?? String(value), LIMITS.outputChars);
    return { value: clipped.text, truncated: clipped.truncated };
  },
};

async function browserOp(name, args) {
  if (name === 'close') {
    if (browserContext) await browserContext.close();
    browserContext = null;
    return {};
  }
  const op = BROWSER_OPS[name];
  const p = await page();
  const result = await op(p, args);
  return { ...(await where(p)), ...result };
}

// ---------------------------------------------------------------- routing

export const OPS = ['exec', 'read_file', 'write_file', 'list', ...Object.keys(BROWSER_OPS), 'close'];

export async function run(body) {
  const op = typeof body.op === 'string' ? body.op : '';
  switch (op) {
    case 'exec': return runShell(requireString(body, 'command'), body.timeout_s);
    case 'read_file': return readFile(body);
    case 'write_file': return writeFile(body);
    case 'list': return listDir(body);
    default:
      if (op === 'close' || Object.hasOwn(BROWSER_OPS, op)) return serial(() => browserOp(op, body));
      throw new UserError(`unknown op "${op}"; expected one of: ${OPS.join(', ')}`);
  }
}

function send(res, status, payload) {
  const data = JSON.stringify(payload);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) });
  res.end(data);
}

export function authorized(req, token) {
  if (!token) return true;
  return req.headers['authorization'] === `Bearer ${token}`;
}

export function createServer(token = process.env.COMPUTADOR_TOKEN || '') {
  return http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true });
    if (req.method !== 'POST' || req.url !== '/v1/run') return send(res, 404, { ok: false, error: 'not found' });
    if (!authorized(req, token)) return send(res, 401, { ok: false, error: 'unauthorized' });
    let raw = '';
    let tooBig = false;
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > LIMITS.bodyBytes) { tooBig = true; req.destroy(); }
    });
    req.on('end', async () => {
      if (tooBig) return;
      let body;
      try { body = JSON.parse(raw); } catch { return send(res, 400, { ok: false, error: 'body must be JSON' }); }
      if (body === null || typeof body !== 'object') return send(res, 400, { ok: false, error: 'body must be a JSON object' });
      try {
        send(res, 200, { ok: true, ...(await run(body)) });
      } catch (e) {
        const message = String(e && e.message ? e.message : e).split('\n')[0].slice(0, 500);
        send(res, e instanceof UserError ? 400 : 200, { ok: false, error: message });
      }
    });
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  await fs.mkdir(WORK_DIR, { recursive: true });
  const port = Number(process.env.COMPUTADOR_PORT || 7070);
  createServer().listen(port, '0.0.0.0', () => {
    console.log(`computador: listening on :${port}, work dir ${WORK_DIR}`);
  });
}
