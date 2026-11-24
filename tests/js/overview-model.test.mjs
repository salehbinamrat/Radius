import test from 'node:test';
import assert from 'node:assert/strict';
import { buildOverviewSnapshot } from '../../src/RadiusManager.Api/wwwroot/overview-model.mjs';

test('overview uses actual server summary and flags the first-100 limit', () => {
  const accounts = Array.from({ length: 12 }, (_, i) =>
    ({ username: 'card_' + i, planName: 'Lab', active: i % 2 === 0,
       password: 'never-disclose', internalSecret: 'hidden' }));
  const state = buildOverviewSnapshot({ plans: 1500, labAccounts: 2900 }, accounts);
  assert.equal(state.plans, 1500);
  assert.equal(state.labAccounts, 2900);
  assert.equal(state.activeInLoadedAccounts, 6);
  assert.equal(state.loadedAccountCount, 12);
  assert.equal(state.recent.length, 5);
  assert.equal(state.scope, 'first-100-loaded');
  assert.equal(JSON.stringify(state).includes('never-disclose'), false);
  assert.equal(JSON.stringify(state).includes('internalSecret'), false);
  assert.deepEqual(Object.keys(state.recent[0]).sort(), ['active', 'planName', 'username']);
});

test('no artificial zeros for absent, malformed or partial server data', () => {
  const missing = buildOverviewSnapshot({}, []);
  assert.equal(missing.plans, null);
  assert.equal(missing.labAccounts, null);
  assert.equal(missing.activeInLoadedAccounts, 0);
  assert.deepEqual(missing.recent, []);
  assert.equal(buildOverviewSnapshot({plans:-1, labAccounts:'x'}, []).plans, null);
  assert.equal(buildOverviewSnapshot({plans:1.5}, []).plans, null);
  assert.equal(buildOverviewSnapshot({plans:'100'}, []).plans, 100);
});

test('loaded active flag uses the exact legacy truthy predicate', () => {
  const cards=[{username:'one',active:true},{username:'two',active:false},
    {username:'three',active:1},{username:'four',active:null}];
  const value=buildOverviewSnapshot({plans:0,labAccounts:4},cards);
  assert.equal(value.activeInLoadedAccounts, 2);
  assert.equal(value.recent[2].active, true);
});

test('overview snapshots never carry HTTP/Identity or subscriber secrets', () => {
  const actual = buildOverviewSnapshot(
    { plans: 2, labAccounts: 10, token:'server-secret', onlineNas:100 },
    [{username:'u',planName:'p',active:true,password:'pass',
      radcheck:{CleartextPassword:'pass'},sessionToken:'xxx',privateKey:'bad'}]
  );
  const text=JSON.stringify(actual);
  for(const secret of ['server-secret', 'pass','CleartextPassword','privateKey','sessionToken'])
    assert.equal(text.includes(secret),false, secret);
});
