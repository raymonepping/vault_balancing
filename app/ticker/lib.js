// app/ticker/lib.js: the ticker's pure logic, unit-tested in test/lib.test.js.
// No I/O here: ticker.js does the requests, files and the metrics server.

export const RING = 7200; // 30 minutes of slots at 4 writes a second (D10)

// The ring slot of a sequence number. Bounded storage: a slot holds the newest
// seq written to it, so a write is lost when its slot holds an older seq.
export const slotOf = (seq, ring = RING) => seq % ring;

// Nearest-rank percentile of a list of numbers; null for an empty list.
export function percentile(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length, Math.max(1, rank)) - 1];
}

// The last 60 seconds of write attempts, for /metrics.
export class Window {
  constructor(seconds = 60) {
    this.seconds = seconds;
    this.items = []; // {t (ms), ok, latency}
  }

  push(item) {
    this.items.push(item);
  }

  prune(now) {
    const from = now - this.seconds * 1000;
    while (this.items.length && this.items[0].t < from) this.items.shift();
  }

  stats(now) {
    this.prune(now);
    const last10 = this.items.filter((i) => i.t >= now - 10_000);
    const okLat = last10.filter((i) => i.ok).map((i) => i.latency);
    const spark = [];
    for (let s = this.seconds - 1; s >= 0; s--) {
      const from = now - (s + 1) * 1000;
      const to = now - s * 1000;
      const inSec = this.items.filter((i) => i.t >= from && i.t < to);
      const ok = inSec.filter((i) => i.ok);
      spark.push({
        t: Math.floor(to / 1000),
        ack: ok.length,
        fail: inSec.length - ok.length,
        p99_ms: percentile(ok.map((i) => i.latency), 99),
      });
    }
    return {
      attempts_10s: last10.length,
      acked_10s: okLat.length,
      fail_10s: last10.length - okLat.length,
      p50_ms: percentile(okLat, 50),
      p99_ms: percentile(okLat, 99),
      spark,
    };
  }
}

// Offsets (in seqs) the regional reader probes behind the newest acknowledged
// seq: 0 means Frankfurt already holds the newest write.
export const LAG_OFFSETS = [0, 1, 2, 4, 8, 16, 32];

// found: Map offset -> seq read from that slot at Frankfurt (or undefined).
// Returns the smallest offset whose slot holds exactly last - offset, or null
// when none does (more than 32 behind, or unreadable).
export function lagFrom(last, found) {
  for (const off of LAG_OFFSETS) {
    if (last - off < 1) break;
    if (found.get(off) === last - off) return off;
  }
  return null;
}

// Rotate the rolling journal once it is older than an hour (D10).
export const shouldRotate = (openedAt, now, maxMs = 3_600_000) => now - openedAt >= maxMs;

// Journal lines (JSON per line) -> objects; a torn or empty line is skipped.
export function parseJournal(text) {
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      /* a torn last line while the ticker writes */
    }
  }
  return out;
}

// The first acknowledged write sent at or after `afterMs` (the RTO clock stops).
export function firstOkAfter(lines, afterMs) {
  return lines.find((l) => l.status === 'ok' && Date.parse(l.sent_at) >= afterMs) ?? null;
}

// Acknowledged writes sent in [fromMs, toMs]: what the RPO check re-reads.
export const ackedBetween = (lines, fromMs, toMs) =>
  lines.filter((l) => l.status === 'ok' && Date.parse(l.sent_at) >= fromMs && Date.parse(l.sent_at) <= toMs);

// Classify one acknowledged seq against what its slot holds now: present (the
// same seq), lost (an older seq or nothing: the write never reached the new
// primary), or overwritten (a newer seq: the ring moved on, unknown).
export function classify(seq, slotSeq) {
  if (slotSeq === seq) return 'present';
  if (slotSeq === undefined || slotSeq === null || slotSeq < seq) return 'lost';
  return 'overwritten';
}

// The outage as clients saw it, after `afterMs` (the site-down moment): the
// first failed write, the last acknowledged one before it, and the first
// acknowledged one after it. RTO = first_ok_after - first_error.
export function gapAfter(lines, afterMs) {
  const i = lines.findIndex((l) => l.status !== 'ok' && Date.parse(l.sent_at) >= afterMs);
  if (i < 0) return { last_ok_before: null, first_error: null, first_ok_after: null };
  const before = lines.slice(0, i).reverse().find((l) => l.status === 'ok') ?? null;
  const after = lines.slice(i + 1).find((l) => l.status === 'ok') ?? null;
  return { last_ok_before: before, first_error: lines[i], first_ok_after: after };
}
