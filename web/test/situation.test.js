import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initial, reduce, roleView, clock, fencedSites } from '../src/situation.js';

test('a snapshot replaces everything; a journal line is added once', () => {
  let s = reduce(initial, { type: 'snapshot', data: { sites: [{ site: 'ams' }], split_brain: false, frontdoor: { state: 'up' }, ticker: null, drill: { open: { id: 'd1', lines: [] } } } });
  assert.equal(s.connected, true);
  assert.equal(s.drill.id, 'd1');
  const line = { ts: '2026-11-10T10:00:00Z', drill: 'd1', act: 'I', step: 'site-down' };
  s = reduce(s, { type: 'journal', data: line });
  s = reduce(s, { type: 'journal', data: line });
  assert.equal(s.drill.lines.length, 1);
  assert.equal(s.drill.act, 'I');
  assert.equal(reduce(s, { type: 'error' }).connected, false);
});

test('the words the room reads', () => {
  assert.equal(roleView({ site: 'ams', state: 'down' }).word, 'Amsterdam is down');
  assert.equal(roleView({ site: 'ams', state: 'up', data: { role: 'primary' } }).pill, 'approved');
  assert.deepEqual(roleView({ site: 'ams', state: 'up', data: { role: 'primary' } }, true), { word: 'Primary: takes the writes, fenced', pill: 'pending' });
  assert.equal(roleView(undefined).word, 'Unknown');
});

test('the drill clock runs from the first failed write until the first acknowledged one', () => {
  const lines = [
    { ts: '2026-11-10T10:00:00.000Z', step: 'site-down' },
    { ts: '2026-11-10T10:00:12.000Z', step: 'first write', first_error_at: '2026-11-10T10:00:01.000Z', first_ok_sent_at: '2026-11-10T10:00:11.500Z' },
  ];
  assert.deepEqual(clock({ lines }, Date.parse('2026-11-10T10:01:00Z')), { running: false, rto_s: 10.5, since_s: 60 });
  assert.equal(clock({ lines: lines.slice(0, 1) }, Date.parse('2026-11-10T10:00:05Z')).running, true);
  assert.equal(clock(null).rto_s, null);
});

test('a site is fenced when every one of its servers is in MAINT', () => {
  const fd = { data: { backends: [{ servers: [{ name: 'vault-ams-1', state: 'MAINT' }, { name: 'vault-ams-2', state: 'MAINT' }, { name: 'vault-dub-1', state: 'UP' }] }] } };
  assert.deepEqual([...fencedSites(fd)], ['ams']);
});
