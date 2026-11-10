// lib/frontdoor.js: HAProxy's stats CSV (read-only; never the runtime socket:
// this API must not be able to fence). One row per backend server.
export function parseStats(csv) {
  const lines = csv.split('\n').filter((l) => l.trim());
  if (!lines.length || !lines[0].startsWith('#')) throw new Error('not a HAProxy stats CSV');
  const head = lines[0].replace(/^#\s*/, '').split(',');
  const col = (name) => head.indexOf(name);
  const [px, sv, st, lc, cs, cc] = ['pxname', 'svname', 'status', 'lastchg', 'check_status', 'check_code'].map(col);
  const backends = {};
  for (const l of lines.slice(1)) {
    const c = l.split(',');
    if (!['primary', 'regional'].includes(c[px]) || ['BACKEND', 'FRONTEND'].includes(c[sv])) continue;
    (backends[c[px]] ??= []).push({
      name: c[sv],
      state: c[st],
      check: c[cs] || null,
      check_code: c[cc] ? Number(c[cc]) : null,
      since_s: c[lc] ? Number(c[lc]) : null,
      vault_said: { csv_row: c.slice(0, 40).join(',') },
    });
  }
  return { backends: Object.entries(backends).map(([name, servers]) => ({ name, servers })) };
}
