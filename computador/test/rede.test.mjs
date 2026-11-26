// What the computer's browsers may not reach (rede.mjs). No network: only
// addresses and names that need no lookup.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { hostBlocked, internalAddress } from '../rede.mjs';

test('internal addresses, IPv4 and IPv6', () => {
  for (const ip of ['127.0.0.1', '127.0.0.2', '0.0.0.0', '10.1.2.3', '172.16.0.1', '172.31.255.255',
    '192.168.0.10', '169.254.169.254', '100.64.0.1', '224.0.0.1', '::1', '::', 'fc00::1', 'fd12::3',
    'fe80::1', '::ffff:127.0.0.1', '::ffff:10.0.0.1', '::ffff:7f00:1']) {
    assert.equal(internalAddress(ip), true, ip);
  }
  for (const ip of ['1.1.1.1', '8.8.8.8', '172.32.0.1', '100.128.0.1', '2606:4700::1111', '::ffff:1.1.1.1']) {
    assert.equal(internalAddress(ip), false, ip);
  }
});

test('hosts as a URL writes them', async () => {
  // The URL parser turns 2130706433 and 0x7f.1 into 127.x.x.x.
  for (const raw of ['http://localhost/', 'http://app.localhost/', 'http://[::1]:7070/', 'http://0.0.0.0:7070/',
    'http://127.0.0.2/', 'http://2130706433/', 'http://0x7f.1/', 'http://[::ffff:7f00:1]/', 'http://10.0.0.5/']) {
    assert.equal(await hostBlocked(new URL(raw).hostname), true, raw);
  }
  assert.equal(await hostBlocked(new URL('http://1.1.1.1/').hostname), false);
});
