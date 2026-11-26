// Tests for the probes' MCP servers (PRD-S, S-03). No network: files live
// in a temporary folder, and the browser only opens blank tabs and a page
// on this machine, which it must refuse.
//   docker run --rm --runtime=runsc supernova-computador npm test --prefix /opt/computador
import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';

const people = await fs.mkdtemp(path.join(os.tmpdir(), 'pessoas-'));
process.env.COMPUTADOR_PEOPLE_DIR = people;
const { browserContexts, shutdown, mcp, MCP_LIMITS, McpUserError, openSessions, personDir, probeDir, setClock, sweepIdle, urlsAllowed } =
  await import('../mcp.mjs');
const { createServer } = await import('../agent.mjs');

after(() => shutdown());

const ANA = 'a1b2c3d4';
const BIA = 'b1b2c3d4';
let nextId = 1;

async function call(session, method, params = {}) {
  const id = nextId++;
  const { resposta } = await mcp({ acao: 'chamar', sessao: session, mensagem: { jsonrpc: '2.0', id, method, params } });
  return resposta;
}

async function open(session, servidor, pessoa, sonda = 1) {
  await mcp({ acao: 'abrir', sessao: session, servidor, pessoa, sonda });
  const init = await call(session, 'initialize', {
    protocolVersion: '2025-11-25',
    capabilities: {},
    clientInfo: { name: 'teste', version: '0' },
  });
  assert.ok(init.result, JSON.stringify(init));
  await mcp({ acao: 'chamar', sessao: session, mensagem: { jsonrpc: '2.0', method: 'notifications/initialized' } });
}

function text(answer) {
  return (answer.result?.content ?? []).map((item) => item.text ?? '').join('\n');
}

test('only http(s) URLs pass, at any depth', () => {
  assert.equal(urlsAllowed({ url: 'https://example.com' }), true);
  assert.equal(urlsAllowed({ url: 'HTTP://example.com' }), true);
  assert.equal(urlsAllowed({ url: 'file:///etc/passwd' }), false);
  assert.equal(urlsAllowed({ url: 'javascript:alert(1)' }), false);
  assert.equal(urlsAllowed({ tabs: [{ url: 'file:///x' }] }), false);
  assert.equal(urlsAllowed({ text: 'file:///x' }), true);
});

test('person and probe folders are checked', () => {
  assert.equal(personDir(ANA), path.join(people, ANA));
  assert.equal(probeDir(ANA, 3), path.join(people, ANA, 'sondas', '3'));
  for (const bad of ['../x', 'ABCDEF12', 'a1b2', '', 5]) assert.throws(() => personDir(bad), McpUserError);
  assert.throws(() => probeDir(ANA, 0), McpUserError);
  assert.throws(() => probeDir(ANA, 1.5), McpUserError);
});

test('requests are checked before anything opens', async () => {
  await assert.rejects(mcp({ acao: 'abrir', sessao: 'x', servidor: 'shell', pessoa: ANA, sonda: 1 }), McpUserError);
  await assert.rejects(mcp({ acao: 'abrir', sessao: 'a b', servidor: 'filesystem', pessoa: ANA, sonda: 1 }), McpUserError);
  await assert.rejects(mcp({ acao: 'chamar', sessao: 'nenhuma', mensagem: { method: 'x' } }), McpUserError);
  await assert.rejects(mcp({ acao: 'voar' }), McpUserError);
});

test('http: /v1/mcp has the same door as /v1/run', async () => {
  const server = createServer('segredo');
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  const post = (headers) => fetch(`http://127.0.0.1:${port}/v1/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ acao: 'fechar', sessao: 'x' }),
  });
  try {
    assert.equal((await post({})).status, 401);
    assert.equal((await post({ authorization: 'Bearer segredo', origin: 'https://evil.example' })).status, 403);
    const ok = await post({ authorization: 'Bearer segredo' });
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { ok: true, fechada: false });
  } finally {
    server.close();
  }
});

test('filesystem: reads and writes inside the person folder only', { timeout: 60_000 }, async () => {
  await fs.mkdir(personDir(ANA), { recursive: true });
  await fs.writeFile(path.join(personDir(ANA), 'nota.txt'), 'da Ana');
  await fs.mkdir(personDir(BIA), { recursive: true });
  await fs.writeFile(path.join(personDir(BIA), 'segredo.txt'), 'da Bia');
  await fs.symlink(path.join(personDir(BIA), 'segredo.txt'), path.join(personDir(ANA), 'atalho.txt'));
  await open('fs-ana', 'filesystem', ANA);
  try {
    const tools = await call('fs-ana', 'tools/list');
    const names = tools.result.tools.map((tool) => tool.name);
    assert.ok(names.includes('read_text_file') || names.includes('read_file'), names.join(','));
    const read = names.includes('read_text_file') ? 'read_text_file' : 'read_file';

    const mine = await call('fs-ana', 'tools/call', { name: read, arguments: { path: path.join(personDir(ANA), 'nota.txt') } });
    assert.match(text(mine), /da Ana/);
    const wrote = await call('fs-ana', 'tools/call', {
      name: 'write_file',
      arguments: { path: path.join(personDir(ANA), 'nova.txt'), content: 'oi' },
    });
    assert.notEqual(wrote.result?.isError, true, JSON.stringify(wrote));
    assert.equal(await fs.readFile(path.join(personDir(ANA), 'nova.txt'), 'utf8'), 'oi');

    // Out of the folder: by "..", by an absolute path, by a symbolic link.
    for (const outside of [
      path.join(personDir(ANA), '..', BIA, 'segredo.txt'),
      path.join(personDir(BIA), 'segredo.txt'),
      '/etc/passwd',
      path.join(personDir(ANA), 'atalho.txt'),
    ]) {
      const answer = await call('fs-ana', 'tools/call', { name: read, arguments: { path: outside } });
      const refused = answer.error !== undefined || answer.result?.isError === true;
      assert.ok(refused, `${outside}: ${JSON.stringify(answer)}`);
      assert.doesNotMatch(JSON.stringify(answer), /da Bia|root:/);
    }
  } finally {
    await mcp({ acao: 'fechar', sessao: 'fs-ana' });
  }
});

test('the file server does not see the service token', { timeout: 60_000 }, async () => {
  process.env.COMPUTADOR_TOKEN = 'segredo-do-servico';
  await open('fs-env', 'filesystem', ANA);
  try {
    // The server's environment holds only PATH and HOME (see mcp.mjs);
    // listing its folder works, and nothing names the token.
    const listed = await call('fs-env', 'tools/call', { name: 'list_directory', arguments: { path: personDir(ANA) } });
    assert.doesNotMatch(JSON.stringify(listed), /segredo-do-servico/);
  } finally {
    delete process.env.COMPUTADOR_TOKEN;
    await mcp({ acao: 'fechar', sessao: 'fs-env' });
  }
});

test('the whole result of a probe is kept in its folder', async () => {
  await mcp({ acao: 'guardar_resultado', pessoa: ANA, sonda: 9, texto: '# Resultado\ntudo' });
  assert.equal(await fs.readFile(path.join(probeDir(ANA, 9), 'resultado.md'), 'utf8'), '# Resultado\ntudo');
  await assert.rejects(mcp({ acao: 'guardar_resultado', pessoa: '../x', sonda: 9, texto: 'x' }), McpUserError);
  await assert.rejects(mcp({ acao: 'guardar_resultado', pessoa: ANA, sonda: 9 }), McpUserError);
});

test('idle sessions close after five minutes', async () => {
  let clock = 1_000_000;
  setClock(() => clock);
  const closed = [];
  const fake = (name) => async () => ({ kind: name, call: async () => null, close: async () => { closed.push(name); } });
  const opener = { playwright: fake('playwright'), filesystem: fake('filesystem') };
  try {
    await mcp({ acao: 'abrir', sessao: 'parada', servidor: 'filesystem', pessoa: ANA, sonda: 1 }, opener);
    await mcp({ acao: 'abrir', sessao: 'ativa', servidor: 'playwright', pessoa: ANA, sonda: 2 }, opener);
    clock += MCP_LIMITS.idleMs - 1000;
    await mcp({ acao: 'chamar', sessao: 'ativa', mensagem: { jsonrpc: '2.0', method: 'notifications/initialized' } });
    clock += 2000;
    assert.deepEqual(await sweepIdle(), ['parada']);
    assert.deepEqual(closed, ['filesystem']);
    assert.ok(openSessions().includes('ativa'));
    await mcp({ acao: 'fechar', sessao: 'ativa' });
  } finally {
    setClock(() => Date.now());
  }
});

test('forgetting a person closes their sessions and deletes their folder', async () => {
  const closed = [];
  const fake = async () => ({ kind: 'filesystem', call: async () => null, close: async () => { closed.push('x'); } });
  await fs.mkdir(probeDir(BIA, 7), { recursive: true });
  await mcp({ acao: 'abrir', sessao: 'da-bia', servidor: 'filesystem', pessoa: BIA, sonda: 7 }, { filesystem: fake, playwright: fake });
  await mcp({ acao: 'apagar_pessoa', pessoa: BIA });
  assert.deepEqual(closed, ['x']);
  assert.equal(openSessions().includes('da-bia'), false);
  await assert.rejects(fs.stat(personDir(BIA)));
});

test('browser: a context per session, two tabs at most, no code, no local pages', { timeout: 180_000 }, async () => {
  const local = http.createServer((req, res) => res.end('servico local'));
  local.listen(0, '127.0.0.1');
  await once(local, 'listening');
  await open('web-1', 'playwright', ANA, 1);
  await open('web-2', 'playwright', ANA, 2);
  try {
    assert.equal(browserContexts(), 2);
    const names = (await call('web-1', 'tools/list')).result.tools.map((tool) => tool.name);
    assert.ok(names.includes('browser_navigate'));
    for (const hidden of ['browser_run_code_unsafe', 'browser_file_upload', 'browser_drop']) {
      assert.equal(names.includes(hidden), false, hidden);
    }
    const code = await call('web-1', 'tools/call', { name: 'browser_run_code_unsafe', arguments: { code: '1' } });
    assert.match(code.error.message, /not available/);
    const file = await call('web-1', 'tools/call', { name: 'browser_navigate', arguments: { url: 'file:///etc/passwd' } });
    assert.match(file.error.message, /http/);

    // This machine's own services are out of reach (the computer's service
    // listens here).
    const { port } = local.address();
    const here = await call('web-1', 'tools/call', { name: 'browser_navigate', arguments: { url: `http://127.0.0.1:${port}/` } });
    assert.doesNotMatch(JSON.stringify(here), /servico local/);

    // A third tab closes the oldest.
    for (let i = 0; i < 3; i += 1) await call('web-1', 'tools/call', { name: 'browser_tabs', arguments: { action: 'new' } });
    const tabs = await call('web-1', 'tools/call', { name: 'browser_tabs', arguments: { action: 'list' } });
    const listed = (text(tabs).match(/^- \d+:/gm) ?? []).length;
    assert.ok(listed <= MCP_LIMITS.maxTabs, text(tabs));

    await mcp({ acao: 'fechar', sessao: 'web-1' });
    assert.equal(browserContexts(), 1);
  } finally {
    await mcp({ acao: 'fechar', sessao: 'web-1' });
    await mcp({ acao: 'fechar', sessao: 'web-2' });
    local.close();
  }
});

test('two opens of one session at once: one wins, nothing leaks', async () => {
  const closed = [];
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const slow = async () => {
    await gate;
    return { kind: 'filesystem', call: async () => null, close: async () => { closed.push('x'); } };
  };
  const opener = { filesystem: slow, playwright: slow };
  const first = mcp({ acao: 'abrir', sessao: 'dupla', servidor: 'filesystem', pessoa: ANA, sonda: 1 }, opener);
  await assert.rejects(
    mcp({ acao: 'abrir', sessao: 'dupla', servidor: 'filesystem', pessoa: ANA, sonda: 1 }, opener),
    McpUserError,
  );
  release();
  await first;
  assert.equal(openSessions().filter((id) => id === 'dupla').length, 1);
  await mcp({ acao: 'fechar', sessao: 'dupla' });
  assert.deepEqual(closed, ['x']);
});

test('a session that finishes opening after its person was forgotten is closed', async () => {
  const closed = [];
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const slow = async () => {
    await gate;
    return { kind: 'filesystem', call: async () => null, close: async () => { closed.push('x'); } };
  };
  const opening = mcp({ acao: 'abrir', sessao: 'tardia', servidor: 'filesystem', pessoa: BIA, sonda: 3 }, { filesystem: slow, playwright: slow });
  await mcp({ acao: 'apagar_pessoa', pessoa: BIA });
  release();
  await assert.rejects(opening, McpUserError);
  assert.equal(openSessions().includes('tardia'), false);
  assert.deepEqual(closed, ['x']);
});

test('an unanswered call frees its slot, and a repeated id waits for nothing', async () => {
  const limit = MCP_LIMITS.callMs;
  MCP_LIMITS.callMs = 50;
  const forgotten = [];
  const pending = new Set();
  const fake = async () => ({
    kind: 'filesystem',
    call: (message) => {
      if (pending.has(message.id)) return Promise.resolve({ jsonrpc: '2.0', id: message.id, error: { message: 'a request with this id is already waiting' } });
      pending.add(message.id);
      return new Promise(() => {});
    },
    forget: (id) => { forgotten.push(id); pending.delete(id); },
    close: async () => {},
  });
  try {
    await mcp({ acao: 'abrir', sessao: 'muda', servidor: 'filesystem', pessoa: ANA, sonda: 4 }, { filesystem: fake, playwright: fake });
    const { resposta } = await mcp({ acao: 'chamar', sessao: 'muda', mensagem: { jsonrpc: '2.0', id: 7, method: 'x' } });
    assert.match(resposta.error.message, /no answer/);
    assert.deepEqual(forgotten, [7]);
  } finally {
    MCP_LIMITS.callMs = limit;
    await mcp({ acao: 'fechar', sessao: 'muda' });
  }
});
