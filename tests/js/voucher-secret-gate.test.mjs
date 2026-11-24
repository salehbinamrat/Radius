import test from 'node:test';
import assert from 'node:assert/strict';
import { createOneTimeRevealGate } from '../../src/RadiusManager.Api/wwwroot/voucher-secret-gate.mjs';

test('only the latest in-flight one-time credential response is allowed',()=>{
  const gate=createOneTimeRevealGate();
  const first=gate.begin();
  assert.equal(gate.isCurrent(first),true);
  const second=gate.begin();
  assert.equal(gate.isCurrent(first),false);
  assert.equal(gate.isCurrent(second),true);
});
test('navigation/logout invalidates a pending response forever',()=>{
  const gate=createOneTimeRevealGate();
  const pending=gate.begin();
  gate.invalidate();
  assert.equal(gate.isCurrent(pending),false);
  const next=gate.begin();
  assert.equal(gate.isCurrent(next),true);
  assert.equal(gate.isCurrent(null),false);
  assert.equal(gate.isCurrent('2'),false);
  assert.equal(gate.isCurrent(-1),false);
});
