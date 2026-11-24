import test from 'node:test';
import assert from 'node:assert/strict';
import { buildSessionViewSnapshot } from '../../src/RadiusManager.Api/wwwroot/session-view-model.mjs';

test('session rows use real accounting fields and preserve uncertain status',()=>{
 const response=[
  {username:'LAB001',framedIp:'10.0.0.2',callingStationId:'AA:BB',nasIp:'10.1.1.1',
   classification:'open-unconfirmed',startedAt:null,updatedAt:'bad',
   uploadBytes:1048576,downloadBytes:2097152,terminateCause:null,
   password:'never-expose',secret:'hidden'},
  {username:'LAB002',framedIp:null,callingStationId:null,nasIp:null,
   classification:'stale',uploadBytes:null,downloadBytes:-1,terminateCause:'Lost-Carrier'}
 ];
 const value=buildSessionViewSnapshot(response,'lab0');
 assert.equal(value.loadedCount,2);
 assert.equal(value.visibleCount,2);
 assert.equal(value.scope,'first-100-loaded');
 assert.equal(value.visible[0].status,'مفتوحة (غير مؤكدة)');
 assert.equal(value.visible[0].classification,'open-unconfirmed');
 assert.equal(value.visible[0].transfer,'1.00 MB / 2.00 MB');
 assert.equal(value.visible[0].startedAt,'—');
 assert.equal(value.visible[0].updatedAt,'—');
 assert.equal(value.visible[1].status,'قديمة / غير مؤكدة');
 assert.equal(value.visible[1].transfer,'غير سليم / غير سليم');
 assert.equal(JSON.stringify(value).includes('never-expose'),false);
 assert.equal(JSON.stringify(value).includes('hidden'),false);
 assert.deepEqual(Object.keys(value.visible[0]).sort(),
   ['username','framedIp','callingStationId','nasIp','status',
    'classification','startedAt','updatedAt','transfer','terminateCause'].sort());
});
test('search matches only first 100 loaded records and existing case-insensitive fields',()=>{
 const records=Array.from({length:120},(_,i)=>({username:'card'+i,framedIp:'10.10.0.'+i,
   callingStationId:'MAC'+i,nasIp:'nas'+i,classification:'closed',
   uploadBytes:0,downloadBytes:0,secret:'hidden'}));
 const byIp=buildSessionViewSnapshot(records,'10.10.0.119');
 assert.equal(byIp.loadedCount,100);
 assert.equal(byIp.visibleCount,0);
 const byMac=buildSessionViewSnapshot(records,'mAc10');
 assert.equal(byMac.visibleCount,1);
 assert.equal(byMac.visible[0].username,'card10');
 assert.equal(byMac.visible[0].status,'مغلقة');
});
test('empty and unexpected classifications fail conservatively',()=>{
 assert.deepEqual(buildSessionViewSnapshot(null),{
   loadedCount:0,visibleCount:0,visible:[],scope:'first-100-loaded'
 });
 const rows=buildSessionViewSnapshot([{username:'a',classification:'online',
   uploadBytes:0,downloadBytes:0}], '');
 assert.equal(rows.visible[0].status,'غير معروف');
 assert.equal(rows.visible[0].classification,'unknown');
 assert.equal(Object.hasOwn(rows,'onlineCount'),false);
 assert.equal(JSON.stringify(rows).includes('متصل الآن'),false);
});
