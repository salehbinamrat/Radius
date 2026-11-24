import { test, expect } from '@playwright/test';

// DOM visibility changes below are for a *public UI rendering test only*.
// They are not authentication: the protected backend must continue returning 401.
async function showCapacityWithoutAuth(page) {
  await page.evaluate(() => {
    const dashboard = document.getElementById('dashboard');
    const login = document.getElementById('loginPanel');
    if (!dashboard || !login) throw new Error('Missing original dashboard shell');
    login.hidden = true;
    dashboard.hidden = false;
    for (const section of document.querySelectorAll('[data-page]'))
      section.hidden = section.id !== 'view-capacity';
  });
}

test('unauthenticated shell loads local React assets and protected API remains denied', async ({ page, request }) => {
  const pageErrors = [];
  page.on('pageerror', err => pageErrors.push(err.message));
  const response = await page.goto('/', { waitUntil: 'domcontentloaded' });
  expect(response?.status()).toBe(200);
  await expect(page.locator('#loginPanel')).toBeVisible();
  await expect(page.locator('#dashboard')).toBeHidden();
  await expect(page.locator('#reactCapacityCalculator #capForm')).toHaveCount(1);
  await expect(page.locator('#reactPlanEditor #planForm')).toHaveCount(1);
  await expect(page.locator('#reactVoucherCreator #labForm')).toHaveCount(1);
  await expect(page.locator('#labCredentials')).toBeHidden();
  const denied = await request.get('/api/plans');
  expect(denied.status()).toBe(401);
  expect(pageErrors).toEqual([]);
});

test('React 19 capacity planner computes locally and rejects invalid values', async ({ page, request }) => {
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await expect(page.locator('#reactCapacityCalculator #capForm')).toHaveCount(1);
  await showCapacityWithoutAuth(page);

  await expect(page.locator('#capPeakOut')).toHaveText('360');
  await expect(page.locator('#capSpeedOut')).toHaveText('270 Mbps');
  await expect(page.locator('#capVolumeOut')).toHaveText('21.87 TB');

  await page.locator('#capUsers').fill('900');
  await expect(page.locator('#capPeakOut')).toHaveText('405');
  await expect(page.locator('#capSpeedOut')).toHaveText('303.75 Mbps');

  await page.locator('#capUsers').fill('0');
  await expect(page.locator('#capError')).not.toBeEmpty();
  await expect(page.locator('#capResults')).toBeHidden();
  expect((await request.get('/api/lab-accounts')).status()).toBe(401);
});

test('small mobile viewport keeps the login and offline planner usable', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'مرحبا بعودتك' })).toBeVisible();
  await expect(page.locator('#reactCapacityCalculator #capForm')).toHaveCount(1);
  await showCapacityWithoutAuth(page);
  await expect(page.locator('#capUsers')).toBeVisible();
  await page.locator('#capConcurrency').fill('50');
  await expect(page.locator('#capPeakOut')).toHaveText('400');
  await expect(page.locator('#capResults')).toBeVisible();
});
