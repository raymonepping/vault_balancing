#!/usr/bin/env node
// scripts/report.js <drill dir>: the epilogue. Reads <dir>/journal.jsonl (and
// <dir>/audit.json, written by report.sh) and writes report.json and
// report.md: RTO split into detection, decision, promotion and first write;
// RPO as lost writes and seconds; the failback's zero-loss check; every step
// with Vault's answer. Standard library only. Times are UTC.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const ms = (iso) => (iso ? Date.parse(iso) : null);
const secs = (a, b) => (a !== null && b !== null ? Math.round((b - a) / 100) / 10 : null);
const hms = (iso) => (iso ? iso.slice(11, 19) : '-');

export function parseLines(text) {
  return text
    .split('\n')
    .filter((l) => l.trim())
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

// The last journal line of a step (a re-run of a step counts once, its last time).
const last = (lines, step) => [...lines].reverse().find((l) => l.step === step) ?? null;

export function compute(lines, { tickMs = 250, siteNames = {} } = {}) {
  const down = last(lines, 'site-down');
  const detected = last(lines, 'front door marked it down');
  const decided = last(lines, 'promote');
  const first = last(lines, 'first write');
  const rpo = last(lines, 'rpo');
  const zero = last(lines, 'zero lost');
  const t0 = ms(down?.ts);
  const tFirst = ms(first?.first_ok_sent_at ?? first?.ts);
  // RTO as clients saw it: the first failed write to the first acknowledged
  // one after it (the kill itself takes seconds, writes succeed meanwhile).
  const tError = ms(first?.first_error_at) ?? t0;
  const rto = {
    total_s: secs(tError, tFirst),
    detection_s: secs(t0, ms(detected?.ts)),
    decision_s: secs(ms(detected?.ts), ms(decided?.ts)),
    // The promote call until the first acknowledged write: the routed line is
    // only as precise as the playbook's 1 s poll, so it is not a boundary.
    promotion_s: secs(ms(decided?.ts), tFirst),
  };
  const lost = rpo ? Number(rpo.lost) : null;
  const result = {
    drill: lines[0]?.drill ?? null,
    site_down: down ? { site: down.target, name: siteNames[down.target] ?? down.target, at: down.ts } : null,
    promoted: decided ? { site: decided.target, name: siteNames[decided.target] ?? decided.target } : null,
    first_write_at: first?.first_ok_sent_at ?? null,
    first_error_at: first?.first_error_at ?? null,
    rto,
    rpo: rpo ? { lost_writes: lost, checked: Number(rpo.checked), lost_seconds: lost * (tickMs / 1000) } : null,
    failback: zero ? { lost_writes: Number(zero.lost), checked: Number(zero.checked) } : null,
    refusals: lines.filter((l) => /refused/.test(l.step)).map((l) => ({ at: l.ts, step: l.step, target: l.target, said: l.vault_said })),
    steps: lines.map((l) => ({ at: l.ts, act: l.act, step: l.step, target: l.target, http: l.http_code ?? null, said: l.vault_said })),
  };
  result.sentence = sentence(result);
  return result;
}

export function sentence(r) {
  if (!r.site_down || !r.first_write_at) return 'The drill has no outage and recovery to report yet.';
  const lostS = r.rpo ? `${r.rpo.lost_seconds.toFixed(r.rpo.lost_seconds % 1 ? 2 : 0)} s of writes (${r.rpo.lost_writes} of ${r.rpo.checked})` : 'an unmeasured amount of writes';
  return `${r.site_down.name} died at ${hms(r.first_error_at ?? r.site_down.at)}. Clients wrote again at ${hms(r.first_write_at)}, ${r.rto.total_s} s later. We lost ${lostS}. Nobody guessed.`;
}

export function markdown(r, audit = []) {
  const row = (...c) => `| ${c.map((x) => String(x ?? '-').replace(/\|/g, '/')).join(' | ')} |`;
  const out = [
    `# Drill report: ${r.drill ?? 'unknown'}`,
    '',
    `> ${r.sentence}`,
    '',
    '## RTO',
    '',
    row('Part', 'Seconds', 'From the journal'),
    row('---', '---', '---'),
    row('Detection', r.rto.detection_s, 'site killed, until the front door marked every node down'),
    row('Decision', r.rto.decision_s, 'until the operator ran promote (scripted in this drill: near zero)'),
    row('Promotion and first write', r.rto.promotion_s, "the promote call, until the ticker's first acknowledged write on the promoted site"),
    row('**Total (clients)**', r.rto.total_s, "the first failed write, until the first acknowledged write after it"),
    '',
    '## RPO',
    '',
    r.rpo
      ? `${r.rpo.lost_writes} of ${r.rpo.checked} writes acknowledged in the minute before the outage are missing on the promoted site: ${r.rpo.lost_seconds} s of writes.`
      : 'Not measured in this drill.',
    '',
    r.failback ? `Failback: ${r.failback.lost_writes} of ${r.failback.checked} writes acknowledged during the planned failback are missing.` : '',
    '',
    '## Steps (Vault said)',
    '',
    row('UTC', 'Act', 'Step', 'Target', 'HTTP', 'Vault said'),
    row('---', '---', '---', '---', '---', '---'),
    ...r.steps.map((s) => row(s.at?.slice(11, 23), s.act, s.step, s.target, s.http, s.said)),
  ];
  if (audit.length) {
    out.push('', "## Vault's own audit record", '', row('Node', 'Path', 'Time (audit log)'), row('---', '---', '---'));
    for (const a of audit) out.push(row(a.node, a.path, a.time));
  }
  return `${out.join('\n')}\n`;
}

function main(dir) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  const sites = JSON.parse(readFileSync(join(root, 'config/sites.json'), 'utf8')).sites;
  const names = Object.fromEntries(sites.map((s) => [s.id, s.name]));
  const lines = parseLines(readFileSync(join(dir, 'journal.jsonl'), 'utf8'));
  const audit = existsSync(join(dir, 'audit.json')) ? JSON.parse(readFileSync(join(dir, 'audit.json'), 'utf8')) : [];
  const tickMs = Number(process.env.VBAL_TICK_MS || 250);
  const r = compute(lines, { tickMs, siteNames: names });
  r.audit = audit;
  writeFileSync(join(dir, 'report.json'), `${JSON.stringify(r, null, 2)}\n`);
  writeFileSync(join(dir, 'report.md'), markdown(r, audit));
  console.log(r.sentence);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) {
    console.error('Usage: report.js <drill dir>');
    process.exit(64);
  }
  main(process.argv[2]);
}
