import { test } from 'node:test';
import assert from 'node:assert/strict';
import { check, nodesOf, portName, readConf } from './sites.js';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { readFileSync } from 'node:fs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const real = JSON.parse(readFileSync(join(root, 'config/sites.json'), 'utf8'));
const conf = readConf(join(root, 'config/defaults.conf'));

test('the tracked topology and defaults are valid', () => {
  assert.deepEqual(check(real, conf), []);
});

test('node and port names', () => {
  assert.deepEqual(nodesOf({ id: 'ams', nodes: 3 }), ['vault-ams-1', 'vault-ams-2', 'vault-ams-3']);
  assert.equal(portName('seal-dub'), 'VBAL_PORT_SEAL_DUB');
  assert.equal(portName('vault-fra-2'), 'VBAL_PORT_VAULT_FRA_2');
  assert.throws(() => portName('frontdoor'));
});

test('exactly one primary', () => {
  const two = { sites: real.sites.map((s) => ({ ...s, role: 'primary' })) };
  assert.match(check(two, conf).join(), /exactly one site must be primary \(found 3\)/);
});

test('a duplicate port is named', () => {
  const errors = check(real, { ...conf, VBAL_PORT_VAULT_FRA_1: conf.VBAL_PORT_VAULT_AMS_1 });
  assert.match(errors.join(), /VBAL_PORT_VAULT_FRA_1=19101 is also VBAL_PORT_VAULT_AMS_1/);
});

test('a missing port and a bad role are reported', () => {
  const { VBAL_PORT_API, ...noApi } = conf;
  assert.match(check(real, noApi).join(), /VBAL_PORT_API is not set/);
  const bad = { sites: [{ ...real.sites[0], role: 'leader' }, ...real.sites.slice(1)] };
  assert.match(check(bad, conf).join(), /role must be one of/);
});
