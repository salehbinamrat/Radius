import test from 'node:test';
import assert from 'node:assert/strict';
import { buildVoucherViewSnapshot } from '../../src/RadiusManager.Api/wwwroot/voucher-view-model.mjs';

test('voucher snapshot uses original filters but never exposes one-time passwords', () => {
  const source=[
    {username:'A001',planName:'باقة 1M',active:true,password:'visible-once',sessionSecret:'do-not-leak'},
    {username:'A002',planName:'باقة 2M',active:false,password:'visible-once'},
    {username:'B003',planName:'باقة 1M',active:1,privateKey:'do-not-leak'},
  ];
  const value=buildVoucherViewSnapshot(source,'a','active');
  assert.equal(value.loadedCount,3);
  assert.equal(value.visibleCount,1);
  assert.deepEqual(value.visible[0],{username:'A001',planName:'باقة 1M',active:true});
  assert.equal(JSON.stringify(value).includes('visible-once'),false);
  assert.equal(JSON.stringify(value).includes('sessionSecret'),false);
  assert.equal(JSON.stringify(value).includes('privateKey'),false);
});
test('display cap is 100 and filtering happens against loaded subset only',()=>{
  const source=Array.from({length:125},(_,i)=>({username:'n'+i,planName:'Lab',active:i%2===0,password:'hidden'}));
  const value=buildVoucherViewSnapshot(source,'','disabled');
  assert.equal(value.loadedCount,100);
  assert.equal(value.visibleCount,50);
  assert.equal(value.scope,'first-100-loaded');
  assert.equal(JSON.stringify(value).includes('hidden'),false);
});
test('empty input produces empty, not invented NAS/accounting state',()=>{
  assert.deepEqual(buildVoucherViewSnapshot(null),{loadedCount:0,visibleCount:0,visible:[],scope:'first-100-loaded'});
  const value=buildVoucherViewSnapshot([{username:'A1',planName:'a',active:false}],'bad','all');
  assert.equal(value.visibleCount,0);
  assert.equal(Object.hasOwn(value,'connectedSessions'),false);
  assert.equal(Object.hasOwn(value,'balance'),false);
});
