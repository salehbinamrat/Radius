import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPlanViewSnapshot } from '../../src/RadiusManager.Api/wwwroot/plan-view-model.mjs';

test('plan view uses existing Arabic search filtering and exactly loaded records', () => {
  const inputs=[
    {id:'first',name:' باقة 1M ',downloadKbps:1024,uploadKbps:256,quotaBytes:null,validityDays:null,active:true, password:'hidden'},
    {id:'second',name:'باقة 3M',downloadKbps:3072,uploadKbps:512,quotaBytes:10485760,validityDays:30,active:false},
  ];
  const result=buildPlanViewSnapshot(inputs,'1m');
  assert.equal(result.loadedCount,2);
  assert.equal(result.visibleCount,1);
  assert.deepEqual(result.visible.map(p=>[p.id,p.name,p.downloadText,p.uploadText,p.active]),
    [['first',' باقة 1M ','1 Mbps','256 Kbps',true]]);
  assert.equal(result.visible[0].quotaBytes,null);
  assert.equal(JSON.stringify(result).includes('hidden'),false);
  assert.deepEqual(Object.keys(result.visible[0]).sort(),
    ['active','downloadKbps','downloadText','id','name','quotaBytes','uploadKbps','uploadText','validityDays'].sort());
});
test('empty/unknown values do not fabricate plan counts or leak plan records', () => {
  assert.deepEqual(buildPlanViewSnapshot(null,''),{loadedCount:0,visibleCount:0,visible:[],scope:'first-100-loaded'});
  const accounts=Array.from({length:110},(_,i)=>({
    id:'id-'+i,name:'Plan'+i,downloadKbps:1024,uploadKbps:256,
    active:true,quotaBytes:null,validityDays:null,secret:'never'
  }));
  const result=buildPlanViewSnapshot(accounts,'');
  assert.equal(result.loadedCount,100);
  assert.equal(result.visibleCount,100);
  assert.equal(result.scope,'first-100-loaded');
  assert.equal(JSON.stringify(result).includes('never'),false);
});
test('plan view is read-only and does not invent backend or live router status',()=>{
  const result=buildPlanViewSnapshot([{id:'x',name:'X',downloadKbps:900,uploadKbps:100,active:false,quotaBytes:null,validityDays:null}], 'nomatch');
  assert.equal(result.visibleCount,0);
  assert.equal(result.loadedCount,1);
  assert.equal(Object.hasOwn(result,'nasConnected'),false);
  assert.equal(Object.hasOwn(result,'radcheck'),false);
});
