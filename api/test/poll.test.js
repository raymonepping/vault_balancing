import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPoller, STALE_MS } from '../lib/poll.js';

test('up, down (keeping the last data), up again; stale after 3 s; one log line per change', async () => {
  let t = 1_000_000;
  let fail = false;
  const logs = [];
  const p = createPoller('x', async () => {
    if (fail) throw new Error('refused');
    return { v: t };
  }, { now: () => t, log: (o) => logs.push(o) });
  assert.equal(p.envelope().state, 'unknown');
  await p.tick();
  assert.equal(p.envelope().state, 'up');
  fail = true;
  t += 1000;
  await p.tick();
  await p.tick();
  const e = p.envelope();
  assert.equal(e.state, 'down');
  assert.equal(e.data.v, 1_000_000); // last good value kept
  assert.equal(e.error, 'refused');
  t += STALE_MS;
  assert.equal(p.envelope().stale, true);
  fail = false;
  await p.tick();
  assert.equal(p.envelope().stale, false);
  assert.deepEqual(logs.map((l) => l.state), ['up', 'down', 'up']);
});

test('a tick while the previous poll runs is skipped and counted', async () => {
  let release;
  const p = createPoller('slow', () => new Promise((r) => (release = r)));
  const first = p.tick();
  await p.tick();
  await p.tick();
  assert.equal(p.health().skipped, 2);
  release({ ok: true });
  await first;
  assert.equal(p.envelope().state, 'up');
});
