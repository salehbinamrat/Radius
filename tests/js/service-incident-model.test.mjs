import test from 'node:test';
import assert from 'node:assert/strict';
import {parseServiceIncidents} from '../../src/RadiusManager.Api/wwwroot/service-alert-model.mjs';
const time='2026-11-24T10:00:00Z';
const later='2026-11-24T10:01:00Z';
const incident={id:'11111111-1111-4111-8111-111111111111',service:'postgresql',failureConfirmedAtUtc:time,recoveryConfirmedAtUtc:null};
const payload={scope:'lab',retention:'volume-snapshot',closedCapacity:256,
  services:[{service:'postgresql',state:'failed',severity:'critical',lastEvidenceAtUtc:time},
    {service:'freeradius',state:'unknown',severity:'warning',lastEvidenceAtUtc:null}],incidents:[incident]};
test('stable incident identity, validated recovery, and independent storage state',()=>{
  assert.deepEqual(parseServiceIncidents(payload),payload);
  assert.notEqual(parseServiceIncidents(payload).incidents[0],incident);
  const recovered={...payload,services:[{...payload.services[0],state:'healthy',severity:'info'},payload.services[1]],
    incidents:[{...incident,recoveryConfirmedAtUtc:later}],retention:'storage-degraded'};
  assert.deepEqual(parseServiceIncidents(recovered),recovered);
  for(const invalid of [null,{...payload,incidents:[]},{...payload,incidents:[incident,incident]},
    {...payload,incidents:[incident,{...incident,id:'22222222-2222-4222-8222-222222222222'}]},
    {...payload,incidents:[{...incident,id:'bad'}]},
    {...payload,incidents:[{...incident,recoveryConfirmedAtUtc:'2026-11-24T09:00:00Z'}]},
    {...payload,retention:'unknown'}, {...payload,closedCapacity:999},
    {...payload,incidents:[{...incident,subscriber:'x'}]}])
      assert.equal(parseServiceIncidents(invalid),null);
});
