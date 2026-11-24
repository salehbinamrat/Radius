import test from 'node:test';
import assert from 'node:assert/strict';
import { parseLabStatus, nextRetryDelay, LIVE_STALE_MS } from '../../src/RadiusManager.Api/wwwroot/live-status-model.mjs';
const good = { scope: 'lab', api: 'running', database: 'reachable', sessionCheckMs: 12.34, observedAtUtc: '2026-11-24T08:00:00.1234567Z', radius: {state:'responsive',checkedAtUtc:'2026-11-24T07:59:50Z'} };
test('only fresh server-contract fields are accepted, no arbitrary or subscriber payloads', () => {
  assert.deepEqual(parseLabStatus(good), good);
  assert.notEqual(parseLabStatus(good), good);
  for (const bad of [null, [], {}, {...good, scope:'production'}, {...good, database:'unknown'},
    {...good, radius:{state:'responsive',checkedAtUtc:'2026-11-24T07:58:00Z'}},
    {...good, radius:{state:'unknown',checkedAtUtc:good.observedAtUtc}}, {...good, radius:{state:'responsive',checkedAtUtc:null}},
    {...good, radius:{state:'responsive',checkedAtUtc:good.observedAtUtc, secret:'x'}}, {...good, api:'unknown'}, {...good, sessionCheckMs:-1}, {...good, sessionCheckMs:Infinity},
    {...good, sessionCheckMs:'12'}, {...good, sessionCheckMs:10001}, {...good, password:'secret'}, {...good, observedAtUtc:'invalid'}, {...good, observedAtUtc:'2026-11-24'}])
    assert.equal(parseLabStatus(bad), null);
});
test('retry budget is bounded; stale timeout exceeds two normal samples', () => {
  assert.deepEqual([0,1,2,3,4,-1,0.5].map(nextRetryDelay), [2000,5000,10000,null,null,null,null]);
  assert.equal(LIVE_STALE_MS, 25000);
});
