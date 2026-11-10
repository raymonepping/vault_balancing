import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseStats } from '../lib/frontdoor.js';

const head = '# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status,weight,act,bck,chkfail,chkdown,lastchg,downtime,qlimit,pid,iid,sid,throttle,lbtot,tracked,type,rate,rate_lim,rate_max,check_status,check_code';
const row = (px, sv, status, lastchg, cs, cc) => {
  const c = Array(38).fill('');
  Object.assign(c, { 0: px, 1: sv, 17: status, 23: lastchg, 36: cs, 37: cc });
  return c.join(',');
};

test('servers per backend; FRONTEND, BACKEND and stats rows are left out', () => {
  const csv = [head, row('writes', 'FRONTEND', 'OPEN'), row('primary', 'vault-ams-1', 'UP', '12', 'L7OK', '200'), row('primary', 'vault-dub-1', 'DOWN', '12', 'L7STS', '472'),
    row('primary', 'vault-ams-2', 'MAINT', '3', '', ''), row('primary', 'BACKEND', 'UP'), row('regional', 'vault-fra-1', 'UP', '5', 'L7OK', '473'), row('stats', 'FRONTEND', 'OPEN'), ''].join('\n');
  const r = parseStats(csv);
  assert.deepEqual(r.backends.map((b) => b.name), ['primary', 'regional']);
  assert.deepEqual(r.backends[0].servers.map((s) => [s.name, s.state, s.check_code]), [['vault-ams-1', 'UP', 200], ['vault-dub-1', 'DOWN', 472], ['vault-ams-2', 'MAINT', null]]);
  assert.equal(r.backends[1].servers[0].since_s, 5);
});

test('anything that is not a stats CSV is an error, not an empty front door', () => {
  assert.throws(() => parseStats('<html>503</html>'), /not a HAProxy stats CSV/);
});
