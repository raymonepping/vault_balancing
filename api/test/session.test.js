import { test } from 'node:test';
import assert from 'node:assert/strict';
import { crossSiteWrite, safeReturn } from '../lib/session.js';

const req = (method, site) => ({ method, headers: site === undefined ? {} : { 'sec-fetch-site': site } });

test('crossSiteWrite: only this origin, a typed address or a script may write', () => {
  assert.equal(crossSiteWrite(req('POST', 'same-origin')), false);
  assert.equal(crossSiteWrite(req('POST', 'none')), false);
  assert.equal(crossSiteWrite(req('POST')), false); // curl, the tests: no browser header
  // every https://localhost:<port> is the same SITE: another local app's page
  assert.equal(crossSiteWrite(req('POST', 'same-site')), true);
  assert.equal(crossSiteWrite(req('POST', 'cross-site')), true);
  assert.equal(crossSiteWrite(req('GET', 'cross-site')), false);
});

test('safeReturn: back to a page of this console, never elsewhere', () => {
  assert.equal(safeReturn('/'), '/');
  assert.equal(safeReturn('/#/report'), '/#/report');
  assert.equal(safeReturn(null), '/');
  for (const bad of ['//evil.example', 'https://evil.example/', '/#/../x', '/\\evil.example', '/#/room?x=1', 'javascript:alert(1)']) {
    assert.equal(safeReturn(bad), '/', bad);
  }
});
