// The computer's first process (PRD-K, K-05, K-07). It runs as root, with
// only the capabilities it needs (CHOWN, SETUID, SETGID, KILL), and does
// two things:
//
// - starts the service (agent.mjs) as user svc, with the token and the
//   proxy credential, and stops when it stops;
// - runs the shell's commands as user sh, asked over a Unix socket only
//   svc can open: sh gets no token and no credential (its traffic goes to
//   the proxy without one, so only to the list of sites), a scratch folder
//   of its own, and the person's folder read-only.
//
// sh cannot read the credential: not from its environment (never given),
// nor from svc's or this process's (/proc/<pid>/environ of another user).

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { runAs } from './shell.mjs';

export const SVC = { uid: 1001, gid: 1001 };
export const SH = { uid: 1002, gid: 1002 };
export const HOME = '/home/pwuser';
export const SCRATCH = path.join(HOME, 'rascunho');
export const SOCKET_DIR = '/run/computador';
export const SOCKET = path.join(SOCKET_DIR, 'shell.sock');

/// What the shell sees: no secret, the proxy without credential.
export function shellEnv(env) {
  const proxy = env.SAIDA_URL || '';
  const out = {
    PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    HOME: SCRATCH,
    LANG: env.LANG || 'C.UTF-8',
    TZ: env.TZ || 'America/Sao_Paulo',
  };
  if (proxy) {
    for (const name of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy']) out[name] = proxy;
    out.NO_PROXY = out.no_proxy = 'localhost,127.0.0.1';
  }
  return out;
}

/// What the service sees: its token and the proxy credential, nothing of
/// the launcher's own.
export function serviceEnv(env) {
  const keep = ['COMPUTADOR_TOKEN', 'SAIDA_URL', 'SAIDA_USUARIO', 'SAIDA_SENHA', 'TZ', 'LANG', 'PLAYWRIGHT_BROWSERS_PATH', 'PATH'];
  const out = { HOME, COMPUTADOR_SHELL_SOCK: SOCKET };
  for (const name of keep) if (env[name] !== undefined) out[name] = env[name];
  return out;
}

/// A folder for `owner`. Root here has CHOWN but not FOWNER: the mode is
/// set while root still owns a new folder; an existing one keeps its mode.
function own(dir, owner, mode) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.chmodSync(dir, mode);
  }
  fs.chownSync(dir, owner.uid, owner.gid);
}

function prepare() {
  // The person's files are svc's; the shell has a scratch folder of its own.
  for (const dir of [HOME, path.join(HOME, 'trabalho'), path.join(HOME, '.navegador'), path.join(HOME, 'pessoas')]) {
    own(dir, SVC, 0o755);
  }
  own(SCRATCH, SH, 0o755);
  // The socket's folder stays root's; the socket itself is svc's, 0600.
  fs.mkdirSync(SOCKET_DIR, { recursive: true });
  fs.chmodSync(SOCKET_DIR, 0o755);
  try { fs.unlinkSync(SOCKET); } catch { /* none */ }
}

export function shellServer(env) {
  // The caller ends its side after the request; the answer still goes back.
  return net.createServer({ allowHalfOpen: true }, (socket) => {
    let request = '';
    socket.setEncoding('utf8');
    socket.on('data', (d) => {
      request += d;
      if (request.length > 1_000_000) socket.destroy();
    });
    socket.on('end', async () => {
      let asked;
      try { asked = JSON.parse(request); } catch { return socket.end(JSON.stringify({ exit_code: -1, stderr: 'bad request' })); }
      const answer = await runAs(String(asked.command || ''), asked.timeout_s, {
        cwd: SCRATCH, env: shellEnv(env), uid: SH.uid, gid: SH.gid,
      });
      socket.end(JSON.stringify(answer));
    });
    socket.on('error', () => {});
  });
}

function main() {
  prepare();
  const server = shellServer(process.env);
  server.listen(SOCKET, () => {
    // Mode first, while root still owns it (no FOWNER here).
    fs.chmodSync(SOCKET, 0o600);
    fs.chownSync(SOCKET, SVC.uid, SVC.gid);
    const service = spawn(process.execPath, ['/opt/computador/agent.mjs'], {
      cwd: path.join(HOME, 'trabalho'),
      env: serviceEnv(process.env),
      uid: SVC.uid,
      gid: SVC.gid,
      stdio: 'inherit',
    });
    service.on('exit', (code, signal) => process.exit(code === null ? (signal ? 1 : 0) : code));
    for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => service.kill(sig));
  });
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) main();
