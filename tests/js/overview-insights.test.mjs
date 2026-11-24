import test from 'node:test';
import assert from 'node:assert/strict';
import { buildOverviewSnapshot } from '../../src/RadiusManager.Api/wwwroot/overview-model.mjs';

test('package mix uses real loaded accounts and the existing top-five aggregation', () => {
  const accounts = [
    ...Array.from({length: 4}, (_,i)=>({username:'a'+i,planName:'1M',active:true})),
    ...Array.from({length: 3}, (_,i)=>({username:'b'+i,planName:'2M',active:false})),
    {username:'c',planName:'3M',active:true},
  ];
  const data=buildOverviewSnapshot({plans:3,labAccounts:800},accounts);
  assert.equal(data.loadedAccountCount,8);
  assert.equal(data.labAccounts,800);
  assert.equal(data.groups.length,3);
  assert.deepEqual(data.groups.map(g=>[g.name,g.count]), [['1M',4],['2M',3],['3M',1]]);
  assert.equal(data.groups.reduce((sum,g)=>sum+g.count,0),8);
  assert.ok(data.groups.every(g=>g.percent>=0 && g.percent<=100));
  assert.equal(typeof data.lastSyncedAt,'string');
  assert.ok(!Number.isNaN(Date.parse(data.lastSyncedAt)));
});

test('more than five plans collapse into other group without claiming whole network', () => {
  const accounts=Array.from({length:7},(_,i)=>({username:'card-'+i,planName:'Plan '+i,active:true,
    secret:'invisible',password:'never expose'}));
  const data=buildOverviewSnapshot({plans:99,labAccounts:1000},accounts);
  assert.equal(data.groups.length,6);
  assert.equal(data.groups.at(-1).name,'باقات أخرى');
  assert.equal(data.groups.at(-1).count,2);
  assert.equal(data.scope,'first-100-loaded');
  assert.equal(JSON.stringify(data).includes('never expose'),false);
  assert.equal(JSON.stringify(data).includes('invisible'),false);
});

test('no accounts yields no guessed distribution or fabricated server status',()=>{
  const value=buildOverviewSnapshot({plans:0,labAccounts:0},[]);
  assert.deepEqual(value.groups,[]);
  assert.equal(value.loadedAccountCount,0);
  assert.equal(Object.hasOwn(value,'routerConnected'),false);
  assert.equal(Object.hasOwn(value,'freeRadiusConnected'),false);
});
