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
  '/api/admin/auth/me', '/api/admin/auth/logout', '/api/summary', '/api/plans', '/api/lab-accounts', '/api/service-status/history', '/api/service-status/alerts']);
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
  step('navigate away');
  await page.locator('[data-view="plans"]').click();
  await page.waitForFunction(() => document.querySelector('#reactLiveStatus')?.childElementCount === 0
    && document.querySelector('#reactServiceHistory')?.childElementCount === 0
    && document.querySelector('#reactServiceAlerts')?.childElementCount === 0);
  for (let i = 0; i < 50 && sockets.some(s => !s.closed); i++)
    await new Promise(resolve => setTimeout(resolve, 100));
  assert.ok(sockets.every(s => s.closed), 'WebSocket remained after navigation');
  step('navigate back');
  await page.locator('[data-view="overview"]').click();
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
  console.log('HTTPS Chromium live status, navigation disposal, reconnect and logout PASS');
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
