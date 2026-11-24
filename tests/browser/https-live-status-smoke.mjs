import { chromium } from '@playwright/test';
import assert from 'node:assert/strict';

const origin = 'https://localhost:18443';
if (process.env.CI !== 'true' || process.env.LAB_HTTPS_TEST_ACK !== 'isolated-ci')
  throw new Error('Disposable HTTPS browser CI acknowledgement required');
const username = process.env.LAB_ADMIN_USER;
const password = process.env.LAB_ADMIN_PASSWORD_NEXT;
if (!username || !password) throw new Error('Missing isolated admin fixture credentials');

let browser, page;
let stage = 'launch';
const sockets = [];
const statuses = [];
let pageErrors = 0, cspErrors = 0, failedRequests = 0;
const allowedPaths = new Set(['/', '/modern/noc-react.mjs', '/app.mjs',
  '/api/admin/auth/mode', '/api/admin/auth/csrf', '/api/admin/auth/login',
  '/api/admin/auth/me', '/api/admin/auth/logout', '/api/summary', '/api/plans', '/api/lab-accounts', '/api/service-status/history', '/api/service-status/alerts', '/api/service-status/incidents', '/api/ownership/resellers', '/api/ownership/accounts', '/api/ownership/accounts/lab_0000000000e1/assign',
  '/api/ownership/accounts/lab_0000000000e1/history', '/api/ownership/accounts/lab_0000000000e1/transfer',
  '/api/admin-audit', '/api/reseller/accounts']);
const step = name => { stage = name; console.log('HTTPS Chromium step: ' + name); };
try {
  browser = await chromium.launch({ headless: true,
    args: ['--host-resolver-rules=MAP localhost 127.0.0.1'] });
  // Only the ephemeral self-signed localhost CI certificate is exempt.
  // The independent wire fixture performs verified TLS.
  const context = await browser.newContext({ ignoreHTTPSErrors: true,
    viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' });
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin !== origin) return route.abort();
    return route.continue();
  });
  page = await context.newPage();
  page.setDefaultTimeout(15000);
  page.on('pageerror', () => { pageErrors++; });
  page.on('requestfailed', () => { failedRequests++; });
  page.on('console', msg => {
    if (msg.type() === 'error' && /content security policy/i.test(msg.text())) cspErrors++;
  });
  page.on('response', response => {
    const url = new URL(response.url());
    if (url.origin === origin && allowedPaths.has(url.pathname))
      statuses.push([response.request().method(), url.pathname, response.status()]);
  });
  page.on('websocket', socket => {
    if (socket.url().startsWith('wss://localhost:18443/hubs/lab-status')) {
      const item = { closed: false, errors: 0 };
      sockets.push(item);
      socket.on('close', () => { item.closed = true; });
      socket.on('socketerror', () => { item.errors++; });
    }
  });
  step('load');
  const loaded = await page.goto(origin + '/', { waitUntil: 'domcontentloaded' });
  assert.equal(loaded?.status(), 200, 'Document not served');
  step('session form ready');
  await page.locator('#sessionLoginUser').waitFor({ state: 'visible' });
  await page.locator('#sessionLoginUser').fill(username);
  await page.locator('#sessionLoginPass').fill(password);
  step('submit login');
  const loginResponse = page.waitForResponse(r => r.url() === origin + '/api/admin/auth/login'
    && r.request().method() === 'POST');
  await page.locator('#reactAdminLogin button[type=submit]').click();
  assert.equal((await loginResponse).status(), 200, 'Browser login rejected');
  step('dashboard ready');
  await page.locator('#dashboard').waitFor({ state: 'visible' });
  step('live status');
  const live = page.locator('#reactLiveStatus [data-live-status="live"]');
  await live.waitFor({ state: 'visible', timeout: 25000 });
  const latency = await live.locator('[data-session-check-ms]').getAttribute('data-session-check-ms');
  assert.ok(latency !== null && Number.isFinite(Number(latency)) && Number(latency) >= 0
    && Number(latency) <= 10000, 'Invalid displayed server duration');
  assert.equal(await live.locator('[data-radius-state]').getAttribute('data-radius-state'), 'unknown',
    'HTTPS fixture without a RADIUS mount must not claim availability');
  assert.ok(sockets.length > 0, 'Missing real browser WebSocket');
  step('service history');
  const history = page.locator('#reactServiceHistory [data-history-status="ready"]');
  await history.waitFor({ state: 'visible', timeout: 25000 });
  const sampleCount = Number(await history.getAttribute('data-history-count'));
  assert.ok(sampleCount > 0 && sampleCount <= 240, 'Expected real service history samples');
  assert.ok(await history.locator('tbody tr').count() > 0, 'History table not rendered');
  assert.ok(await history.locator('svg.history-chart').count() === 1, 'History chart absent');
  step('service alerts');
  const alerts = page.locator('#reactServiceAlerts [data-alert-status="ready"]');
  await alerts.waitFor({ state: 'visible', timeout: 25000 });
  assert.equal(await alerts.locator('[data-alert-service]').count(), 2, 'Missing service cards');
  assert.equal(await alerts.locator('[data-alert-service="freeradius"]').getAttribute('data-alert-state'), 'unknown',
    'No RADIUS evidence in isolated HTTPS fixture');
  assert.ok(['pending','healthy'].includes(await alerts.locator('[data-alert-service="postgresql"]').getAttribute('data-alert-state')),
    'Unexpected PostgreSQL state in healthy fixture');
  assert.equal(await alerts.locator('[data-incident-retention]').getAttribute('data-incident-retention'), 'volume-snapshot');
  await alerts.locator('select').selectOption('open');
  await alerts.locator('[data-incidents-empty]').waitFor({state:'visible'});
  await alerts.locator('select').selectOption('all');
  step('navigate away');
  await page.locator('[data-view="plans"]').click();
  await page.waitForFunction(() => document.querySelector('#reactLiveStatus')?.childElementCount === 0
    && document.querySelector('#reactServiceHistory')?.childElementCount === 0
    && document.querySelector('#reactServiceAlerts')?.childElementCount === 0);
  for (let i = 0; i < 50 && sockets.some(s => !s.closed); i++)
    await new Promise(resolve => setTimeout(resolve, 100));
  assert.ok(sockets.every(s => s.closed), 'WebSocket remained after navigation');
  step('ownership assignment');
  await page.locator('[data-view="vouchers"]').click();
  const ownership=page.locator('#reactOwnership [data-ownership-state="ready"]');
  await ownership.waitFor({state:'visible',timeout:20000});
  await ownership.locator('#ownershipCard').selectOption('lab_0000000000e1');
  await ownership.locator('#ownershipReseller').selectOption('ci-owner-a');
  assert.equal(await ownership.locator('option[value="lab_0000000000f1"]').count(),0);
  page.once('dialog',dialog=>dialog.accept());
  const assigned=page.waitForResponse(r=>r.url()===origin+'/api/ownership/accounts/lab_0000000000e1/assign'&&r.request().method()==='POST');
  await ownership.locator('#ownershipAssign').click();
  assert.equal((await assigned).status(),200);
  await page.waitForFunction(()=>document.querySelector('[data-ownership-result]')?.textContent?.includes('تم إسناد الكرت بنجاح'));
  await ownership.waitFor({state:'visible'});
  assert.equal(await ownership.locator('option[value="lab_0000000000e1"]').count(),0);
  step('ownership transfer and history');
  await page.locator('#transferCard').fill('lab_0000000000e1');
  await page.locator('#transferLookup').click();
  await page.locator('[data-transfer-owner="ci-owner-a"]').waitFor({state:'visible'});
  for(const target of ['ci-owner-b','ci-owner-a']){
    await page.locator('#transferTarget').selectOption(target);
    page.once('dialog',dialog=>dialog.accept());
    const transfer=page.waitForResponse(r=>r.url()===origin+'/api/ownership/accounts/lab_0000000000e1/transfer'&&r.request().method()==='POST');
    await page.locator('#transferSubmit').click();
    assert.equal((await transfer).status(),200);
    await page.locator('[data-transfer-owner="'+target+'"]').waitFor({state:'visible'});
  }
  assert.equal(await page.locator('[data-transfer-event]').count(),2);
  assert.ok((await page.locator('[data-transfer-result]').textContent()).includes('تم نقل الملكية بنجاح'));
  step('audit read and filters');
  await page.locator('#auditNav').click();
  await page.locator('#reactAuditLog [data-audit-state="ready"]').waitFor({state:'visible'});
  await page.locator('#auditAction').selectOption('voucher_owner_transferred');
  await page.locator('#auditOutcome').selectOption('success');
  await page.locator('#auditApply').click();
  await page.waitForFunction(()=>document.querySelectorAll('[data-audit-action]').length>0
    && [...document.querySelectorAll('[data-audit-action]')].every(r=>r.getAttribute('data-audit-action')==='voucher_owner_transferred'));
  step('navigate back');
  await page.locator('[data-view="overview"]').click();
  await page.waitForFunction(()=>document.querySelector('#reactOwnership')?.childElementCount===0
    && document.querySelector('#reactAuditLog')?.childElementCount===0);
  await live.waitFor({ state: 'visible', timeout: 25000 });
  assert.ok(sockets.length >= 2, 'Missing new connection on overview return');
  await history.waitFor({ state: 'visible', timeout: 25000 });
  await alerts.waitFor({ state: 'visible', timeout: 25000 });
  step('logout');
  await page.locator('#logout').click();
  await page.locator('#loginPanel').waitFor({ state: 'visible' });
  await page.waitForFunction(() => document.querySelector('#reactLiveStatus')?.childElementCount === 0
    && document.querySelector('#reactServiceHistory')?.childElementCount === 0
    && document.querySelector('#reactServiceAlerts')?.childElementCount === 0);
  for (let i = 0; i < 50 && sockets.some(s => !s.closed); i++)
    await new Promise(resolve => setTimeout(resolve, 100));
  assert.ok(sockets.every(s => s.closed), 'WebSocket remained after logout');
  step('verify revoked session');
  const denied = await context.request.get(origin + '/api/summary');
  assert.equal(denied.status(), 401, 'Browser session still accepted after logout');
  assert.equal((await context.request.get(origin + '/api/service-status/alerts')).status(), 401,
    'Alert endpoint accepted revoked session');
  assert.equal((await context.request.get(origin + '/api/service-status/incidents')).status(), 401,
    'Incident endpoint accepted revoked session');
  console.log('HTTPS Chromium live status, navigation disposal, reconnect and logout PASS');
  step('reseller workspace');
  // Reuse the same browser context after server logout: no previous-owner data
  // must carry over into either reseller session.
  const resellerRequests=[];
  page.on('request', request=>{
    const url=new URL(request.url());
    if(url.origin===origin&&(url.pathname.startsWith('/api/')||url.pathname.startsWith('/hubs/')))
      resellerRequests.push(url.pathname);
  });
  const socketBaseline=sockets.length;
  async function resellerLogin(name){
    await page.locator('#sessionLoginUser').fill(name);
    await page.locator('#sessionLoginPass').fill(password);
    await page.locator('#reactAdminLogin button[type=submit]').click();
    await page.locator('#resellerWorkspace').waitFor({state:'visible'});
    await page.locator('#reactResellerWorkspace [data-reseller-status="ready"]').waitFor({state:'visible'});
    assert.equal(await page.locator('#dashboard').isVisible(),false);
  }
  const visibleCards=()=>page.locator('#reactResellerWorkspace [data-reseller-card]').evaluateAll(rows=>rows.map(row=>row.getAttribute('data-reseller-card')));
  step('reseller A login and owner scope');
  await resellerLogin('ci_owner_a');
  let own=await visibleCards();
  assert.ok(own.includes('lab_0000000000a1')&&own.includes('lab_0000000000e1')&&!own.includes('lab_0000000000b1'));
  step('reseller A search');
  await page.locator('#resellerSearch').fill('lab_0000000000e1');
  await page.waitForFunction(()=>{const rows=document.querySelectorAll('#reactResellerWorkspace [data-reseller-card]');
    return rows.length===1&&rows[0].getAttribute('data-reseller-card')==='lab_0000000000e1';});
  assert.deepEqual(await visibleCards(),['lab_0000000000e1']);
  step('reseller A reload');
  await page.reload({waitUntil:'domcontentloaded'});
  await page.locator('#resellerWorkspace').waitFor({state:'visible'});
  await page.locator('#reactResellerWorkspace [data-reseller-status="ready"]').waitFor({state:'visible'});
  assert.ok((await visibleCards()).includes('lab_0000000000a1'));
  step('reseller A logout and revoked access');
  await page.locator('#resellerLogout').click();
  await page.locator('#loginPanel').waitFor({state:'visible'});
  await page.waitForFunction(()=>document.querySelector('#reactResellerWorkspace')?.childElementCount===0);
  const resellerDenied=await context.request.get(origin+'/api/reseller/accounts');
  statuses.push(['GET','/api/reseller/accounts',resellerDenied.status()]);
  assert.equal(resellerDenied.status(),401);
  step('reseller B login and owner scope');
  await resellerLogin('ci_owner_b');
  own=await visibleCards();
  assert.ok(own.includes('lab_0000000000b1')&&!own.includes('lab_0000000000a1')&&!own.includes('lab_0000000000e1'));
  await page.locator('#resellerLogout').click();
  await page.locator('#loginPanel').waitFor({state:'visible'});
  await page.waitForFunction(()=>document.querySelector('#reactResellerWorkspace')?.childElementCount===0);
  step('reseller request and socket isolation');
  const permitted=new Set(['/api/health/live','/api/admin/auth/mode','/api/admin/auth/csrf',
    '/api/admin/auth/me','/api/admin/auth/login','/api/admin/auth/logout','/api/reseller/accounts']);
  assert.ok(resellerRequests.includes('/api/reseller/accounts')&&resellerRequests.every(path=>permitted.has(path)),
    'Reseller workspace requested shared data');
  assert.equal(sockets.length,socketBaseline,'Reseller opened a shared status socket');
  console.log('HTTPS Chromium two isolated reseller workspaces, reload, filter and logout PASS');
} catch (error) {
  // Only fixed stage names, allowlisted HTTP status metadata and booleans.
  // Never print Playwright messages, DOM text, URLs with query strings, credentials or frames.
  let dom = null;
  if (page) {
    try {
      dom = await page.evaluate(() => ({
        loginVisible: document.getElementById('loginPanel')?.hidden === false,
        dashboardVisible: document.getElementById('dashboard')?.hidden === false,
        formMounted: !!document.getElementById('sessionLoginUser'),
        legacyHidden: document.getElementById('loginForm')?.hidden === true,
        loginError: Boolean(document.querySelector('#reactAdminLogin .form-error')?.textContent),
        hostError: Boolean(document.getElementById('loginError')?.textContent),
        liveState: ['connecting', 'live', 'stale', 'unavailable'].find(state =>
          document.querySelector('#reactLiveStatus [data-live-status="' + state + '"]')),
      }));
    } catch { /* Diagnostics must not replace the actual failure. */ }
  }
  console.error('HTTPS Chromium live status failed', JSON.stringify({
    stage, errorType: error.name, statuses, dom, pageErrors, cspErrors, failedRequests, sockets,
  }));
  process.exitCode = 1;
} finally {
  await browser?.close();
}
