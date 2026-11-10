// api/server.js: the situation room API (prompts 07 and 12). Node 24, no
// dependencies. It tells the console what Vault, HAProxy, the ticker and the
// drill journal say right now (background pollers fill a cache; routes only
// read it). No Vault token: the status endpoints it reads are unauthenticated
// on every role (probe P19). One write: POST /api/actions/:id, for a signed-in
// operator or admin (Keycloak, D16), forwarded to the host runner, which runs
// the drill step's make target. The API itself never changes Vault.
import { createServer as createHttps } from 'node:https';
import { createServer as createHttp } from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createPoller } from './lib/poll.js';
import { getJson } from './lib/fetch.js';
import { pollSite, withLag } from './lib/vault.js';
import { parseStats } from './lib/frontdoor.js';
import { ID, openDrill, listDrills, readReport } from './lib/journal.js';
import { nextStep, steps, view } from './lib/actions.js';
import { ACTING_ROLES } from './lib/oidc.js';

const SSE_MAX = 20;

// auth: { person(req), login(url), callback(url), logout(req), sessionCookie, crossSiteWrite }
// runner: { status(), run(action, accessToken) } (the host runner, lib below)
// drillSites: config/sites.json's array (roles and names for the drill steps)
export function createApp({ sites, pollers, drillDir, layersFile, auth = null, runner = null, drillSites = [], now = () => Date.now(), log = (o) => console.log(JSON.stringify(o)) }) {
  const clients = new Set();
  let eventId = 0;
  const send = (res, event, data) => res.write(`id: ${++eventId}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  const broadcast = (event, data) => clients.forEach((res) => send(res, event, data));

  const sitesView = () => withLag(sites.map((s) => ({ site: s.id, ...pollers.sites[s.id].envelope(now()) })));
  const snapshot = () => {
    const v = sitesView();
    return {
      sites: v.sites,
      split_brain: v.split_brain,
      frontdoor: pollers.frontdoor.envelope(now()),
      ticker: pollers.ticker.envelope(now()),
      drill: { open: drillDir ? openDrill(drillDir) : null },
    };
  };

  let layersCache = { at: 0, data: null };
  const layers = () => {
    if (now() - layersCache.at > 5000) {
      layersCache = { at: now(), data: layersFile && existsSync(layersFile) ? JSON.parse(readFileSync(layersFile, 'utf8')) : null };
    }
    return layersCache.data;
  };

  const health = () => {
    const sources = { frontdoor: pollers.frontdoor.health(now()), ticker: pollers.ticker.health(now()) };
    for (const s of sites) sources[`site:${s.id}`] = pollers.sites[s.id].health(now());
    const failed = Object.entries(sources).filter(([, h]) => h.state !== 'up' || h.stale).map(([k]) => k);
    const neverRead = Object.values(sources).some((h) => h.state === 'unknown');
    return { code: neverRead ? 503 : 200, body: { ok: failed.length === 0, uptime_s: Math.round(process.uptime()), split_brain: sitesView().split_brain, sources, sse_clients: clients.size, failed } };
  };

  const routes = {
    '/api/sites': () => sitesView().sites,
    '/api/frontdoor': () => pollers.frontdoor.envelope(now()),
    '/api/ticker': () => pollers.ticker.envelope(now()),
    '/api/drill': () => ({ open: drillDir ? openDrill(drillDir) : null }),
    '/api/drills': () => (drillDir ? listDrills(drillDir) : []),
    '/api/layers': () => layers(),
  };

  function handler(req, res) {
    const rid = (req.headers['x-request-id'] && String(req.headers['x-request-id']).slice(0, 64)) || randomUUID();
    res.setHeader('x-request-id', rid);
    res.setHeader('x-content-type-options', 'nosniff');
    const url = new URL(req.url, 'https://api');
    const t0 = now();
    res.on('finish', () => {
      if (url.pathname === '/healthz' && res.statusCode === 200) return;
      log({ at: new Date().toISOString(), request_id: rid, method: req.method, path: url.pathname, status: res.statusCode, ms: now() - t0 });
    });
    const json = (code, body) => res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(body));
    const error = (code, c, message) => json(code, { error: { code: c, message, request_id: rid } });

    const act = /^\/api\/actions\/([a-z-]{1,32})$/.exec(url.pathname);
    const postOnly = Boolean(act) || url.pathname === '/auth/logout';
    if (req.method !== 'GET' && !(req.method === 'POST' && postOnly)) {
      res.setHeader('allow', postOnly ? 'POST' : 'GET');
      return error(405, 'method_not_allowed', 'GET only, except POST /api/actions/<step> and POST /auth/logout');
    }
    if (url.pathname.startsWith('/auth/') || url.pathname === '/api/me' || url.pathname === '/api/actions' || act) {
      return authRoutes(req, res, url, act, { json, error, rid }).catch((e) => {
        log({ at: new Date().toISOString(), request_id: rid, error: e.message });
        error(e.name === 'Unauthenticated' ? 401 : 500, e.name === 'Unauthenticated' ? 'unauthenticated' : 'internal', e.message);
      });
    }
    try {
      if (url.pathname === '/healthz') {
        const h = health();
        return json(h.code, h.body);
      }
      if (url.pathname === '/api/events') {
        if (clients.size >= SSE_MAX) return error(429, 'too_many_streams', `at most ${SSE_MAX} event streams`);
        res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', 'x-accel-buffering': 'no', connection: 'keep-alive' });
        clients.add(res);
        // A reconnecting client gets the whole current state, not a replay.
        send(res, 'snapshot', snapshot());
        const ping = setInterval(() => res.write(': ping\n\n'), 15000);
        const drop = () => {
          clearInterval(ping);
          clients.delete(res);
        };
        req.on('close', drop);
        res.on('error', drop);
        return undefined;
      }
      const m = /^\/api\/drills\/([^/]+)$/.exec(url.pathname);
      if (m) {
        if (!ID.test(m[1])) return error(404, 'not_found', 'no such drill');
        const r = drillDir ? readReport(drillDir, m[1]) : null;
        return r ? json(200, r) : error(404, 'not_found', 'no report for that drill (make report writes one)');
      }
      const route = routes[url.pathname];
      if (!route) return error(404, 'not_found', 'no such route');
      return json(200, route());
    } catch (e) {
      log({ at: new Date().toISOString(), request_id: rid, error: e.message });
      return error(500, 'internal', 'the API failed to answer; see its log');
    }
  }

  async function readBody(req) {
    let body = '';
    for await (const c of req) {
      body += c;
      if (body.length > 1024) throw new Error('body too large');
    }
    return body ? JSON.parse(body) : {};
  }

  // Sign-in, who is signed in, the next drill step and pressing it.
  async function authRoutes(req, res, url, act, { json, error }) {
    if (!auth) return error(404, 'not_found', 'sign-in is not configured');
    const redirect = (to, cookie, status = 302) => res.writeHead(status, { location: to, ...(cookie ? { 'set-cookie': cookie } : {}) }).end();
    if (url.pathname === '/auth/login') return redirect(auth.login(url));
    if (url.pathname === '/auth/callback') {
      try {
        const { sid, returnTo } = await auth.callback(url);
        return redirect(returnTo, auth.sessionCookie(sid, 4 * 3600));
      } catch (e) {
        log({ at: new Date().toISOString(), msg: `sign-in failed: ${e.message}` });
        return redirect('/#/room?signin=failed');
      }
    }
    // Sign-out is a POST from this console only: as a GET, any page on another
    // localhost port could sign the presenter out with an image tag.
    if (url.pathname === '/auth/logout') {
      if (req.method !== 'POST') {
        res.setHeader('allow', 'POST');
        return error(405, 'method_not_allowed', 'sign out with POST /auth/logout');
      }
      if (auth.crossSiteWrite(req)) return error(403, 'cross_site', 'refused: this request came from another site');
      return redirect(auth.logout(req), auth.sessionCookie('', 0), 303);
    }
    const p = await auth.person(req);
    if (url.pathname === '/api/me') return json(200, p ? { signedIn: true, user: p.user, name: p.name, role: p.role } : { signedIn: false });
    const running = runner ? await runner.status().catch(() => null) : null;
    const open = drillDir ? openDrill(drillDir) : null;
    const step = nextStep(drillSites, open);
    const busy = running?.running ? running : null;
    if (url.pathname === '/api/actions') {
      return json(200, { next: view(step, { role: p?.role ?? null, running: busy }), current: running, runner: Boolean(runner) });
    }
    // POST /api/actions/:id
    if (auth.crossSiteWrite(req)) return error(403, 'cross_site', 'refused: this request came from another site');
    if (!p) return error(401, 'unauthenticated', 'sign in first');
    if (!ACTING_ROLES.includes(p.role)) return error(403, 'forbidden', `${p.user} is a ${p.role ?? 'stranger'}: operators and admins run the drill`);
    const want = steps(drillSites).find((s) => s.id === act[1]);
    if (!want) return error(404, 'not_found', 'no such drill step');
    if (want.id !== step.id) return error(409, 'not_next', `the drill is at "${step.id}"`);
    let body;
    try {
      body = await readBody(req);
    } catch {
      return error(400, 'bad_request', 'a small JSON body is expected');
    }
    if (want.confirm && body.confirm !== want.confirm) return error(400, 'confirm', `type ${want.confirm} to confirm`);
    if (!runner) return error(503, 'no_runner', 'the drill runner is not configured: make runner-up');
    const [code, out] = await runner.run(want.id, p.accessToken);
    log({ at: new Date().toISOString(), msg: `action ${want.id} by ${p.user}: runner answered ${code}` });
    return code === 202 ? json(202, out) : error(code, 'runner', out.error ?? `runner answered ${code}`);
  }

  return { handler, broadcast, clients, snapshot, sitesView };
}

// The host runner, reached from this container (D16). The shared secret proves
// the API; the person's own access token goes along and is verified again there.
export function runnerClient({ url, secretFile, fetchImpl = fetch }) {
  const secret = () => readFileSync(secretFile, 'utf8').trim();
  const call = async (method, path, { token, body } = {}) => {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 5000);
    try {
      const r = await fetchImpl(`${url}${path}`, {
        method,
        signal: ac.signal,
        headers: { 'x-runner-secret': secret(), 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
        body: body ? JSON.stringify(body) : undefined,
      });
      return [r.status, await r.json().catch(() => ({}))];
    } finally {
      clearTimeout(t);
    }
  };
  return {
    status: async () => (await call('GET', '/status'))[1].current ?? null,
    run: (action, token) => call('POST', '/run', { token, body: { action } }).catch((e) => [503, { error: `the drill runner does not answer: ${e.message} (make runner-up)` }]),
  };
}

// ── main ──────────────────────────────────────────────────────────────────────
async function main() {
  const env = (k, d) => process.env[k] ?? d;
  const sites = JSON.parse(readFileSync(env('API_SITES_FILE', '/config/sites.json'), 'utf8')).sites.map((s) => ({
    id: s.id,
    name: s.name,
    nodes: Array.from({ length: s.nodes }, (_, i) => `vault-${s.id}-${i + 1}`),
  }));
  const drillDir = env('API_DRILL_DIR', '/build/drill');
  const log = (o) => console.log(JSON.stringify(o));
  let app = null;
  const onSite = (name, snap, before) => {
    if (!app) return;
    if (snap.state !== before.state || snap.data?.role !== before.data?.role) {
      const v = app.sitesView();
      app.broadcast('site', { sites: v.sites, split_brain: v.split_brain });
    }
  };
  const pollers = { sites: {} };
  for (const s of sites) pollers.sites[s.id] = createPoller(`site:${s.id}`, () => pollSite(s), { onChange: onSite, log });
  pollers.frontdoor = createPoller('frontdoor', async () => parseStats((await getJson(env('API_STATS_URL', 'http://frontdoor:8404/stats;csv'))).text), {
    log,
    onChange: (n, snap, before) => {
      const states = (x) => JSON.stringify(x.data?.backends?.map((b) => b.servers.map((sv) => sv.state)));
      if (app && (snap.state !== before.state || states(snap) !== states(before))) app.broadcast('frontdoor', pollers.frontdoor.envelope());
    },
  });
  pollers.ticker = createPoller('ticker', async () => (await getJson(env('API_TICKER_URL', 'http://ticker:9100/metrics'))).json, {
    log,
    onChange: () => app && app.broadcast('ticker', pollers.ticker.envelope()),
  });

  const auth = await import('./lib/session.js');
  const runner = runnerClient({ url: env('API_RUNNER_URL', 'http://host.containers.internal:19193'), secretFile: env('API_RUNNER_SECRET_FILE', '/run/secrets/runner-secret') });
  const drillSites = JSON.parse(readFileSync(env('API_SITES_FILE', '/config/sites.json'), 'utf8')).sites;
  app = createApp({ sites, pollers, drillDir, layersFile: env('API_LAYERS_FILE', '/build/layers.json'), auth, runner, drillSites, log });

  // Journal lines of the open drill, as they are written (and open/close).
  let seen = { id: null, n: 0 };
  setInterval(() => {
    const d = openDrill(drillDir);
    if ((d?.id ?? null) !== seen.id) {
      app.broadcast('drill', { open: d ? { id: d.id, act: d.act, started_at: d.started_at } : null, closed: seen.id });
      seen = { id: d?.id ?? null, n: 0 };
    }
    if (d) {
      d.lines.slice(seen.n).forEach((l) => app.broadcast('journal', l));
      seen.n = d.lines.length;
    }
  }, 1000);

  for (const p of [...Object.values(pollers.sites), pollers.frontdoor, pollers.ticker]) p.start();
  const port = Number(env('API_PORT', '3000'));
  const cert = env('API_TLS_CERT', '/tls/vault.crt');
  const server = existsSync(cert)
    ? createHttps({ cert: readFileSync(cert), key: readFileSync(env('API_TLS_KEY', '/tls/vault.key')), minVersion: 'TLSv1.3' }, app.handler)
    : createHttp(app.handler);
  server.listen(port, '0.0.0.0', () => log({ at: new Date().toISOString(), msg: `situation room API on ${port} (${existsSync(cert) ? 'https' : 'http'})` }));
  const stop = () => server.close(() => process.exit(0));
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
