// lib/poll.js: the one poll loop every source uses. A tick that starts while
// the previous poll still runs is skipped (and counted): a slow source never
// piles up requests. Each poll result replaces the whole snapshot. States:
// unknown (never read), up, down; "stale" is computed at read time (older
// than 3 s). On failure the last good data is kept, with its age.
export const STALE_MS = 3000;

export function createPoller(name, fn, { everyMs = 1000, now = () => Date.now(), onChange = () => {}, log = () => {} } = {}) {
  let snap = { state: 'unknown', read_at: null, data: null, error: null };
  let running = false;
  let skipped = 0;
  let lastPollMs = null;
  let timer = null;

  async function tick() {
    if (running) {
      skipped++;
      return;
    }
    running = true;
    const t0 = now();
    const before = snap;
    try {
      const data = await fn();
      snap = { state: 'up', read_at: new Date(now()).toISOString(), data, error: null };
    } catch (e) {
      snap = { ...before, state: 'down', error: e.message };
    }
    lastPollMs = now() - t0;
    running = false;
    if (snap.state !== before.state) {
      log({ source: name, state: snap.state, was: before.state, error: snap.error });
    }
    onChange(name, snap, before);
  }

  return {
    name,
    tick,
    start() {
      tick();
      timer = setInterval(tick, everyMs);
      return this;
    },
    stop() {
      clearInterval(timer);
    },
    envelope(at = now()) {
      const age = snap.read_at ? at - Date.parse(snap.read_at) : null;
      return {
        state: snap.state,
        read_at: snap.read_at,
        age_ms: age,
        stale: age === null || age > STALE_MS,
        error: snap.error,
        data: snap.data,
      };
    },
    health(at = now()) {
      const e = this.envelope(at);
      return { state: e.state, age_ms: e.age_ms, stale: e.stale, last_poll_ms: lastPollMs, skipped };
    },
  };
}
