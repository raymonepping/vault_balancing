import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compute, markdown, parseLines } from './report.js';

// A synthetic drill: Amsterdam killed at :00, detected at :02, promote at
// :02.5, routed at :04, first write sent at :04.25; 2 of 240 lost.
const J = [
  { ts: '2026-11-10T14:02:00.000Z', drill: 'drill-x', act: 'I', step: 'site-down', target: 'ams', vault_said: 'ams was primary' },
  { ts: '2026-11-10T14:02:02.000Z', drill: 'drill-x', act: 'I', step: 'front door marked it down', target: 'ams' },
  { ts: '2026-11-10T14:02:02.500Z', drill: 'drill-x', act: 'II', step: 'promote', target: 'dub' },
  { ts: '2026-11-10T14:02:04.000Z', drill: 'drill-x', act: 'II', step: 'front door routes to it', target: 'dub', http_code: 200 },
  { ts: '2026-11-10T14:02:05.000Z', drill: 'drill-x', act: 'II', step: 'first write', target: 'dub', first_error_at: '2026-11-10T14:02:00.250Z', first_ok_sent_at: '2026-11-10T14:02:04.250Z' },
  { ts: '2026-11-10T14:02:06.000Z', drill: 'drill-x', act: 'II', step: 'rpo', target: 'dub', lost: '2', checked: '240' },
  { ts: '2026-11-10T14:05:00.000Z', drill: 'drill-x', act: 'IV', step: 'site-up refused', target: 'ams', vault_said: 'not fenced' },
  { ts: '2026-11-10T14:09:00.000Z', drill: 'drill-x', act: 'V', step: 'zero lost', target: 'ams', lost: '0', checked: '300' },
];

test('RTO: the total as clients saw it, and its three parts from the journal', () => {
  const r = compute(J, { siteNames: { ams: 'Amsterdam', dub: 'Dublin' } });
  // detection from the first failed write (:00.25), not the kill (:00)
  assert.deepEqual(r.rto, { total_s: 4, detection_s: 1.8, decision_s: 0.5, promotion_s: 1.8 });
  // the parts add up to the total, within each part's 0.1 s rounding
  const sum = r.rto.detection_s + r.rto.decision_s + r.rto.promotion_s;
  assert.ok(Math.abs(sum - r.rto.total_s) <= 0.15, `parts ${sum} vs total ${r.rto.total_s}`);
  assert.equal(r.site_down.name, 'Amsterdam');
  assert.equal(r.promoted.site, 'dub');
});

test('RPO in writes and seconds; failback; refusals', () => {
  const r = compute(J, { tickMs: 250 });
  assert.deepEqual(r.rpo, { lost_writes: 2, checked: 240, lost_seconds: 0.5 });
  assert.deepEqual(r.failback, { lost_writes: 0, checked: 300 });
  assert.equal(r.refusals.length, 1);
});

test('the sentence for the room comes from measured numbers only', () => {
  const r = compute(J, { siteNames: { ams: 'Amsterdam' } });
  assert.equal(r.sentence, 'Amsterdam died at 14:02:00. Clients wrote again at 14:02:04, 4 s later. We lost 0.50 s of writes (2 of 240). Nobody guessed.');
  assert.equal(compute([]).sentence, 'The drill has no outage and recovery to report yet.');
});

test('a re-run step counts its last time; torn lines are skipped; markdown escapes pipes', () => {
  const twice = [...J.slice(0, 1), { ...J[0], ts: '2026-11-10T14:01:00.000Z' }];
  assert.equal(compute(twice).site_down.at, '2026-11-10T14:01:00.000Z');
  assert.equal(parseLines(`${JSON.stringify(J[0])}\n{"torn`).length, 1);
  assert.match(markdown(compute([{ ...J[0], vault_said: 'a|b' }])), /a\/b/);
});
