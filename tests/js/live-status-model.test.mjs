import test from 'node:test';
import assert from 'node:assert/strict';
import { parseLabStatus, nextRetryDelay, LIVE_STALE_MS } from '../../src/RadiusManager.Api/wwwroot/live-status-model.mjs';
const good = { scope: 'lab', database: 'reachable', observedAtUtc: '2026-11-24T08:00:00.1234567Z' };
test('only fresh server-contract fields are accepted, no arbitrary or subscriber payloads', () => {
  assert.deepEqual(parseLabStatus(good), good);
  assert.notEqual(parseLabStatus(good), good);
  for (const bad of [null, [], {}, {...good, scope:'production'}, {...good, database:'unknown'},
    {...good, password:'secret'}, {...good, observedAtUtc:'invalid'}, {...good, observedAtUtc:'2026-11-24'}])
    assert.equal(parseLabStatus(bad), null);
});
test('retry budget is bounded; stale timeout exceeds two normal samples', () => {
  assert.deepEqual([0,1,2,3,4,-1,0.5].map(nextRetryDelay), [2000,5000,10000,null,null,null,null]);
  assert.equal(LIVE_STALE_MS, 25000);
});
