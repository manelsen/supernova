// The screen a person can take over (PRD-K, K15, K16, K-09): a virtual
// display (Xvfb), a VNC server on it (x11vnc, localhost only, with a random
// password only svc can read) and noVNC over websockify. The browser is
// reopened on it with the same profile, so the person sees the page the
// agent was on, and the gate still watches every request.
//
// The dispatcher serves it to the person through a one-use link; when the
// link ends, the screen closes and the browser goes back to headless.

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const DISPLAY = ':99';
export const WEB_PORT = 6080;
const VNC_PORT = 5900;

let stack = null;

export function isOpen() {
  return stack !== null;
}

function waitFor(check, ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (check()) return resolve();
      if (Date.now() > deadline) return reject(new Error('the screen did not start'));
      setTimeout(tick, 100);
    };
    tick();
  });
}

function start(command, args, env) {
  const child = spawn(command, args, { env, stdio: 'ignore', detached: true });
  child.on('error', () => {});
  return child;
}

/// Open the screen; returns the VNC password for the noVNC page.
export async function open() {
  if (stack) return { senha: stack.password };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tela-'));
  fs.chmodSync(dir, 0o700);
  // VNC passwords are at most 8 characters.
  const password = randomBytes(6).toString('base64url').slice(0, 8);
  const passFile = path.join(dir, 'vnc.pass');
  const env = { PATH: process.env.PATH, HOME: process.env.HOME || os.homedir() };
  await new Promise((resolve, reject) => {
    const store = spawn('x11vnc', ['-storepasswd', password, passFile], { stdio: 'ignore' });
    store.on('exit', (code) => (code === 0 ? resolve() : reject(new Error('could not set the screen password'))));
    store.on('error', reject);
  });
  fs.chmodSync(passFile, 0o600);
  // The display wants a cookie only svc can read: the shell's user (sh)
  // could otherwise watch the screen or type into it while the person
  // types a password.
  const authFile = path.join(dir, 'Xauthority');
  const cookie = randomBytes(16).toString('hex');
  await new Promise((resolve, reject) => {
    const add = spawn('xauth', ['-q', '-f', authFile, 'add', DISPLAY, '.', cookie], { stdio: 'ignore' });
    add.on('exit', (code) => (code === 0 ? resolve() : reject(new Error('could not set the screen cookie'))));
    add.on('error', reject);
  });
  fs.chmodSync(authFile, 0o600);
  const xvfb = start('Xvfb', [DISPLAY, '-screen', '0', '1280x800x24', '-nolisten', 'tcp', '-auth', authFile], env);
  const socket = `/tmp/.X11-unix/X${DISPLAY.slice(1)}`;
  await waitFor(() => fs.existsSync(socket), 10_000);
  const vnc = start('x11vnc', ['-display', DISPLAY, '-auth', authFile, '-localhost', '-rfbport', String(VNC_PORT),
    '-rfbauth', passFile, '-forever', '-shared', '-quiet', '-noxdamage'], env);
  const web = start('websockify', ['--web', '/usr/share/novnc', String(WEB_PORT), `localhost:${VNC_PORT}`], env);
  stack = { xvfb, vnc, web, dir, password, authFile };
  // Give the VNC server a moment to listen.
  await new Promise((r) => setTimeout(r, 500));
  return { senha: password };
}

/// Close the screen and everything it started.
export function close() {
  if (!stack) return;
  for (const child of [stack.web, stack.vnc, stack.xvfb]) {
    try { process.kill(-child.pid, 'SIGTERM'); } catch { /* gone */ }
  }
  try { fs.rmSync(stack.dir, { recursive: true, force: true }); } catch { /* gone */ }
  stack = null;
}

/// The browser's launch options while the screen is open.
export function launchOptions() {
  if (!stack) return { headless: true };
  return { headless: false, env: { ...process.env, DISPLAY, XAUTHORITY: stack.authFile } };
}

/// Whether the page shows a captcha (K15): the agent must not solve it.
export async function hasCaptcha(page) {
  const found = await page.$([
    'iframe[src*="recaptcha"]', 'iframe[src*="hcaptcha"]', 'iframe[src*="turnstile"]',
    'iframe[src*="challenges.cloudflare"]', '[class*="captcha" i]', '[id*="captcha" i]',
    'div.g-recaptcha', 'div.h-captcha', 'div.cf-turnstile',
  ].join(', ')).catch(() => null);
  return Boolean(found);
}
