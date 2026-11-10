import { test } from 'node:test';
import assert from 'node:assert/strict';
import { steps, nextStep, view } from '../lib/actions.js';

const SITES = [
  { id: 'ams', name: 'Amsterdam', role: 'primary' },
  { id: 'fra', name: 'Frankfurt', role: 'performance' },
  { id: 'dub', name: 'Dublin', role: 'dr' },
];
const line = (act, step) => ({ act, step });

test('the sequence is the drill, with the make target of each step', () => {
  assert.deepEqual(steps(SITES).map((s) => s.id), ['site-down', 'promote', 'repoint', 'fence', 'site-up', 'demote', 'unfence', 'failback', 'report']);
  assert.deepEqual(steps(SITES)[2].make, ['repoint', 'SITE=fra', 'TO=dub']);
  assert.equal(steps(SITES)[0].confirm, 'ams');
});

test('the next step follows the journal, never repeats a done step', () => {
  assert.equal(nextStep(SITES, null).id, 'site-down');
  assert.equal(nextStep(SITES, { lines: [line('I', 'site-down')] }).id, 'site-down'); // not done until detected
  assert.equal(nextStep(SITES, { lines: [line('I', 'front door marked it down')] }).id, 'promote');
  const toIV = [line('I', 'front door marked it down'), line('II', 'dr token'), line('III', 'lag normal')];
  assert.equal(nextStep(SITES, { lines: toIV }).id, 'fence');
  // A "lag normal" from Act V does not count for Act III.
  assert.equal(nextStep(SITES, { lines: [line('I', 'front door marked it down'), line('II', 'dr token'), line('V', 'lag normal')] }).id, 'repoint');
  const all = [...toIV, line('IV', 'fenced'), line('IV', 'site-up'), line('IV', 'streams as DR secondary'), line('IV', 'unfenced'), line('V', 'zero lost')];
  assert.equal(nextStep(SITES, { lines: all }).id, 'report');
});

test('who may press it, and why not', () => {
  const s = steps(SITES)[1];
  assert.equal(view(s, { role: 'operator' }).enabled, true);
  assert.equal(view(s, { role: 'admin' }).enabled, true);
  assert.match(view(s, { role: 'viewer' }).reason, /viewer/);
  assert.equal(view(s, { role: 'viewer' }).enabled, false);
  assert.match(view(s, { role: null }).reason, /Sign in/);
  assert.match(view(s, { role: 'operator', running: { action: 'promote' } }).reason, /Running: promote/);
  assert.equal(view(s, { role: 'operator' }).command, 'make promote SITE=dub');
});
