import test from 'node:test';
import assert from 'node:assert/strict';
import { buildUsageViewSnapshot } from '../../src/RadiusManager.Api/wwwroot/usage-view-model.mjs';

test('usage report reflects only authorized lab accounting counters', () => {
  const result = buildUsageViewSnapshot('LAB001', {
    totalBytes: 1572864, downloadBytes: 1048576, uploadBytes: 524288,
    sessions: 4, openSessions: 1, staleSessions: 2, anomalousSessions: 1,
    observedNas: 2, reportIsFinal: false, warning: 'البيانات استرشادية',
    password: 'must-never-cross-to-react', sharedSecret: 'sensitive', radcheck: {value: 'hidden'},
  });
  assert.deepEqual(result, {
    username: 'LAB001', total: '1.5 MB', download: '1 MB', upload: '512 KB',
    sessions: '4', openSessions: '1', staleSessions: '2', anomalousSessions: '1',
    observedNas: '2', finality: 'غير نهائي', warning: 'البيانات استرشادية',
    scope: 'lab-accounting-estimate',
  });
  assert.equal(JSON.stringify(result).includes('must-never-cross-to-react'), false);
  assert.equal(JSON.stringify(result).includes('sharedSecret'), false);
  assert.equal(JSON.stringify(result).includes('radcheck'), false);
});
test('unknown/invalid counters are not coerced to fabricated zeros', () => {
  const data = buildUsageViewSnapshot('LAB002', { totalBytes: null, sessions: null,
    openSessions: -2, staleSessions: 'invalid', anomalousSessions: 2.5,
    observedNas: '9', reportIsFinal: 'true', warning: '' });
  assert.equal(data.total, '—');
  assert.equal(data.download, '—');
  assert.equal(data.sessions, '—');
  assert.equal(data.openSessions, '—');
  assert.equal(data.staleSessions, '—');
  assert.equal(data.anomalousSessions, '—');
  assert.equal(data.observedNas, '9');
  assert.equal(data.finality, 'غير نهائي');
  assert.match(data.warning, /استرشادية/);
});
test('a formally closed report is not described as final billing', () => {
  const data = buildUsageViewSnapshot('LAB003', { totalBytes: 0,
    downloadBytes: 0, uploadBytes: 0, sessions: 0, openSessions: 0,
    staleSessions: 0, anomalousSessions: 0, observedNas: 0, reportIsFinal: true });
  assert.equal(data.finality, 'مغلق شكليا');
  assert.equal(data.total, '0 B');
});
test('invalid usernames and untrusted responses fail closed', () => {
  assert.throws(() => buildUsageViewSnapshot('', { totalBytes: 1 }));
  assert.throws(() => buildUsageViewSnapshot('LAB1', null));
  assert.throws(() => buildUsageViewSnapshot('LAB1', []));
});
