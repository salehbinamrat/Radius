import test from 'node:test';
import assert from 'node:assert/strict';
import {parseServiceAlerts} from '../../src/RadiusManager.Api/wwwroot/service-alert-model.mjs';
const time='2026-11-24T10:00:00Z';
const payload={scope:'lab',window:'retained-samples',confirmationCount:2,
  services:[{service:'postgresql',state:'failed',severity:'critical',lastEvidenceAtUtc:time},
    {service:'freeradius',state:'unknown',severity:'warning',lastEvidenceAtUtc:null}],
  events:[{service:'postgresql',kind:'failure-confirmed',severity:'critical',confirmedAtUtc:time}]};
test('accepts only bounded strict alert projection and copies rows',()=>{
  assert.deepEqual(parseServiceAlerts(payload),payload);
  assert.notEqual(parseServiceAlerts(payload).services[0],payload.services[0]);
  assert.deepEqual(parseServiceAlerts({...payload,events:[]}).events,[]);
  for(const invalid of [null,{...payload,secret:'x'},{...payload,confirmationCount:1},
    {...payload,services:[payload.services[0],payload.services[0]]},
    {...payload,services:[{...payload.services[0],severity:'info'},payload.services[1]]},
    {...payload,services:[{...payload.services[0],lastEvidenceAtUtc:null},payload.services[1]]},
    {...payload,events:Array(481).fill(payload.events[0])},
    {...payload,events:[{...payload.events[0],kind:'unknown'}]},
    {...payload,events:[{...payload.events[0],confirmedAtUtc:'invalid'}]},
    {...payload,events:[{...payload.events[0],confirmedAtUtc:'2026-11-25T10:00:00Z'},payload.events[0]]}])
      assert.equal(parseServiceAlerts(invalid),null);
});
