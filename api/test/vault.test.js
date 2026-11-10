import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { deriveRole, withLag, pollSite } from '../lib/vault.js';

// Shapes as the probe captured them (docs/capabilities.md, P2, P12, P13).
const R = {
  primary: { dr: { mode: 'primary' }, performance: { mode: 'primary' } },
  perf: { dr: { mode: 'disabled' }, performance: { mode: 'secondary', state: 'stream-wals' } },
  dr: { dr: { mode: 'secondary', state: 'stream-wals', primaries: [{ api_address: 'https://vault-ams-1:8200' }] }, performance: { mode: 'disabled' } },
  demoted: { dr: { mode: 'secondary', state: 'idle', primaries: [] }, performance: { mode: 'disabled' } },
  fresh: { dr: { mode: 'disabled' }, performance: { mode: 'disabled' } },
};

test('the role comes from replication status only', () => {
  assert.equal(deriveRole(R.primary), 'primary');
  assert.equal(deriveRole(R.perf), 'performance secondary');
  assert.equal(deriveRole(R.dr), 'DR secondary');
  assert.equal(deriveRole(R.demoted), 'demoted');
  assert.equal(deriveRole(R.fresh), 'standalone');
  assert.equal(deriveRole({ dr: { mode: 'primary' }, performance: { mode: 'secondary' } }), 'unknown');
  assert.equal(deriveRole(null), 'unknown');
  assert.equal(deriveRole({ dr: { mode: 'primary' } }), 'unknown');
});

test('lag in WAL entries per secondary, and two primaries are split brain', () => {
  const site = (role, wal) => ({ state: 'up', data: { role, wal } });
  const v = withLag([
    site('primary', { perf_last_wal: 100, dr_last_wal: 100 }),
    site('performance secondary', { perf_last_remote_wal: 97 }),
    site('DR secondary', { dr_last_remote_wal: 100 }),
  ]);
  assert.deepEqual(v.sites.map((s) => s.data.lag_wal), [null, 3, 0]);
  assert.equal(v.split_brain, false);
  assert.equal(withLag([site('primary', {}), site('primary', {})]).split_brain, true);
});

test('a dead old primary does not hide the new primary lag (Act II onwards)', () => {
  const dead = { state: 'down', data: { role: 'primary', wal: { perf_last_wal: 50 } } };
  const v = withLag([dead, { state: 'up', data: { role: 'primary', wal: { perf_last_wal: 200 } } }, { state: 'up', data: { role: 'performance secondary', wal: { perf_last_remote_wal: 198 } } }]);
  assert.equal(v.sites[2].data.lag_wal, 2);
  assert.equal(v.split_brain, false);
});

test('a dead site (accepts, never answers) is reported within the deadline', async () => {
  const sockets = [];
  const srv = createServer((s) => sockets.push(s)).listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  const port = srv.address().port;
  const viaHang = (url, opts) => fetch(url.replace(/^https:\/\/[^/]+/, `http://127.0.0.1:${port}`), opts);
  const t0 = Date.now();
  await assert.rejects(pollSite({ id: 'ams', nodes: ['vault-ams-1', 'vault-ams-2'] }, { timeoutMs: 300, fetchImpl: viaHang }), /no node of ams answers/);
  const took = Date.now() - t0;
  assert.ok(took < 900, `took ${took} ms`);
  sockets.forEach((s) => s.destroy());
  srv.close();
});

test('a live site: every node, its health code, and the role', async () => {
  const fake = async (url) => {
    const body = url.endsWith('/sys/health')
      ? { sealed: false, standby: false, version: '2.2.1+ent', server_time_utc: Math.round(Date.now() / 1000) }
      : { data: R.primary };
    return new Response(JSON.stringify(body), { status: url.includes('vault-ams-2') && url.endsWith('/sys/health') ? 473 : 200 });
  };
  const s = await pollSite({ id: 'ams', name: 'Amsterdam', nodes: ['vault-ams-1', 'vault-ams-2'] }, { fetchImpl: fake });
  assert.equal(s.role, 'primary');
  assert.deepEqual(s.nodes.map((n) => n.ha_state), ['active', 'perf-standby']);
  assert.equal(s.skew, false);
});
