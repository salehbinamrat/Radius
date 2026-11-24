import test from 'node:test';
import assert from 'node:assert/strict';
import { createRefreshCoordinator } from '../../src/RadiusManager.Api/wwwroot/refresh-coordinator.mjs';
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes,no) => { resolve=yes; reject=no; });
  return { promise, resolve, reject };
}
test('concurrent refresh callers share actual in-flight result; no completed cache', async () => {
  const c=createRefreshCoordinator();
  const gate=deferred();
  let count=0;
  const first=c.run(async()=>{count++;return gate.promise;});
  const second=c.run(()=>{throw new Error('duplicate read');});
  assert.equal(first,second);
  gate.resolve('snapshot');
  assert.equal(await second,'snapshot');
  assert.equal(count,1);
  assert.equal(await c.run(()=>{count++;return 'new';}),'new');
  assert.equal(count,2);
});
test('fresh read supersedes pre-mutation result and cannot clear newer operation', async () => {
  const c=createRefreshCoordinator();
  const old=deferred(), next=deferred();
  let oldSignal;
  const first=c.run(async({signal,isCurrent})=>{
    oldSignal=signal; await old.promise;
    assert.equal(isCurrent(),false);
    throw new DOMException('stale','AbortError');
  });
  await Promise.resolve();
  const current=c.run(()=>next.promise,{fresh:true});
  assert.equal(oldSignal.aborted,true);
  old.resolve();
  await assert.rejects(first,{name:'AbortError'});
  assert.equal(c.run(()=>{throw Error('duplicate');}),current);
  next.resolve('updated');
  assert.equal(await current,'updated');
});
test('logout invalidates generation and aborts outstanding read', async()=>{
  const c=createRefreshCoordinator();
  let context;
  const gate=deferred();
  const old=c.run(async args=>{context=args;await gate.promise;return args.isCurrent();});
  await Promise.resolve();
  c.invalidate();
  assert.equal(context.signal.aborted,true);
  assert.equal(await c.run(()=>42),42);
  gate.resolve();
  assert.equal(await old,false);
});
test('deadline aborts cooperative network request and permits retry', async()=>{
  const c=createRefreshCoordinator(10);
  await assert.rejects(c.run(({signal})=>new Promise((_,reject)=>{
    signal.addEventListener('abort',()=>reject(new DOMException('timeout','AbortError')),{once:true});
  })),{name:'AbortError'});
  assert.equal(await c.run(()=>true),true);
});
test('failed read aborts remaining sibling requests and does not cache failure',async()=>{
  const c=createRefreshCoordinator();
  let signal;
  await assert.rejects(c.run(args=>{signal=args.signal;throw new Error('read failed');}),/read failed/);
  assert.equal(signal.aborted,true);
  assert.equal(await c.run(()=>1),1);
});
