// situation.js: the console's state, from the API's server-sent events
// (/api/events). A snapshot on (re)connect replaces everything; live events
// update one part. The reducer is pure (test/situation.test.js).
export const initial = { connected: false, sites: [], split_brain: false, frontdoor: null, ticker: null, drill: null };

export function reduce(state, { type, data }) {
  switch (type) {
    case 'open':
      return { ...state, connected: true };
    case 'error':
      return { ...state, connected: false };
    case 'snapshot':
      return { ...state, connected: true, sites: data.sites, split_brain: data.split_brain, frontdoor: data.frontdoor, ticker: data.ticker, drill: data.drill?.open ?? null };
    case 'site':
      return { ...state, sites: data.sites, split_brain: data.split_brain };
    case 'frontdoor':
      return { ...state, frontdoor: data };
    case 'ticker':
      return { ...state, ticker: data };
    case 'drill':
      return { ...state, drill: data.open ? { ...data.open, lines: [] } : null };
    case 'journal': {
      const d = state.drill ?? { id: data.drill, lines: [] };
      if (d.lines.some((l) => l.ts === data.ts && l.step === data.step)) return state;
      return { ...state, drill: { ...d, id: d.id ?? data.drill, act: data.act, step: data.step, lines: [...d.lines, data] } };
    }
    default:
      return state;
  }
}

// West to east, as the room sees the map: Dublin, Amsterdam, Frankfurt.
export const MAP_ORDER = ['dub', 'ams', 'fra'];
export const NAMES = { ams: 'Amsterdam', fra: 'Frankfurt', dub: 'Dublin' };

// One word the room understands, and the pill it wears (AA on its own tint).
export function roleView(site, fenced = false) {
  if (!site || site.state === 'unknown') return { word: 'Unknown', pill: 'manual' };
  if (site.state === 'down') return { word: `${NAMES[site.site] ?? site.site} is down`, pill: 'rejected', down: true };
  const role = site.data?.role;
  const words = {
    primary: ['Primary: takes the writes', 'approved'],
    'performance secondary': ['Performance secondary: serves reads', 'healthy'],
    'DR secondary': ['DR secondary: waits', 'manual'],
    demoted: ['Demoted: waits to be attached', 'pending'],
    standalone: ['Not replicating', 'manual'],
  };
  const [word, pill] = words[role] ?? ['Unknown', 'manual'];
  return { word: fenced ? `${word}, fenced` : word, pill: fenced ? 'pending' : pill };
}

// The drill clock from the journal: when the site died, when clients wrote again.
export function clock(drill, now = Date.now()) {
  const lines = drill?.lines ?? [];
  const down = [...lines].reverse().find((l) => l.step === 'site-down');
  const first = [...lines].reverse().find((l) => l.step === 'first write');
  if (!down) return { running: false, rto_s: null, since_s: null };
  const from = Date.parse(first?.first_error_at ?? down.ts);
  const to = first?.first_ok_sent_at ? Date.parse(first.first_ok_sent_at) : now;
  return { running: !first, rto_s: Math.max(0, Math.round((to - from) / 100) / 10), since_s: Math.round((now - Date.parse(down.ts)) / 1000) };
}

// Which sites the front door holds in MAINT (fenced), from HAProxy's own view.
export function fencedSites(frontdoor) {
  const out = new Set();
  for (const b of frontdoor?.data?.backends ?? []) {
    const bySite = {};
    for (const s of b.servers) (bySite[s.name.split('-')[1]] ??= []).push(s.state);
    for (const [site, states] of Object.entries(bySite)) if (states.length && states.every((x) => x.startsWith('MAINT'))) out.add(site);
  }
  return out;
}
