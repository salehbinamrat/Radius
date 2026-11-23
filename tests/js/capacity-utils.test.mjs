import test from 'node:test';
import assert from 'node:assert/strict';
import { estimateCapacity } from '../../src/RadiusManager.Api/wwwroot/capacity-utils.mjs';

test('calculates peak users and upstream capacity with explicit assumptions', () => {
  const result = estimateCapacity({users:800,averageMbps:6,peakConcurrencyPercent:45,contentionRatio:8,dailyPeakEquivalentHours:6});
  assert.equal(result.peakUsers, 360);
  assert.equal(result.upstreamMbps, 270);
  assert.equal(result.monthlyDecimalTb, 21.87);
});
test('rejects invalid and nonfinite inputs instead of silently guessing', () => {
  for (const value of [0, -1, NaN, Infinity, 'invalid']) {
    assert.throws(() => estimateCapacity({users:value,averageMbps:6,peakConcurrencyPercent:45,contentionRatio:8,dailyPeakEquivalentHours:6}));
  }
  assert.throws(() => estimateCapacity({users:100,averageMbps:10,peakConcurrencyPercent:110,contentionRatio:5,dailyPeakEquivalentHours:6}));
  assert.throws(() => estimateCapacity({users:100,averageMbps:10,peakConcurrencyPercent:50,contentionRatio:0,dailyPeakEquivalentHours:6}));
  assert.throws(() => estimateCapacity({users:100,averageMbps:10,peakConcurrencyPercent:50,contentionRatio:5,dailyPeakEquivalentHours:30}));
});
test('does not change configuration or persist results', () => {
  const options={users:100,averageMbps:2,peakConcurrencyPercent:20,contentionRatio:4,dailyPeakEquivalentHours:5};
  const old={...options};
  const result=estimateCapacity(options);
  assert.deepEqual(options,old);
  assert.equal(result.peakUsers,20);
  assert.equal(result.upstreamMbps,10);
  assert.equal(result.monthlyDecimalTb,0.675);
});
