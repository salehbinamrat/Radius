import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizedPlan, rateLimit } from '../../src/RadiusManager.Api/wwwroot/plan-utils.mjs';
test('rate formatting respects upload/download order',()=>assert.equal(rateLimit(256,1024),'256k/1024k'));
test('valid plan with nullable quotas',()=>assert.deepEqual(normalizedPlan(' 1M ',1024,256,'',''),{name:'1M',downloadKbps:1024,uploadKbps:256,quotaMb:null,validityDays:null}));
test('rejects negative quota',()=>assert.throws(()=>normalizedPlan('A',1024,256,-5,30)));
test('rejects truncated speeds',()=>assert.throws(()=>normalizedPlan('A','abc',256,'','')));
test('rejects empty name',()=>assert.throws(()=>normalizedPlan('  ',1024,256,'','')));
test('rejects huge quota',()=>assert.throws(()=>normalizedPlan('A',1024,256,100000001,30)));
