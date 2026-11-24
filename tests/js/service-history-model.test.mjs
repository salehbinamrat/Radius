import test from 'node:test';
import assert from 'node:assert/strict';
import {parseServiceHistory,historyMetrics,latencySegments} from '../../src/RadiusManager.Api/wwwroot/service-history-model.mjs';
const sample=(second,db='reachable',radius='unknown')=>({observedAtUtc:new Date(1800000000000+second*1000).toISOString(),
  database:db,databaseCheckMs:db==='reachable'?2:null,radius,radiusCheckedAtUtc:radius==='unknown'?null:new Date(1800000000000+second*1000).toISOString()});
const wrap=samples=>({scope:'lab',retention:'process-memory',intervalSeconds:15,capacity:240,samples});
test('strict bounded shape and no fabricated latency',()=>{
  const valid=wrap([sample(0),sample(15,'no-response','responsive')]);
  assert.deepEqual(parseServiceHistory(valid),valid);
  assert.notEqual(parseServiceHistory(valid).samples[0],valid.samples[0]);
  for(const bad of [null,wrap(Array(241).fill(sample(0))),wrap([sample(15),sample(0)]),
    wrap([{...sample(0),databaseCheckMs:NaN}]),wrap([{...sample(0,'no-response'),databaseCheckMs:0}]),
    wrap([{...sample(0),secret:'x'}]),wrap([{...sample(0),radius:'responsive',radiusCheckedAtUtc:null}]),
    {...valid,retention:'persistent'}]) assert.equal(parseServiceHistory(bad),null);
});
test('failures and gaps are never connected, counts are samples not incidents',()=>{
  const rows=[sample(0),sample(15),sample(30,'no-response','no-response'),sample(45),sample(90)];
  assert.deepEqual(latencySegments(rows).map(x=>x.length),[2,1,1]);
  assert.deepEqual(historyMetrics(rows),{count:5,mean:2,databaseFailures:1,radiusFailures:1,unknown:4});
  assert.equal(historyMetrics([]).mean,null);
});

test('retention reports real storage mode without changing sample semantics',()=>{
  for(const retention of ['volume-snapshot','storage-degraded']){
    const payload={...wrap([sample(0)]),retention};
    assert.deepEqual(parseServiceHistory(payload),payload);
  }
});
