import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseLines, openDrill, listDrills, readReport, ID } from '../lib/journal.js';

const L = (o) => JSON.stringify(o);

test('a torn last line is skipped; a torn line in the middle is kept as torn', () => {
  assert.equal(parseLines(`${L({ a: 1 })}\n${L({ b: 2 })}\n{"c":`).length, 2);
  const mid = parseLines(`${L({ a: 1 })}\n{"x\n${L({ b: 2 })}\n`);
  assert.deepEqual(mid[1], { torn: true, line: 2 });
});

test('drill ids cannot leave the drill directory', () => {
  assert.equal(ID.test('drill-20261110-104735'), true);
  for (const bad of ['..', '../x', 'a/b', '', 'x'.repeat(65), '%2e%2e']) assert.equal(ID.test(bad), false, bad);
});

test('open drill, closed drills, reports', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vbal-journal-'));
  mkdirSync(join(dir, 'drill-1'));
  writeFileSync(join(dir, 'drill-1', 'journal.jsonl'), `${L({ ts: '2026-11-10T10:00:00Z', act: 'I', step: 'site-down' })}\n${L({ ts: '2026-11-10T10:00:30Z', act: 'II', step: 'promote' })}\n`);
  writeFileSync(join(dir, 'open'), 'drill-1');
  const d = openDrill(dir);
  assert.equal(d.act, 'II');
  assert.equal(d.elapsed_s, 30);
  assert.equal(d.closed, false);
  writeFileSync(join(dir, 'drill-1', 'report.json'), L({ sentence: 'x' }));
  assert.deepEqual(listDrills(dir).map((x) => [x.id, x.closed]), [['drill-1', true]]);
  assert.equal(readReport(dir, 'drill-1').sentence, 'x');
  assert.equal(readReport(dir, '../drill-1'), null);
});
