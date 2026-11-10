import { test } from 'node:test';
import assert from 'node:assert/strict';
import { slotOf, percentile, Window, lagFrom, shouldRotate, RING } from '../lib.js';

test('the ring wraps at 7200 and never collides within 30 minutes', () => {
  assert.equal(RING, 7200);
  assert.equal(slotOf(1), 1);
  assert.equal(slotOf(7200), 0);
  assert.equal(slotOf(7201), 1);
});

test('nearest-rank percentiles', () => {
  assert.equal(percentile([], 50), null);
  assert.equal(percentile([5], 99), 5);
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50), 5);
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 100], 99), 100);
});

test('window counts the last 10 seconds and keeps 60 one-second buckets', () => {
  const w = new Window();
  const now = 1_000_000;
  w.push({ t: now - 70_000, ok: true, latency: 1 }); // older than the window: pruned (pushes are chronological)
  for (let i = 0; i < 40; i++) w.push({ t: now - 9_900 + i * 250, ok: i % 10 !== 0, latency: 5 + i });
  const s = w.stats(now);
  assert.equal(s.attempts_10s, 40);
  assert.equal(s.fail_10s, 4);
  assert.equal(s.acked_10s, 36);
  assert.equal(s.spark.length, 60);
  assert.equal(s.spark.reduce((n, b) => n + b.ack + b.fail, 0), 40);
  assert.equal(w.items.length, 40);
});

test('regional lag is the smallest offset whose slot holds the expected seq', () => {
  assert.equal(lagFrom(100, new Map([[0, 100]])), 0);
  assert.equal(lagFrom(100, new Map([[0, 92], [1, 92], [2, 92], [4, 92], [8, 92]])), 8);
  assert.equal(lagFrom(100, new Map()), null);
  assert.equal(lagFrom(1, new Map([[0, 1]])), 0);
  assert.equal(lagFrom(3, new Map([[0, -1], [1, -1], [2, 1]])), 2);
});

test('journal rotates after an hour', () => {
  assert.equal(shouldRotate(0, 3_599_999), false);
  assert.equal(shouldRotate(0, 3_600_000), true);
});

import { parseJournal, firstOkAfter, ackedBetween, classify } from '../lib.js';

const J = [
  { seq: 1, sent_at: '2026-11-10T10:00:00.000Z', status: 'ok' },
  { seq: 2, sent_at: '2026-11-10T10:00:00.250Z', status: 'error' },
  { seq: 3, sent_at: '2026-11-10T10:00:00.500Z', status: 'error' },
  { seq: 4, sent_at: '2026-11-10T10:00:00.750Z', status: 'ok' },
]
  .map((l) => JSON.stringify(l))
  .join('\n');

test('a torn last journal line is skipped', () => {
  assert.equal(parseJournal(`${J}\n{"seq": 5, "sent`).length, 4);
});

test('the first acknowledged write after the outage', () => {
  const lines = parseJournal(J);
  assert.equal(firstOkAfter(lines, Date.parse('2026-11-10T10:00:00.100Z')).seq, 4);
  assert.equal(firstOkAfter(lines, Date.parse('2026-11-10T10:00:01Z')), null);
});

test('acknowledged writes in a window, and how each is classified', () => {
  const lines = parseJournal(J);
  assert.deepEqual(ackedBetween(lines, Date.parse('2026-11-10T10:00:00Z'), Date.parse('2026-11-10T10:00:00.800Z')).map((l) => l.seq), [1, 4]);
  assert.equal(classify(10, 10), 'present');
  assert.equal(classify(10, 9), 'lost');
  assert.equal(classify(10, undefined), 'lost');
  assert.equal(classify(10, 7210), 'overwritten');
});

import { gapAfter } from '../lib.js';

test('the outage as clients saw it', () => {
  const lines = parseJournal(J); // ok 1, error 2, error 3, ok 4
  const g = gapAfter(lines, Date.parse('2026-11-10T10:00:00Z'));
  assert.equal(g.last_ok_before.seq, 1);
  assert.equal(g.first_error.seq, 2);
  assert.equal(g.first_ok_after.seq, 4);
  assert.equal(gapAfter(lines, Date.parse('2026-11-10T10:00:00.600Z')).first_error, null);
  assert.equal(gapAfter(parseJournal(J.split('\n').slice(0, 3).join('\n')), 0).first_ok_after, null);
});
