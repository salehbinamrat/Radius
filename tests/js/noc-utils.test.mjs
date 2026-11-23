import test from 'node:test';
import assert from 'node:assert/strict';
import { groupLoadedAccounts, csvCell, buildSafeCsv, searchLoadedRecords } from '../../src/RadiusManager.Api/wwwroot/noc-utils.mjs';
const plans = [
  { id: 'p1', name: 'باقة 1M' },
  { id: 'p2', name: 'باقة 3M' }
];
const accounts = [
  { username: '12345678', planName: 'باقة 1M', active: true },
  { username: '23456789', planName: 'باقة 1M', active: true },
  { username: '34567890', planName: 'باقة 3M', active: false }
];
test('plan distribution uses loaded accounts only, never placeholder KPIs', () => {
  const d = groupLoadedAccounts(accounts);
  assert.equal(d.total, 3);
  assert.deepEqual(d.groups.map(g => [g.name,g.count]), [['باقة 1M',2],['باقة 3M',1]]);
  assert.equal(groupLoadedAccounts([]).total, 0);
  assert.deepEqual(groupLoadedAccounts([]).groups, []);
});
test('distribution collapses groups beyond the configured limit', () => {
  const d = groupLoadedAccounts([{planName:'A'},{planName:'B'},{planName:'C'}],1);
  assert.equal(d.total,3);
  assert.equal(d.groups.length,2);
  assert.equal(d.groups[1].name,'باقات أخرى');
  assert.equal(d.groups.reduce((sum,p)=>sum+p.count,0),3);
});
test('CSV exports neutralize formula injection and escape all columns', () => {
  for (const value of ['=1+1','+SUM(A1:A2)','-1+3','@danger',' \t=3','\r=5'])
    assert.ok(csvCell(value).startsWith('"\''), `unsafe: ${JSON.stringify(value)}`);
  assert.equal(csvCell('normal, "quoted"'), '"normal, ""quoted"""');
  const csv = buildSafeCsv(['اسم','الحالة'], [['=1+1','نشط']]);
  assert.ok(csv.startsWith('\uFEFF'));
  assert.ok(csv.includes('"\'=1+1","نشط"'));
  assert.ok(csv.endsWith('\r\n'));
});
test('global search matches only loaded plans or accounts', () => {
  const result = searchLoadedRecords(plans,accounts,'1M');
  assert.deepEqual(result.map(x=>x.kind),['plan','account','account']);
  assert.deepEqual(searchLoadedRecords(plans,accounts,''),[]);
  assert.equal(searchLoadedRecords(plans,accounts,'مفقود').length,0);
  assert.equal(searchLoadedRecords(plans,accounts,'باقة',2).length,2);
});
test('search does not expose passwords or unmanaged fields', () => {
  const secret = 'S3CRET_NOT_FOR_DISPLAY';
  const result = searchLoadedRecords(plans,[{username:'99999999',planName:'باقة 1M',password:secret}],'999');
  assert.equal(result.length,1);
  assert.ok(!JSON.stringify(result).includes(secret));
});
