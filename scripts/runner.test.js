import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { chmodSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRunner } from './runner.js';

const SITES = [
  { id: 'ams', name: 'Amsterdam', role: 'primary' },
  { id: 'fra', name: 'Frankfurt', role: 'performance' },
  { id: 'dub', name: 'Dublin', role: 'dr' },
];
const TOKENS = {
  oscar: { preferred_username: 'oscar', groups: ['drill-viewers', 'drill-operators'] },
  vera: { preferred_username: 'vera', groups: ['drill-viewers'] },
};
const verify = async (t) => {
  if (!TOKENS[t]) throw new Error('bad signature');
  return TOKENS[t];
};
function fakeSpawn(calls) {
  return (cmd, args, opts) => {
    calls.push({ cmd, args, env: opts.env });
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    setImmediate(() => {
      child.stdout.emit('data', 'PLAY RECAP ok\n');
      child.emit('close', 0);
    });
    return child;
  };
}
const setup = () => {
  const dir = mkdtempSync(join(tmpdir(), 'vbal-runner-'));
  const calls = [];
  const r = createRunner({ root: dir, secret: 's3cret', verify, sites: SITES, spawnImpl: fakeSpawn(calls), drillDir: join(dir, 'drill'), logDir: join(dir, 'logs') });
  return { r, calls };
};
const h = (token, secret = 's3cret') => ({ 'x-runner-secret': secret, authorization: `Bearer ${token}` });

test('an operator runs the next step; its make arguments come from sites.json; the journal gets their name', async () => {
  const { r, calls } = setup();
  const [code, out] = await r.run({ action: 'site-down', headers: h('oscar') });
  assert.equal(code, 202);
  assert.equal(out.by, 'oscar');
  assert.deepEqual(calls[0].args, ['--no-print-directory', 'site-down', 'SITE=ams']);
  assert.equal(calls[0].env.VBAL_OPERATOR, 'oscar');
  await new Promise((res) => setTimeout(res, 10));
  assert.equal(r.status().exit_code, 0);
});

test('a make that cannot start is a failed run, not a crashed runner; the next press is accepted', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'vbal-runner-'));
  let n = 0;
  const r = createRunner({ root: dir, secret: 's3cret', verify, sites: SITES, drillDir: join(dir, 'drill'), logDir: join(dir, 'logs'), spawnImpl: () => {
    n += 1;
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    setImmediate(() => {
      child.emit('error', Object.assign(new Error('spawn make ENOENT'), { code: 'ENOENT' }));
      child.emit('close', -2);
    });
    return child;
  } });
  assert.equal((await r.run({ action: 'site-down', headers: h('oscar') }))[0], 202);
  await new Promise((res) => setTimeout(res, 10));
  assert.equal(r.status().exit_code, 127);
  assert.equal(r.status().running, false);
  assert.match(r.status().tail.join('\n'), /make did not start \(spawn make ENOENT\)/);
  assert.equal((await r.run({ action: 'site-down', headers: h('oscar') }))[0], 202);
  assert.equal(n, 2);
});

test('a log file that cannot be written does not stop the step or the runner', async () => {
  // A read-only log folder: the stream fails like on a full disk (an error event).
  const dir = mkdtempSync(join(tmpdir(), 'vbal-runner-'));
  const logDir = join(dir, 'logs');
  mkdirSync(logDir);
  chmodSync(logDir, 0o500);
  const calls = [];
  const r = createRunner({ root: dir, secret: 's3cret', verify, sites: SITES, spawnImpl: fakeSpawn(calls), drillDir: join(dir, 'drill'), logDir });
  assert.equal((await r.run({ action: 'site-down', headers: h('oscar') }))[0], 202);
  await new Promise((res) => setTimeout(res, 20));
  chmodSync(logDir, 0o700);
  assert.equal(r.status().exit_code, 0);
  assert.match(r.status().tail.join('\n'), /log file failed/);
  assert.match(r.status().tail.join('\n'), /PLAY RECAP ok/);
});

test('refusals: no secret, a forged token, a viewer, a step out of order, a second run while busy', async () => {
  const { r } = setup();
  assert.equal((await r.run({ action: 'site-down', headers: h('oscar', 'wrong') }))[0], 401);
  assert.equal((await r.run({ action: 'site-down', headers: h('forged') }))[0], 401);
  const [code, out] = await r.run({ action: 'site-down', headers: h('vera') });
  assert.equal(code, 403);
  assert.match(out.error, /vera is not an operator/);
  const [c2, o2] = await r.run({ action: 'promote', headers: h('oscar') });
  assert.equal(c2, 409);
  assert.match(o2.error, /not the next step: the drill is at "site-down"/);
  assert.equal((await r.run({ action: 'rm -rf', headers: h('oscar') }))[0], 409);
  // busy: a spawn that never closes
  const calls = [];
  const busy = createRunner({ root: mkdtempSync(join(tmpdir(), 'vbal-runner-')), secret: 's3cret', verify, sites: SITES, spawnImpl: (c, a, o) => {
    calls.push(a);
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    return child;
  } });
  assert.equal((await busy.run({ action: 'site-down', headers: h('oscar') }))[0], 202);
  const [c3, o3] = await busy.run({ action: 'site-down', headers: h('oscar') });
  assert.equal(c3, 409);
  assert.match(o3.error, /busy: site-down \(by oscar\)/);
  assert.equal(calls.length, 1);
});
