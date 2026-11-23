import test from 'node:test';
import assert from 'node:assert/strict';
import { filterPlans, filterAccounts, summarizeVisibleAccounts, formatBytes, formatKbps } from '../../src/RadiusManager.Api/wwwroot/dashboard-utils.mjs';

const plans = [{ name: 'باقة 1M' }, { name: 'باقة 3M' }, { name: 'شبكة نجم' }];
const users = [
  { username: '12345678', planName: 'باقة 1M', active: true },
  { username: '45454545', planName: 'باقة 3M', active: false },
  { username: '77778888', planName: 'باقة 1M', active: true },
];
test('plan search filters Arabic and ignores spaces', () => {
  assert.equal(filterPlans(plans, '  3M  ').length, 1);
  assert.equal(filterPlans(plans, 'شبكة')[0].name, 'شبكة نجم');
  assert.deepEqual(filterPlans(plans, ''), plans);
});
test('account search matches card number and plan name', () => {
  assert.equal(filterAccounts(users, '4545')[0].username, '45454545');
  assert.equal(filterAccounts(users, '1M').length, 2);
});
test('account status filter is correct and cannot show disabled card as enabled', () => {
  assert.deepEqual(filterAccounts(users, '', 'active').map(a => a.username), ['12345678','77778888']);
  assert.deepEqual(filterAccounts(users, '', 'disabled').map(a => a.username), ['45454545']);
  assert.equal(filterAccounts(users, '4545', 'active').length, 0);
});
test('visible account KPI describes only loaded accounts', () => {
  assert.deepEqual(summarizeVisibleAccounts(users), { active: 2, total: 3 });
  assert.deepEqual(summarizeVisibleAccounts([]), { active: 0, total: 0 });
});
test('byte values use IEC units and are safe on invalid input', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(1048576), '1 MB');
  assert.equal(formatBytes(1073741824), '1 GB');
  assert.equal(formatBytes(-1), '—');
  assert.equal(formatBytes(Number.NaN), '—');
});
test('speed formatting keeps explicit Kbps and exact Mbps', () => {
  assert.equal(formatKbps(1024), '1 Mbps');
  assert.equal(formatKbps(256), '256 Kbps');
  assert.equal(formatKbps(3072), '3 Mbps');
});
