// lib/journal.js: the drill journals under the read-only mount of .build/drill.
// A torn LAST line (the drill is writing it) is skipped; any other bad line is
// an error worth seeing, so it is kept as {torn: true}.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';

export const ID = /^[A-Za-z0-9_-]{1,64}$/;

export function parseLines(text) {
  const raw = text.split('\n');
  const out = [];
  raw.forEach((l, i) => {
    if (!l.trim()) return;
    try {
      out.push(JSON.parse(l));
    } catch {
      if (i < raw.length - 1 && raw.slice(i + 1).some((x) => x.trim())) out.push({ torn: true, line: i + 1 });
    }
  });
  return out;
}

export function openDrill(dir) {
  const f = join(dir, 'open');
  if (!existsSync(f)) return null;
  const id = readFileSync(f, 'utf8').trim();
  if (!ID.test(id)) return null;
  return readDrill(dir, id);
}

export function readDrill(dir, id) {
  if (!ID.test(id)) return null;
  const f = join(dir, id, 'journal.jsonl');
  if (!existsSync(f)) return null;
  const lines = parseLines(readFileSync(f, 'utf8'));
  const first = lines.find((l) => l.ts);
  const last = [...lines].reverse().find((l) => l.ts);
  return {
    id,
    act: last?.act ?? null,
    step: last?.step ?? null,
    started_at: first?.ts ?? null,
    elapsed_s: first && last ? Math.round((Date.parse(last.ts) - Date.parse(first.ts)) / 1000) : 0,
    closed: existsSync(join(dir, id, 'report.json')),
    lines,
  };
}

export function listDrills(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((d) => ID.test(d) && d.startsWith('drill-') && statSync(join(dir, d)).isDirectory())
    .sort()
    .reverse()
    .map((id) => {
      const d = readDrill(dir, id);
      return d ? { id, act: d.act, started_at: d.started_at, closed: d.closed } : null;
    })
    .filter(Boolean);
}

export function readReport(dir, id) {
  if (!ID.test(id)) return null;
  const f = join(dir, id, 'report.json');
  return existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : null;
}
