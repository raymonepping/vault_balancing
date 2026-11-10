// app/ticker/ticker.js: the drill's measuring instrument (D10). Node 24, no
// dependencies.
//
// Every TICK_MS it writes {seq, written_at} to the ring slot
// payments/kv/data/ticker/<seq mod 7200> THROUGH THE FRONT DOOR (writes), and
// journals each attempt (one JSON line: seq, sent_at, status, http_code,
// latency_ms). Every second it reads slots behind the newest acknowledged seq
// at Frankfurt (the front door's regional port) to measure replication lag in
// seqs. GET /metrics (internal network only) serves the last 60 seconds.
//
// The token is the Vault Agent's sink file, re-read on every request (the
// agent replaces it). It is a batch token: valid on the performance secondary
// and on a promoted DR secondary (probe P18). Never logged.
import { readFileSync, writeFileSync, appendFileSync, renameSync, existsSync, mkdirSync } from 'node:fs';
import { createServer } from 'node:http';
import { slotOf, Window, LAG_OFFSETS, lagFrom, shouldRotate, parseJournal, firstOkAfter, ackedBetween, classify, gapAfter } from './lib.js';

const env = (k, d) => process.env[k] ?? d;
const WRITES = env('TICKER_WRITES_ADDR', 'https://frontdoor:8443');
const READS = env('TICKER_READS_ADDR', 'https://frontdoor:8444');
const TOKEN_FILE = env('TICKER_TOKEN_FILE', '/sink/token');
const DATA = env('TICKER_DATA_DIR', '/data');
const TICK_MS = Number(env('TICKER_TICK_MS', '250'));
const TIMEOUT_MS = Number(env('TICKER_TIMEOUT_MS', '2000'));
const PORT = Number(env('TICKER_METRICS_PORT', '9100'));
const NS = 'payments';

mkdirSync(DATA, { recursive: true });
const SEQ_FILE = `${DATA}/seq`;
const JOURNAL = `${DATA}/current.jsonl`;
const PREVIOUS = `${DATA}/previous.jsonl`;

// The counter survives a restart, so a ring slot never goes backwards.
let seq = existsSync(SEQ_FILE) ? Number(readFileSync(SEQ_FILE, 'utf8')) || 0 : 0;
let openedAt = Date.now();
let lastAck = { seq: 0, at: null };
let regional = { lag: null, ok: false, at: null, error: null };
let inFlight = 0;
const window = new Window();
const startedAt = new Date().toISOString();

const token = () => {
  try {
    return readFileSync(TOKEN_FILE, 'utf8').trim();
  } catch {
    return '';
  }
};

// fetch with a hard deadline: an AbortController plus a REFERENCED setTimeout
// (AbortSignal.timeout can silently never fire, vault_codex lesson).
async function vault(base, method, path, body) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), TIMEOUT_MS);
  const t0 = performance.now();
  try {
    const res = await fetch(`${base}/v1/${path}`, {
      method,
      signal: ac.signal,
      headers: { 'X-Vault-Token': token(), 'X-Vault-Namespace': NS, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    return { code: res.status, text, latency: performance.now() - t0 };
  } catch (e) {
    return { code: 0, text: '', latency: performance.now() - t0, error: e.name === 'AbortError' ? 'timeout' : e.cause?.code || e.message };
  } finally {
    clearTimeout(timer);
  }
}

function journal(line) {
  const now = Date.now();
  if (shouldRotate(openedAt, now)) {
    try {
      renameSync(JOURNAL, PREVIOUS);
    } catch {
      /* first rotation: no file yet */
    }
    openedAt = now;
  }
  appendFileSync(JOURNAL, `${JSON.stringify(line)}\n`);
}

async function tick() {
  if (inFlight >= 8) return; // a stalled front door must not pile up requests
  inFlight++;
  const mySeq = ++seq;
  writeFileSync(SEQ_FILE, String(seq));
  const sentAt = Date.now();
  const r = await vault(WRITES, 'POST', `kv/data/ticker/${slotOf(mySeq)}`, {
    data: { seq: mySeq, written_at: new Date(sentAt).toISOString() },
  });
  inFlight--;
  const ok = r.code === 200 || r.code === 204;
  if (ok && mySeq > lastAck.seq) lastAck = { seq: mySeq, at: new Date().toISOString() };
  window.push({ t: sentAt, ok, latency: r.latency });
  let error = r.error;
  if (!ok && !error) {
    try {
      error = JSON.parse(r.text).errors?.[0];
    } catch {
      error = r.text.slice(0, 160);
    }
  }
  journal({
    seq: mySeq,
    slot: slotOf(mySeq),
    sent_at: new Date(sentAt).toISOString(),
    status: ok ? 'ok' : 'error',
    http_code: r.code,
    latency_ms: Math.round(r.latency),
    ...(ok ? {} : { error }),
  });
}

async function readRegional() {
  const last = lastAck.seq;
  if (last < 1) return;
  const found = new Map();
  let firstError = null;
  await Promise.all(
    LAG_OFFSETS.filter((off) => last - off >= 1).map(async (off) => {
      const r = await vault(READS, 'GET', `kv/data/ticker/${slotOf(last - off)}`);
      if (r.code === 200) {
        try {
          found.set(off, JSON.parse(r.text).data.data.seq);
        } catch {
          /* unreadable slot: treated as missing */
        }
      } else if (firstError === null) firstError = r.error || `HTTP ${r.code}`;
    }),
  );
  regional = { lag: lagFrom(last, found), ok: found.size > 0, at: new Date().toISOString(), error: found.size ? null : firstError };
}

const readJournal = () =>
  parseJournal([PREVIOUS, JOURNAL].filter((f) => existsSync(f)).map((f) => readFileSync(f, 'utf8')).join('\n'));
const json = (res, code, body) => res.writeHead(code, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
const msParam = (url, k) => {
  const v = url.searchParams.get(k);
  const ms = v === null ? NaN : Date.parse(v);
  return Number.isFinite(ms) ? ms : null;
};

// GET /verify?to=<iso>&seconds=<n> (or from=<iso>): re-read the ring slot of every acknowledged
// write sent in that window, through the front door (the current primary),
// with the ticker's own token: the RPO. At most 2400 writes (10 minutes).
async function verify(fromMs, toMs) {
  const acked = ackedBetween(readJournal(), fromMs, toMs).slice(-2400);
  const result = { checked: acked.length, present: 0, lost: [], overwritten: 0, unreadable: 0 };
  for (let i = 0; i < acked.length; i += 16) {
    await Promise.all(
      acked.slice(i, i + 16).map(async (l) => {
        const r = await vault(WRITES, 'GET', `kv/data/ticker/${slotOf(l.seq)}`);
        let slotSeq = null;
        if (r.code === 200) slotSeq = JSON.parse(r.text).data.data.seq;
        else if (r.code !== 404) {
          result.unreadable++;
          return;
        }
        const c = classify(l.seq, slotSeq);
        if (c === 'present') result.present++;
        else if (c === 'lost') result.lost.push({ seq: l.seq, sent_at: l.sent_at });
        else result.overwritten++;
      }),
    );
  }
  result.lost.sort((a, b) => a.seq - b.seq);
  return result;
}

createServer(async (req, res) => {
  if (req.method !== 'GET') {
    res.writeHead(405, { Allow: 'GET' }).end();
    return;
  }
  const url = new URL(req.url, 'http://ticker');
  if (url.pathname === '/first-ok') {
    const after = msParam(url, 'after');
    if (after === null) return json(res, 400, { error: 'after=<ISO time> is required' });
    return json(res, 200, { first_ok: firstOkAfter(readJournal(), after) });
  }
  if (url.pathname === '/gap') {
    const after = msParam(url, 'after');
    if (after === null) return json(res, 400, { error: 'after=<ISO time> is required' });
    return json(res, 200, gapAfter(readJournal(), after));
  }
  if (url.pathname === '/verify') {
    const to = msParam(url, 'to');
    const seconds = Number(url.searchParams.get('seconds'));
    const from = url.searchParams.has('seconds') && to !== null && seconds > 0 && seconds <= 600 ? to - seconds * 1000 : msParam(url, 'from');
    if (from === null || to === null || to < from) return json(res, 400, { error: 'from and to (ISO times, from <= to) are required' });
    return json(res, 200, await verify(from, to));
  }
  if (req.url === '/metrics' || req.url === '/healthz') {
    const body = {
      started_at: startedAt,
      tick_ms: TICK_MS,
      last_ack_seq: lastAck.seq,
      last_ack_at: lastAck.at,
      next_seq: seq + 1,
      regional_lag: regional.lag,
      regional_read_ok: regional.ok,
      regional_at: regional.at,
      regional_error: regional.error,
      ...window.stats(Date.now()),
    };
    if (req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ ok: true, last_ack_seq: lastAck.seq }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
    return;
  }
  res.writeHead(404).end();
}).listen(PORT, '0.0.0.0');

const writer = setInterval(tick, TICK_MS);
const reader = setInterval(readRegional, 1000);
const stop = () => {
  clearInterval(writer);
  clearInterval(reader);
  setTimeout(() => process.exit(0), TIMEOUT_MS + 100);
};
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
console.log(`ticker: writing every ${TICK_MS} ms to ${WRITES}, reading at ${READS}, from seq ${seq + 1}`);
