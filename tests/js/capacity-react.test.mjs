import test from 'node:test';
import assert from 'node:assert/strict';
import { estimateCapacity } from '../../src/RadiusManager.Api/wwwroot/capacity-utils.mjs';

const inputs={users:800,averageMbps:6,peakConcurrencyPercent:45,contentionRatio:8,dailyPeakEquivalentHours:6};
test('React capacity form defaults use the existing pure engine without rounding drift',()=>{
  assert.deepEqual(estimateCapacity({...inputs}),{peakUsers:360,upstreamMbps:270,monthlyDecimalTb:21.87});
  const updated=estimateCapacity({...inputs,users:900,peakConcurrencyPercent:50});
  assert.equal(updated.peakUsers,450);
  assert.equal(updated.upstreamMbps,337.5);
  assert.equal(updated.monthlyDecimalTb,27.338);
});
test('capacity planner rejects blank/invalid inputs rather than showing fabricated data',()=>{
  for(const item of ['', ' ', '-1', 'Infinity', 'NaN','bad']){
    assert.throws(()=>estimateCapacity({...inputs,users:Number(item)}));
  }
  assert.throws(()=>estimateCapacity({...inputs,averageMbps:Number('')}));
  assert.throws(()=>estimateCapacity({...inputs,peakConcurrencyPercent:101}));
  assert.throws(()=>estimateCapacity({...inputs,contentionRatio:0}));
  assert.throws(()=>estimateCapacity({...inputs,dailyPeakEquivalentHours:25}));
});
test('estimating never changes the caller input object',()=>{
  const clone={...inputs};
  estimateCapacity(inputs);
  assert.deepEqual(inputs,clone);
});
