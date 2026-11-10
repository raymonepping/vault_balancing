// lib/vault.js: one site as Vault reports it. sys/health of every node and
// sys/replication/status of the first node that answers. Both endpoints are
// unauthenticated on every role (probe P19): this API holds no Vault token
// (D12). The role comes ONLY from replication status, never a health code.
import { getJson } from './fetch.js';

const HA = { 200: 'active', 429: 'standby', 472: 'dr-secondary', 473: 'perf-standby', 501: 'uninitialized', 503: 'sealed' };

// Role table (shapes from docs/capabilities.md).
export function deriveRole(rep) {
  const dr = rep?.dr?.mode;
  const perf = rep?.performance?.mode;
  if (!dr || !perf) return 'unknown';
  if (dr === 'primary' && perf === 'secondary') return 'unknown'; // contradictory
  if (dr === 'primary') return 'primary';
  if (perf === 'secondary') return 'performance secondary';
  if (dr === 'secondary') return rep.dr.state === 'idle' && !(rep.dr.primaries ?? []).length ? 'demoted' : 'DR secondary';
  if (dr === 'disabled' && perf === 'disabled') return 'standalone';
  return 'unknown';
}

export async function pollSite(site, { timeoutMs = 800, fetchImpl, nowMs = () => Date.now() } = {}) {
  const nodes = await Promise.all(
    site.nodes.map(async (n) => {
      const read_at = new Date(nowMs()).toISOString();
      try {
        const r = await getJson(`https://${n}:8200/v1/sys/health`, { timeoutMs, fetchImpl });
        const j = r.json ?? {};
        return {
          node: n,
          reachable: true,
          health_code: r.status,
          ha_state: HA[r.status] ?? `http-${r.status}`,
          sealed: j.sealed ?? null,
          version: j.version ?? null,
          skew_s: Number.isFinite(j.server_time_utc) ? Math.round(j.server_time_utc - nowMs() / 1000) : null,
          read_at,
          said: { code: r.status, sealed: j.sealed, standby: j.standby, replication_dr_mode: j.replication_dr_mode, replication_performance_mode: j.replication_performance_mode },
        };
      } catch (e) {
        return { node: n, reachable: false, health_code: null, ha_state: e.kind === 'timeout' ? 'timeout' : 'unreachable', sealed: null, version: null, skew_s: null, read_at, said: { error: e.message } };
      }
    }),
  );
  const answering = nodes.find((n) => n.reachable && n.sealed === false) ?? nodes.find((n) => n.reachable);
  if (!answering) {
    const err = new Error(`no node of ${site.id} answers`);
    err.nodes = nodes;
    throw err;
  }
  let rep = null;
  try {
    rep = (await getJson(`https://${answering.node}:8200/v1/sys/replication/status`, { timeoutMs, fetchImpl })).json?.data ?? null;
  } catch {
    /* the role stays unknown; the nodes are still reported */
  }
  const skews = nodes.map((n) => n.skew_s).filter((s) => s !== null);
  return {
    site: site.id,
    name: site.name,
    reachable: true,
    role: deriveRole(rep),
    cluster_id: rep?.dr?.cluster_id ?? rep?.performance?.cluster_id ?? null,
    nodes,
    wal: {
      dr_last_wal: rep?.dr?.last_wal ?? null,
      dr_last_remote_wal: rep?.dr?.last_remote_wal ?? null,
      perf_last_wal: rep?.performance?.last_wal ?? null,
      perf_last_remote_wal: rep?.performance?.last_remote_wal ?? null,
    },
    skew: skews.some((s) => Math.abs(s) > 1),
    vault_said: { replication: rep ? { dr: pick(rep.dr), performance: pick(rep.performance) } : null },
  };
}

const pick = (k) => (k ? { mode: k.mode, state: k.state, cluster_id: k.cluster_id, last_wal: k.last_wal, last_remote_wal: k.last_remote_wal, primaries: (k.primaries ?? []).map((p) => p.api_address), known_secondaries: k.known_secondaries } : null);

// lag_wal per secondary: the primary's last_wal minus its last_remote_wal of
// the kind it replicates. split_brain: more than one site says primary.
export function withLag(sites) {
  // Only sites that answer now: a dead site keeps its last answer (primary),
  // which must not hide the promoted primary's lag (ponytail review).
  const primaries = sites.filter((s) => s.state === 'up' && s.data?.role === 'primary');
  const p = primaries.length === 1 ? primaries[0].data : null;
  for (const s of sites) {
    if (!s.data) continue;
    let lag = null;
    if (p && s.data.role === 'performance secondary') lag = sub(p.wal.perf_last_wal, s.data.wal.perf_last_remote_wal);
    if (p && s.data.role === 'DR secondary') lag = sub(p.wal.dr_last_wal, s.data.wal.dr_last_remote_wal);
    s.data.lag_wal = lag;
  }
  return { sites, split_brain: primaries.length > 1 };
}
const sub = (a, b) => (Number.isFinite(a) && Number.isFinite(b) ? Math.max(0, a - b) : null);
