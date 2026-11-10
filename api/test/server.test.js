import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createApp } from '../server.js';

const env = (state, data) => ({ envelope: () => ({ state, read_at: state === 'unknown' ? null : new Date().toISOString(), age_ms: 0, stale: state === 'unknown', data }), health: () => ({ state, age_ms: 0, stale: state === 'unknown', last_poll_ms: 1, skipped: 0 }) });
const sites = [{ id: 'ams' }, { id: 'dub' }];

async function serve(pollers) {
  const app = createApp({ sites, pollers, drillDir: null, layersFile: null, log: () => {} });
  const srv = createServer(app.handler).listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  return { app, srv, base: `http://127.0.0.1:${srv.address().port}` };
}
const upPollers = () => ({
  sites: { ams: env('up', { role: 'primary', wal: {} }), dub: env('up', { role: 'DR secondary', wal: {} }) },
  frontdoor: env('up', { backends: [] }),
  ticker: env('up', { last_ack_seq: 1 }),
});

test('read-only: anything but GET is 405 with Allow: GET and the one error shape', async () => {
  const { srv, base } = await serve(upPollers());
  const r = await fetch(`${base}/api/sites`, { method: 'POST' });
  assert.equal(r.status, 405);
  assert.equal(r.headers.get('allow'), 'GET');
  const b = await r.json();
  assert.equal(b.error.code, 'method_not_allowed');
  assert.ok(b.error.request_id);
  srv.close();
});

test('routes: sites array, unknown route 404, a traversal drill id 404', async () => {
  const { srv, base } = await serve(upPollers());
  const s = await (await fetch(`${base}/api/sites`)).json();
  assert.deepEqual(s.map((x) => x.data.role), ['primary', 'DR secondary']);
  assert.equal((await fetch(`${base}/api/nope`)).status, 404);
  assert.equal((await fetch(`${base}/api/drills/..%2F..%2Fetc`)).status, 404);
  assert.equal((await fetch(`${base}/api/drills/drill-1`)).status, 404);
  srv.close();
});

test('healthz: 503 before every source was read; 200 with ok:false while Vault is down', async () => {
  const p = upPollers();
  p.ticker = env('unknown', null);
  let { srv, base } = await serve(p);
  assert.equal((await fetch(`${base}/healthz`)).status, 503);
  srv.close();
  const q = upPollers();
  q.sites.ams = env('down', null);
  ({ srv, base } = await serve(q));
  const r = await fetch(`${base}/healthz`);
  assert.equal(r.status, 200);
  const b = await r.json();
  assert.equal(b.ok, false);
  assert.deepEqual(b.failed, ['site:ams']);
  srv.close();
});

test('SSE: a snapshot first, x-accel-buffering no, and at most 20 streams', async () => {
  const { app, srv, base } = await serve(upPollers());
  const acs = [];
  for (let i = 0; i < 20; i++) {
    const ac = new AbortController();
    acs.push(ac);
    const r = await fetch(`${base}/api/events`, { signal: ac.signal });
    assert.equal(r.headers.get('x-accel-buffering'), 'no');
    if (i === 0) {
      const reader = r.body.getReader();
      const { value } = await reader.read();
      assert.match(new TextDecoder().decode(value), /^id: 1\nevent: snapshot\n/);
    }
  }
  assert.equal(app.clients.size, 20);
  assert.equal((await fetch(`${base}/api/events`)).status, 429);
  acs.forEach((a) => a.abort());
  srv.closeAllConnections();
  srv.close();
});

test('no response carries a token-shaped string', async () => {
  const p = upPollers();
  p.ticker = env('up', { note: 'clean' });
  const { srv, base } = await serve(p);
  for (const path of ['/api/sites', '/api/frontdoor', '/api/ticker', '/api/drill', '/api/drills', '/healthz']) {
    const t = await (await fetch(`${base}${path}`)).text();
    assert.doesNotMatch(t, /\bhv[sbr]\.[A-Za-z0-9_-]{20,}/, path);
  }
  srv.close();
});

// ── prompt 12: the drill buttons ─────────────────────────────────────────────
const DRILL_SITES = [
  { id: 'ams', name: 'Amsterdam', role: 'primary' },
  { id: 'fra', name: 'Frankfurt', role: 'performance' },
  { id: 'dub', name: 'Dublin', role: 'dr' },
];
const PEOPLE = { oscar: { user: 'oscar', name: 'Oscar', role: 'operator', accessToken: 'tok-oscar' }, vera: { user: 'vera', name: 'Vera', role: 'viewer', accessToken: 'tok-vera' } };
const fakeAuth = {
  person: async (req) => PEOPLE[req.headers['x-test-user']] ?? null,
  crossSiteWrite: (req) => Boolean(req.headers['sec-fetch-site']) && req.headers['sec-fetch-site'] !== 'same-origin',
  login: () => 'http://kc/login',
  callback: async () => ({ sid: 's', returnTo: '/' }),
  logout: () => 'http://kc/logout',
  sessionCookie: (id) => `vbal_sid=${id}`,
};
async function serveActions(runnerAnswer = [202, { action: 'site-down', running: true }]) {
  const ran = [];
  const runner = { status: async () => null, run: async (action, token) => (ran.push({ action, token }), runnerAnswer) };
  const app = createApp({ sites, pollers: upPollers(), drillDir: null, layersFile: null, auth: fakeAuth, runner, drillSites: DRILL_SITES, log: () => {} });
  const srv = createServer(app.handler).listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  return { srv, ran, base: `http://127.0.0.1:${srv.address().port}` };
}
const post = (base, path, user, body = {}, extra = {}) =>
  fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...(user ? { 'x-test-user': user } : {}), ...extra }, body: JSON.stringify(body) });

test('the next step, and who may press it', async () => {
  const { srv, base } = await serveActions();
  const anon = await (await fetch(`${base}/api/actions`)).json();
  assert.equal(anon.next.id, 'site-down');
  assert.equal(anon.next.enabled, false);
  const viewer = await (await fetch(`${base}/api/actions`, { headers: { 'x-test-user': 'vera' } })).json();
  assert.match(viewer.next.reason, /viewer/);
  const op = await (await fetch(`${base}/api/actions`, { headers: { 'x-test-user': 'oscar' } })).json();
  assert.equal(op.next.enabled, true);
  assert.equal(op.next.command, 'make site-down SITE=ams');
  assert.deepEqual(await (await fetch(`${base}/api/me`, { headers: { 'x-test-user': 'oscar' } })).json(), { signedIn: true, user: 'oscar', name: 'Oscar', role: 'operator' });
  srv.close();
});

test('pressing it: 401 signed out, 403 viewer, 403 another site, 409 out of order, 400 unconfirmed, 202 for an operator', async () => {
  const { srv, base, ran } = await serveActions();
  assert.equal((await post(base, '/api/actions/site-down', null, { confirm: 'ams' })).status, 401);
  const v = await post(base, '/api/actions/site-down', 'vera', { confirm: 'ams' });
  assert.equal(v.status, 403);
  assert.match((await v.json()).error.message, /vera is a viewer/);
  assert.equal((await post(base, '/api/actions/site-down', 'oscar', { confirm: 'ams' }, { 'sec-fetch-site': 'same-site' })).status, 403);
  assert.equal((await post(base, '/api/actions/promote', 'oscar')).status, 409);
  assert.equal((await post(base, '/api/actions/site-down', 'oscar', { confirm: 'dub' })).status, 400);
  assert.equal((await post(base, '/api/actions/nope', 'oscar')).status, 404);
  assert.equal(ran.length, 0, 'nothing reached the runner yet');
  const ok = await post(base, '/api/actions/site-down', 'oscar', { confirm: 'ams' });
  assert.equal(ok.status, 202);
  assert.deepEqual(ran, [{ action: 'site-down', token: 'tok-oscar' }]);
  assert.equal((await fetch(`${base}/api/actions/site-down`, { method: 'DELETE' })).status, 405);
  srv.close();
});

test('a runner that refuses or is down is reported, not hidden', async () => {
  const { srv, base } = await serveActions([503, { error: 'the drill runner does not answer: ECONNREFUSED (make runner-up)' }]);
  const r = await post(base, '/api/actions/site-down', 'oscar', { confirm: 'ams' });
  assert.equal(r.status, 503);
  assert.match((await r.json()).error.message, /make runner-up/);
  srv.close();
});
