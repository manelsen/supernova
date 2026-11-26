// The launcher's shell, as user sh (PRD-K, K-05). Only where it can run:
// as root with SETUID/SETGID (the image's test run gives them).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import net from 'node:net';
import { shellServer, shellEnv, serviceEnv, SH, SCRATCH } from '../lancador.mjs';

const root = process.getuid && process.getuid() === 0;

function ask(socketPath, command) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath, () => socket.end(JSON.stringify({ command, timeout_s: 10 }) + '\n'));
    let answer = '';
    socket.on('data', (d) => { answer += d; });
    socket.on('end', () => resolve(JSON.parse(answer)));
    socket.on('error', reject);
  });
}

test('the shell gets the proxy without credential, and no secret', () => {
  const env = shellEnv({ SAIDA_URL: 'http://172.20.0.2:3128', SAIDA_SENHA: 'segredo', COMPUTADOR_TOKEN: 't' });
  assert.equal(env.HTTPS_PROXY, 'http://172.20.0.2:3128');
  assert.equal(env.https_proxy, 'http://172.20.0.2:3128');
  assert.equal(JSON.stringify(env).includes('segredo'), false);
  assert.equal(env.COMPUTADOR_TOKEN, undefined);
  assert.equal(env.HOME, SCRATCH);
});

test('the service gets its token and the credential, nothing else of the launcher', () => {
  const env = serviceEnv({ SAIDA_SENHA: 's', COMPUTADOR_TOKEN: 't', OUTRA: 'x', SAIDA_URL: 'u' });
  assert.equal(env.SAIDA_SENHA, 's');
  assert.equal(env.COMPUTADOR_TOKEN, 't');
  assert.equal(env.OUTRA, undefined);
});

test('commands run as sh, which reads no credential', { skip: !root && 'needs root' }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lancador-'));
  fs.chmodSync(dir, 0o755);
  const socketPath = path.join(dir, 'shell.sock');
  fs.mkdirSync(SCRATCH, { recursive: true });
  fs.chownSync(SCRATCH, SH.uid, SH.gid);
  // A secret this (root) process holds, and one svc keeps in a 0600 file.
  process.env.SAIDA_SENHA = 'segredo-do-svc';
  const secretFile = path.join(dir, 'credencial');
  fs.writeFileSync(secretFile, 'segredo-do-svc', { mode: 0o600 });
  fs.chownSync(secretFile, 1001, 1001);
  const server = shellServer({ SAIDA_URL: 'http://172.20.0.2:3128', SAIDA_SENHA: 'segredo-do-svc' });
  server.listen(socketPath);
  await once(server, 'listening');
  try {
    const who = await ask(socketPath, 'id -u; pwd; echo "$HTTPS_PROXY"');
    assert.deepEqual(who.stdout.trim().split('\n'), [String(SH.uid), SCRATCH, 'http://172.20.0.2:3128']);
    const leak = await ask(socketPath, `env; cat /proc/${process.pid}/environ; cat ${secretFile}; cat /proc/1/environ; true`);
    assert.equal((leak.stdout + leak.stderr).includes('segredo-do-svc'), false);
    // The person's folder is svc's: the shell reads it, cannot change it
    // (K22); it writes in its scratch folder.
    const folder = path.join(dir, 'trabalho');
    fs.mkdirSync(folder, { mode: 0o755 });
    fs.writeFileSync(path.join(folder, 'nota.txt'), 'da pessoa', { mode: 0o644 });
    fs.chownSync(path.join(folder, 'nota.txt'), 1001, 1001);
    fs.chownSync(folder, 1001, 1001);
    const files = await ask(socketPath, `cat ${folder}/nota.txt; rm -f ${folder}/nota.txt; echo x > ${folder}/nota.txt; touch ${folder}/nova.txt; echo ok > rascunho.txt && cat rascunho.txt`);
    assert.match(files.stdout, /da pessoa/);
    assert.match(files.stdout, /ok/);
    assert.equal(fs.readFileSync(path.join(folder, 'nota.txt'), 'utf8'), 'da pessoa');
    assert.equal(fs.existsSync(path.join(folder, 'nova.txt')), false);
    // Not root, no way back to root.
    const sudo = await ask(socketPath, 'cat /etc/shadow');
    assert.notEqual(sudo.exit_code, 0);
  } finally {
    server.close();
    delete process.env.SAIDA_SENHA;
  }
});
