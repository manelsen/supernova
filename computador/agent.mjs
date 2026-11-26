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
// answers {"ok": true}. POST /v1/mcp opens, calls and closes the MCP
// servers of Supernova's probes (see mcp.mjs), behind the same checks.

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { mcp, McpUserError, sweepIdle } from './mcp.mjs';
import { guard } from './rede.mjs';

export const LIMITS = {
  bodyBytes: 4 * 1024 * 1024,
  outputChars: 20_000,
  pageTextChars: 15_000,
  fileReadBytes: 200_000,
  listEntries: 200,
  execDefaultS: 60,
  execMaxS: 300,
  browserTimeoutMs: 30_000,
  // A whole browser operation; below the 60 s Supernova waits for an answer.
  browserOpMs: 45_000,
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
    // Decode as UTF-8 across chunk boundaries.
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
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
// Bumped when an operation times out: a launch that finishes after that
// belongs to an abandoned operation and must not become the browser.
let generation = 0;
// Settles when the last abandoned browser has closed (or gave up closing),
// so the next launch does not fight it for the profile directory.
let closing = Promise.resolve();
// Settles when the last launch has finished, successful or not. An
// abandoned launch may still be starting Chromium on the profile.
let launching = Promise.resolve();
// True from the moment Chromium is asked to start until that launch settles.
let launchInFlight = false;
const CLOSE_WAIT_MS = 10_000;

// Waits for `promise`, but at most `ms`. The timer is cleared as soon as
// either side wins, so it never keeps the process alive.
function bounded(promise, ms) {
  let timer;
  const expired = new Promise((resolve) => { timer = setTimeout(resolve, ms); });
  return Promise.race([promise, expired]).finally(() => clearTimeout(timer));
}

// Browser operations share one page, so they run one at a time. Each one has
// a deadline: Playwright can wait forever (a page script that never
// settles), and a stuck operation would block every later one. On timeout
// the browser is thrown away; the next operation starts a fresh one with the
// same profile.
function serial(task) {
  const next = chain.then(() => withDeadline(task), () => withDeadline(task));
  chain = next.catch(() => {});
  return next;
}

function closeBounded(context) {
  return bounded(context.close().catch(() => {}), CLOSE_WAIT_MS);
}

async function withDeadline(task) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('timeout')), LIMITS.browserOpMs);
  });
  try {
    return await Promise.race([task(generation), deadline]);
  } catch (e) {
    if (e && e.message === 'timeout') {
      generation += 1;
      const stuck = browserContext;
      browserContext = null;
      if (stuck) closing = closeBounded(stuck);
      throw new Error(`the browser did not answer within ${LIMITS.browserOpMs / 1000} s and was restarted`);
    }
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

async function page(gen) {
  if (!browserContext) {
    // Read `closing` only after the previous launch settled: an abandoned
    // launch sets it before `launching` settles.
    await bounded(launching, LIMITS.browserOpMs + CLOSE_WAIT_MS);
    // An expired wait is no permission to launch: the old launch could
    // still start Chromium on the same profile.
    if (launchInFlight) throw new Error('the browser is still starting; try again shortly');
    await closing;
    const { chromium } = await import('playwright');
    // This operation timed out while waiting; a newer one owns the browser.
    // No await between this check and the launch below.
    if (gen !== generation) throw new Error('abandoned operation');
    const attempt = (async () => {
      const launched = await chromium.launchPersistentContext(PROFILE_DIR, {
        headless: true,
        viewport: VIEWPORT,
        locale: 'pt-BR',
        timezoneId: process.env.TZ || 'America/Sao_Paulo',
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
        timeout: LIMITS.browserOpMs,
      });
      if (gen !== generation) {
        // This operation already timed out; do not let its browser linger.
        closing = closeBounded(launched);
        throw new Error('abandoned launch');
      }
      // Nothing internal: this machine, the Docker networks, the LAN.
      await guard(launched);
      launched.setDefaultTimeout(LIMITS.browserTimeoutMs);
      launched.on('close', () => { if (browserContext === launched) browserContext = null; });
      browserContext = launched;
    })();
    launchInFlight = true;
    launching = attempt.then(() => {}, () => {}).finally(() => { launchInFlight = false; });
    await attempt;
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
    try {
      const res = await p.goto(url, { waitUntil: 'domcontentloaded' });
      return { status: res ? res.status() : null };
    } catch (e) {
      // A blocked or failed navigation leaves Chromium loading its own error
      // page in this tab, which cuts the next navigation short (measured).
      // The next operation gets a fresh tab instead.
      await p.context().newPage().catch(() => {});
      await p.close().catch(() => {});
      throw e;
    }
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

async function browserOp(name, args, gen) {
  if (name === 'close') {
    const open = browserContext;
    browserContext = null;
    if (open) await closeBounded(open);
    return {};
  }
  const op = BROWSER_OPS[name];
  const p = await page(gen);
  const result = await op(p, args);
  return { ...(await where(p)), ...result };
}

/// For tests: whether a browser is open right now.
export function browserOpen() {
  return browserContext !== null;
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
      if (op === 'close' || Object.hasOwn(BROWSER_OPS, op)) return serial((gen) => browserOp(op, body, gen));
      throw new UserError(`unknown op "${op}"; expected one of: ${OPS.join(', ')}`);
  }
}

function send(res, status, payload) {
  const data = JSON.stringify(payload);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) });
  res.end(data);
}

// No token, no service: an empty COMPUTADOR_TOKEN refuses every request
// (and the service refuses to start without one, below).
export function authorized(req, token) {
  if (!token) return false;
  const given = Buffer.from(String(req.headers['authorization'] || ''));
  const wanted = Buffer.from(`Bearer ${token}`);
  return given.length === wanted.length && timingSafeEqual(given, wanted);
}

// The computer's own browser can reach this service on 127.0.0.1, so a page
// must not be able to drive it. Browsers send an Origin header and cannot send
// a cross-origin JSON POST without a preflight, which is never answered here.
// Supernova sends application/json and no Origin.
export function fromBrowser(req) {
  if (req.headers['origin'] !== undefined) return true;
  const type = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  return type !== 'application/json';
}

export function createServer(token = process.env.COMPUTADOR_TOKEN || '') {
  return http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true });
    const routes = { '/v1/run': run, '/v1/mcp': (body) => mcp(body) };
    const handler = req.method === 'POST' ? routes[req.url] : undefined;
    if (!handler) return send(res, 404, { ok: false, error: 'not found' });
    if (fromBrowser(req)) return send(res, 403, { ok: false, error: 'requests from a browser are refused' });
    if (!authorized(req, token)) return send(res, 401, { ok: false, error: 'unauthorized' });
    // Keep raw bytes and decode once, so a UTF-8 character split across
    // chunks survives.
    const chunks = [];
    let size = 0;
    let tooBig = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > LIMITS.bodyBytes) { tooBig = true; req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on('end', async () => {
      if (tooBig) return;
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return send(res, 400, { ok: false, error: 'body must be JSON' }); }
      if (body === null || typeof body !== 'object') return send(res, 400, { ok: false, error: 'body must be a JSON object' });
      try {
        send(res, 200, { ok: true, ...(await handler(body)) });
      } catch (e) {
        const message = String(e && e.message ? e.message : e).split('\n')[0].slice(0, 500);
        const userError = e instanceof UserError || e instanceof McpUserError;
        send(res, userError ? 400 : 200, { ok: false, error: message });
      }
    });
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  if (!process.env.COMPUTADOR_TOKEN) {
    console.error('computador: COMPUTADOR_TOKEN is empty; refusing to start without authentication');
    process.exit(1);
  }
  await fs.mkdir(WORK_DIR, { recursive: true });
  const port = Number(process.env.COMPUTADOR_PORT || 7070);
  // Probe sessions nobody used for five minutes are closed.
  setInterval(() => { sweepIdle().catch(() => {}); }, 30_000).unref();
  createServer().listen(port, '0.0.0.0', () => {
    console.log(`computador: listening on :${port}, work dir ${WORK_DIR}`);
  });
}
