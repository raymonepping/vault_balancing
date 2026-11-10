#!/usr/bin/env node
// scripts/runner.js (make runner-up): runs the drill's make targets for the
// console (D16). Host side, 127.0.0.1 only: the API reaches it from its
// container at host.containers.internal. Ansible still runs every promotion;
// this only starts the same make target the terminal would.
//
// POST /run {action}   needs x-runner-secret (the API's shared secret) AND
//                      Authorization: Bearer <the person's Keycloak access
//                      token>, verified again here (signature, issuer,
//                      audience, expiry, operator or admin). The action must be
//                      the drill's NEXT step (api/lib/actions.js against the
//                      open journal); its make arguments come from
//                      config/sites.json, never from the request. One at a time.
// GET  /status         the running or last action, with its output's tail.
// Standard library only.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, createWriteStream, mkdirSync } from 'node:fs';
import { timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createVerifier, mayAct } from '../api/lib/oidc.js';
import { steps, nextStep } from '../api/lib/actions.js';
import { openDrill } from '../api/lib/journal.js';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

export function createRunner({ root = ROOT, secret, verify, spawnImpl = spawn, sites, drillDir = join(root, '.build/drill'), logDir = join(root, '.build/logs') }) {
  let current = null; // { action, by, started_at, finished_at, exit_code, tail[] }
  const sameSecret = (given) => {
    const a = Buffer.from(String(given || ''));
    const b = Buffer.from(secret);
    return a.length === b.length && timingSafeEqual(a, b);
  };
  const publicState = () => (current ? { ...current, running: current.exit_code === null, tail: current.tail.slice(-40) } : null);

  async function run({ action, headers }) {
    if (!sameSecret(headers['x-runner-secret'])) return [401, { error: 'not the API' }];
    const bearer = /^Bearer (.+)$/.exec(headers.authorization || '')?.[1];
    let claims;
    try {
      claims = await verify(bearer);
    } catch (e) {
      return [401, { error: `token refused: ${e.message}` }];
    }
    if (!mayAct(claims)) return [403, { error: `${claims.preferred_username} is not an operator or admin` }];
    if (current && current.exit_code === null) return [409, { error: `busy: ${current.action} (by ${current.by})` }];
    const next = nextStep(sites, openDrill(drillDir));
    if (action !== next.id) return [409, { error: `not the next step: the drill is at "${next.id}"` }];
    const step = steps(sites).find((s) => s.id === action);
    mkdirSync(logDir, { recursive: true });
    const started = new Date().toISOString();
    const log = createWriteStream(join(logDir, `runner-${started.replace(/[:.]/g, '-')}-${action}.log`));
    current = { action, command: `make ${step.make.join(' ')}`, by: claims.preferred_username, started_at: started, finished_at: null, exit_code: null, tail: [] };
    const run = current;
    const child = spawnImpl('make', ['--no-print-directory', ...step.make], {
      cwd: root,
      env: { ...process.env, VBAL_OPERATOR: claims.preferred_username, DRILL_AUTO: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let logOk = true;
    const take = (chunk) => {
      if (logOk) log.write(chunk);
      for (const l of String(chunk).split('\n')) if (l.trim()) run.tail.push(l.replace(/\x1b\[[0-9;]*m/g, ''));
      if (run.tail.length > 400) run.tail.splice(0, run.tail.length - 400);
    };
    // Without these two handlers a full disk or a make that cannot start would
    // crash the runner, and the make it started would die halfway through a step.
    log.on('error', (e) => {
      if (logOk) run.tail.push(`runner: log file failed (${e.message}); the step goes on`);
      logOk = false;
    });
    const finish = (code) => {
      if (run.exit_code !== null) return; // a spawn error is followed by close
      run.exit_code = code;
      run.finished_at = new Date().toISOString();
      log.end();
    };
    child.on('error', (e) => {
      run.tail.push(`runner: make did not start (${e.message})`);
      finish(127);
    });
    child.stdout.on('data', take);
    child.stderr.on('data', take);
    child.on('close', (code) => finish(code ?? 1));
    return [202, publicState()];
  }

  return {
    run,
    status: () => publicState(),
    handler: async (req, res) => {
      const send = (code, body) => res.writeHead(code, { 'content-type': 'application/json' }).end(JSON.stringify(body));
      try {
        if (req.method === 'GET' && req.url === '/status') {
          if (!sameSecret(req.headers['x-runner-secret'])) return send(401, { error: 'not the API' });
          return send(200, { current: publicState() });
        }
        if (req.method === 'POST' && req.url === '/run') {
          let body = '';
          for await (const c of req) {
            body += c;
            if (body.length > 1024) return send(413, { error: 'too large' });
          }
          let action;
          try {
            action = JSON.parse(body || '{}').action;
          } catch {
            return send(400, { error: 'JSON body {action} expected' });
          }
          const [code, out] = await run({ action, headers: req.headers });
          return send(code, out);
        }
        return send(404, { error: 'no such route' });
      } catch (e) {
        return send(500, { error: e.message });
      }
    },
  };
}

function main() {
  const conf = (name, fallback) => {
    for (const f of ['.env', 'config/defaults.conf']) {
      try {
        const m = new RegExp(`^${name}=(.*)$`, 'm').exec(readFileSync(join(ROOT, f), 'utf8'));
        if (m && m[1]) return m[1];
      } catch {
        /* .env is optional */
      }
    }
    return fallback;
  };
  const kc = `http://127.0.0.1:${conf('VBAL_PORT_KEYCLOAK', '19192')}/realms/balancing`;
  const runner = createRunner({
    secret: readFileSync(join(ROOT, '.secrets/identity/runner-secret'), 'utf8').trim(),
    verify: createVerifier({ jwksUrl: `${kc}/protocol/openid-connect/certs`, issuer: `http://localhost:${conf('VBAL_PORT_KEYCLOAK', '19192')}/realms/balancing`, audience: 'balancing-console' }),
    sites: JSON.parse(readFileSync(join(ROOT, 'config/sites.json'), 'utf8')).sites,
  });
  const port = Number(conf('VBAL_PORT_RUNNER', '19193'));
  createServer(runner.handler).listen(port, '127.0.0.1', () => console.log(`runner: listening on 127.0.0.1:${port}`));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
