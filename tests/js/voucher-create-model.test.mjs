import test from 'node:test';
import assert from 'node:assert/strict';
import { eligibleVoucherPlans } from '../../src/RadiusManager.Api/wwwroot/voucher-create-model.mjs';

test('only active unlimited lab plans can create vouchers', () => {
  const plans = [
    {id:'a',name:'1M',active:true,quotaBytes:null,validityDays:null,sharedSecret:'never-expose'},
    {id:'b',name:'10GB',active:true,quotaBytes:10737418240,validityDays:null},
    {id:'c',name:'30days',active:true,quotaBytes:null,validityDays:30},
    {id:'d',name:'Disabled',active:false,quotaBytes:null,validityDays:null},
    {id:'e',name:'2M',active:true,quotaBytes:null,validityDays:null}
  ];
  assert.deepEqual(eligibleVoucherPlans(plans),[{id:'a',name:'1M'},{id:'e',name:'2M'}]);
  assert.equal(JSON.stringify(eligibleVoucherPlans(plans)).includes('never-expose'),false);
});
test('empty, incomplete, and partially loaded plans cannot enable creation', () => {
  assert.deepEqual(eligibleVoucherPlans(null),[]);
  assert.deepEqual(eligibleVoucherPlans([{id:'a',name:'Bad',active:true,quotaBytes:undefined,validityDays:null}]),[]);
  assert.deepEqual(eligibleVoucherPlans([{id:'a',name:'Bad',active:true,quotaBytes:null,validityDays:undefined}]),[]);
  assert.deepEqual(eligibleVoucherPlans([{id:null,name:'Bad',active:true,quotaBytes:null,validityDays:null}]),[]);
  assert.deepEqual(eligibleVoucherPlans([{id:'a',name:'',active:true,quotaBytes:null,validityDays:null}]),[]);
});
