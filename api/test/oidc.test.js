import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { createVerifier, roleOf, mayAct } from '../lib/oidc.js';

const ISS = 'http://localhost:19192/realms/balancing';
const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'k1', use: 'sig', alg: 'RS256' };
const jwks = async () => new Response(JSON.stringify({ keys: [jwk] }));
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const NOW = 1_800_000_000_000;
function token(claims, { key = privateKey, kid = 'k1', alg = 'RS256' } = {}) {
  const h = b64({ alg, kid, typ: 'JWT' });
  const p = b64({ iss: ISS, aud: ['balancing-console', 'account'], exp: NOW / 1000 + 300, preferred_username: 'oscar', groups: ['drill-viewers', 'drill-operators'], ...claims });
  return `${h}.${p}.${sign('RSA-SHA256', Buffer.from(`${h}.${p}`), key).toString('base64url')}`;
}
const verify = createVerifier({ jwksUrl: 'x', issuer: ISS, audience: 'balancing-console', fetchImpl: jwks, now: () => NOW });

test('a valid operator token is accepted, with its groups', async () => {
  const c = await verify(token({}));
  assert.equal(c.preferred_username, 'oscar');
  assert.equal(roleOf(c), 'operator');
  assert.equal(mayAct(c), true);
});

test('every forged or wrong token is refused', async () => {
  await assert.rejects(verify(token({}, { key: other.privateKey })), /bad signature/);
  await assert.rejects(verify(token({ iss: 'http://evil/realms/balancing' })), /wrong issuer/);
  await assert.rejects(verify(token({ aud: 'account' })), /wrong audience/);
  await assert.rejects(verify(token({ exp: NOW / 1000 - 120 })), /expired/);
  await assert.rejects(verify(token({}, { kid: 'nope' })), /unknown signing key/);
  await assert.rejects(verify(token({}, { alg: 'HS256' })), /unexpected alg/);
  await assert.rejects(verify('a.b'), /not a JWT/);
  // A token whose payload was edited after signing (a viewer making herself an admin).
  const t = token({ groups: ['drill-viewers'] }).split('.');
  t[1] = b64({ iss: ISS, aud: 'balancing-console', exp: NOW / 1000 + 300, groups: ['drill-admins'] });
  await assert.rejects(verify(t.join('.')), /bad signature/);
});

test('roles: admin over operator over viewer; viewers and strangers may not act', () => {
  assert.equal(roleOf({ groups: ['drill-viewers', 'drill-admins'] }), 'admin');
  assert.equal(roleOf({ groups: ['drill-viewers'] }), 'viewer');
  assert.equal(mayAct({ groups: ['drill-viewers'] }), false);
  assert.equal(roleOf({}), null);
  assert.equal(mayAct({ groups: ['other'] }), false);
});
