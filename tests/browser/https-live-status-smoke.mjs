import { chromium } from '@playwright/test';
import assert from 'node:assert/strict';

const origin = 'https://localhost:18443';
if (process.env.CI !== 'true' || process.env.LAB_HTTPS_TEST_ACK !== 'isolated-ci')
  throw new Error('Disposable HTTPS browser CI acknowledgement required');
const username = process.env.LAB_ADMIN_USER;
const password = process.env.LAB_ADMIN_PASSWORD_NEXT;
if (!username || !password) throw new Error('Missing isolated admin fixture credentials');

let browser;
try {
  browser = await chromium.launch({ headless: true });
  // Only the ephemeral, self-signed localhost CI certificate is exempt here.
  // The separate wire fixture verifies the certificate cryptographically.
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin !== origin) return route.abort();
    return route.continue();
  });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  const sockets = [];
  page.on('websocket', socket => {
    if (socket.url().startsWith('wss://localhost:18443/hubs/lab-status')) {
      const item = { closed: false };
      sockets.push(item);
      socket.on('close', () => { item.closed = true; });
    }
  });
  await page.goto(origin, { waitUntil: 'domcontentloaded' });
  await page.locator('#sessionLoginUser').fill(username);
  await page.locator('#sessionLoginPass').fill(password);
  await page.locator('#reactAdminLogin button[type=submit]').click();
  const live = page.locator('#reactLiveStatus [data-live-status="live"]');
  await live.waitFor({ state: 'visible', timeout: 25000 });
  const latency = await live.locator('[data-session-check-ms]').getAttribute('data-session-check-ms');
  assert.ok(latency !== null && Number.isFinite(Number(latency)) && Number(latency) >= 0
    && Number(latency) <= 10000, 'Invalid displayed server duration');
  assert.ok(sockets.length > 0, 'Missing real browser WebSocket');
  await page.locator('[data-view="plans"]').click();
  await page.waitForFunction(() => document.querySelector('#reactLiveStatus')?.childElementCount === 0);
  // Transport must be disposed on navigation; the UI cannot merely hide it.
  for (let i = 0; i < 50 && sockets.some(s => !s.closed); i++)
    await new Promise(resolve => setTimeout(resolve, 100));
  assert.ok(sockets.every(s => s.closed), 'WebSocket remained after navigation');
  await page.locator('[data-view="overview"]').click();
  await live.waitFor({ state: 'visible', timeout: 25000 });
  const count = sockets.length;
  assert.ok(count >= 2, 'Missing new connection on overview return');
  await page.locator('#logout').click();
  await page.locator('#loginPanel').waitFor({ state: 'visible' });
  await page.waitForFunction(() => document.querySelector('#reactLiveStatus')?.childElementCount === 0);
  for (let i = 0; i < 50 && sockets.some(s => !s.closed); i++)
    await new Promise(resolve => setTimeout(resolve, 100));
  assert.ok(sockets.every(s => s.closed), 'WebSocket remained after logout');
  const denied = await context.request.get(origin + '/api/summary');
  assert.equal(denied.status(), 401, 'Browser session still accepted after logout');
  console.log('HTTPS Chromium live status, navigation disposal, reconnect and logout PASS');
} catch (error) {
  // Playwright errors can include entered credentials or URLs. Never dump them.
  console.error('HTTPS Chromium live status failed (' + error.name + ')');
  process.exitCode = 1;
} finally {
  await browser?.close();
}
