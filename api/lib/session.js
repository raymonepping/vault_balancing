// lib/session.js: who is at the console (D16), from vault_codex.
//
//   A person   signs in on Keycloak's own page: Authorization Code + PKCE
//              (S256) with the confidential client balancing-console; the code
//              exchange is server to server, tokens stay here, the browser
//              holds an opaque HttpOnly cookie (vbal_sid). There is no Vault
//              login: every token is verified here (lib/oidc.js) and the
//              signed `groups` claim gives the role.
//   Scripts    may send `Authorization: Bearer <Keycloak access token>`
//              (the tests and make verify, client balancing-cli).
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createVerifier, roleOf } from './oidc.js';

const env = (k, d) => (process.env[k] ?? d).replace(/\/$/, '');
const KC_PUBLIC = env('KEYCLOAK_PUBLIC_URL', 'http://localhost:19192');
const KC_INTERNAL = env('KEYCLOAK_INTERNAL_URL', 'http://keycloak:8080');
const REALM = 'balancing';
const CLIENT_ID = 'balancing-console';
const SECRET_FILE = process.env.CONSOLE_CLIENT_SECRET_FILE || '/run/secrets/console-client-secret';
export const CONSOLE_URL = env('CONSOLE_URL', 'https://localhost:19190');
const REDIRECT_URI = `${CONSOLE_URL}/auth/callback`;
export const COOKIE = 'vbal_sid';
const SESSION_IDLE_MS = 4 * 3600 * 1000; // the realm's ssoSessionIdleTimeout
const PENDING_MS = 10 * 60 * 1000;
const PENDING_MAX = 100;

export class Unauthenticated extends Error {}

export const b64url = (buf) => Buffer.from(buf).toString('base64url');
export const randomToken = (bytes = 32) => b64url(randomBytes(bytes));
export const pkceChallenge = (verifier) => b64url(createHash('sha256').update(verifier).digest());
const claimsOf = (jwt) => JSON.parse(Buffer.from(String(jwt).split('.')[1] || '', 'base64url').toString('utf8'));

export function parseCookies(header) {
  const out = {};
  for (const part of String(header || '').split(';')) {
    const i = part.indexOf('=');
    if (i < 1) continue;
    const k = part.slice(0, i).trim();
    if (!(k in out)) out[k] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

// SameSite=Lax: the cookie is set on the redirect back from Keycloak (a
// cross-site navigation); every state change is a POST, which Lax never sends
// cross-site, and crossSiteWrite refuses other local origins as well.
export const sessionCookie = (id, maxAgeSeconds) => `${COOKIE}=${id}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAgeSeconds}`;

// Every https://localhost:<port> is the SAME site to a browser: a POST from
// another local app would carry the cookie. Sec-Fetch-Site says where it came
// from; a write from anywhere but this origin is refused.
export const crossSiteWrite = (req) => {
  if (req.method === 'GET' || req.method === 'HEAD') return false;
  const site = req.headers['sec-fetch-site'];
  return Boolean(site) && site !== 'same-origin' && site !== 'none';
};
export const safeReturn = (v) => (/^\/(#\/[a-z0-9-]+)?$/.test(String(v || '/')) ? String(v) : '/');

export const verifyAccess = createVerifier({
  jwksUrl: `${KC_INTERNAL}/realms/${REALM}/protocol/openid-connect/certs`,
  issuer: `${KC_PUBLIC}/realms/${REALM}`,
  audience: CLIENT_ID,
});

const pending = new Map(); // state -> { verifier, nonce, returnTo, at }
const sessions = new Map(); // sid -> session
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of pending) if (now - v.at > PENDING_MS) pending.delete(k);
  for (const [k, v] of sessions) if (now - v.seen > SESSION_IDLE_MS) sessions.delete(k);
}, 60_000).unref();

async function tokenEndpoint(params) {
  const secret = readFileSync(SECRET_FILE, 'utf8').trim();
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(new Error('Keycloak token endpoint timed out')), 10_000);
  try {
    const r = await fetch(`${KC_INTERNAL}/realms/${REALM}/protocol/openid-connect/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', authorization: `Basic ${Buffer.from(`${CLIENT_ID}:${secret}`).toString('base64')}` },
      body: new URLSearchParams(params),
      signal: ac.signal,
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Unauthenticated(`Keycloak refused: ${j.error_description || j.error || r.status}`);
    return j;
  } finally {
    clearTimeout(t);
  }
}

const personOf = (claims, extra = {}) => ({
  user: claims.preferred_username,
  name: claims.given_name || claims.preferred_username,
  role: roleOf(claims),
  ...extra,
});

export function login(url) {
  const state = randomToken(24);
  const verifier = randomToken(48);
  const nonce = randomToken(16);
  pending.set(state, { verifier, nonce, returnTo: safeReturn(url.searchParams.get('return')), at: Date.now() });
  while (pending.size > PENDING_MAX) pending.delete(pending.keys().next().value);
  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: 'code',
    scope: 'openid profile',
    redirect_uri: REDIRECT_URI,
    state,
    nonce,
    code_challenge: pkceChallenge(verifier),
    code_challenge_method: 'S256',
  });
  return `${KC_PUBLIC}/realms/${REALM}/protocol/openid-connect/auth?${q}`;
}

export async function callback(url) {
  const state = url.searchParams.get('state');
  const p = state && pending.get(state);
  pending.delete(state);
  if (!p) throw new Unauthenticated('sign-in expired or was not started here; try again');
  if (url.searchParams.get('error')) throw new Unauthenticated(`Keycloak: ${url.searchParams.get('error_description') || url.searchParams.get('error')}`);
  const t = await tokenEndpoint({ grant_type: 'authorization_code', code: url.searchParams.get('code') || '', redirect_uri: REDIRECT_URI, code_verifier: p.verifier });
  if (claimsOf(t.id_token).nonce !== p.nonce) throw new Unauthenticated('nonce mismatch');
  const c = await verifyAccess(t.access_token);
  const s = { id: randomToken(32), ...personOf(c), accessToken: t.access_token, accessExp: c.exp, refreshToken: t.refresh_token, idToken: t.id_token, seen: Date.now() };
  sessions.set(s.id, s);
  return { sid: s.id, returnTo: p.returnTo };
}

export function logout(req) {
  const sid = parseCookies(req.headers.cookie)[COOKIE];
  const s = sid && sessions.get(sid);
  sessions.delete(sid);
  const q = new URLSearchParams({ client_id: CLIENT_ID, post_logout_redirect_uri: `${CONSOLE_URL}/` });
  if (s?.idToken) q.set('id_token_hint', s.idToken);
  return `${KC_PUBLIC}/realms/${REALM}/protocol/openid-connect/logout?${q}`;
}

// The person behind a request, with an access token valid for at least a
// minute (refreshed here), or null.
export async function person(req) {
  const bearer = /^Bearer (.+)$/.exec(req.headers.authorization || '')?.[1];
  if (bearer) {
    try {
      return personOf(await verifyAccess(bearer), { accessToken: bearer });
    } catch {
      return null;
    }
  }
  const sid = parseCookies(req.headers.cookie)[COOKIE];
  const s = sid && sessions.get(sid);
  if (!s) return null;
  s.seen = Date.now();
  if (s.accessExp - 60 < Date.now() / 1000) {
    try {
      const t = await tokenEndpoint({ grant_type: 'refresh_token', refresh_token: s.refreshToken });
      const c = await verifyAccess(t.access_token);
      Object.assign(s, personOf(c), { accessToken: t.access_token, accessExp: c.exp, refreshToken: t.refresh_token || s.refreshToken, idToken: t.id_token || s.idToken });
    } catch (e) {
      console.error(JSON.stringify({ at: new Date().toISOString(), msg: `session of ${s.user} ended: ${e.message}` }));
      sessions.delete(s.id);
      return null;
    }
  }
  return s;
}
