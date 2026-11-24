import { normalizedPlan } from './plan-utils.mjs';
import { buildOverviewSnapshot } from './overview-model.mjs';
import { buildUsageViewSnapshot } from './usage-view-model.mjs';
import { buildPlanViewSnapshot } from './plan-view-model.mjs';
import { buildVoucherViewSnapshot } from './voucher-view-model.mjs';
import { eligibleVoucherPlans } from './voucher-create-model.mjs';
import { createOneTimeRevealGate } from './voucher-secret-gate.mjs';
import { initializeNocUi } from './noc-ui.mjs';
import { initializeUltraFeatures } from './ultra-features.mjs';
import { initializeNasDrafts } from './nas-drafts.mjs';

const el = id => document.getElementById(id);
let auth = '';
let sessionMode = false;
let sessionCsrf = '';
let planHealth = 'unloaded';
let voucherHealth = 'unloaded';
const voucherSecretGate = createOneTimeRevealGate();
let plans = [];
let accounts = [];
let overviewSnapshot = null;
let overviewHealth = 'unloaded';
let usageGeneration = 0;
let usageDisplay = { kind: 'unloaded' };
let pendingRequest = false;
let toastTimeout = null;
let noc = null;
let ultra = null;
let nasDrafts = null;
const viewLabels = { overview: 'الرئيسية', plans: 'إدارة الباقات', vouchers: 'كروت المختبر', accounting: 'مراجعة الاستهلاك', sessions: 'سجلات الجلسات', capacity: 'تخطيط السعة', networks: 'الشبكات وNAS', roadmap: 'الرصيد الموحد' };

function setError(id, message = '') { el(id).textContent = message; }
function toast(message, type = '') {
  const layer = el('toastLayer');
  layer.replaceChildren();
  const box = document.createElement('div');
  box.className = `toast ${type}`.trim();
  box.textContent = message;
  layer.append(box);
  if (toastTimeout !== null) clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => { if (box.parentElement === layer) box.remove(); }, 4500);
}
function loading(button, isLoading) {
  if (!button) return;
  button.disabled = isLoading;
  button.setAttribute('aria-busy', String(isLoading));
}
function publishUsage(next = usageDisplay) {
  usageDisplay = next;
  window.dispatchEvent(new CustomEvent('radius-usage-updated', { detail: next }));
}
window.addEventListener('radius-usage-request', () => publishUsage());
function resetUsage() {
  // Invalidate requests started for another card, page or login.
  usageGeneration += 1;
  loading(el('loadUsage'), false);
  publishUsage({ kind: 'unloaded' });
}
function isCurrentUsage(generation, username) {
  return generation === usageGeneration && !el('dashboard').hidden &&
    !el('view-accounting').hidden && el('usageAccount').value === username;
}
function clearCredentials() {
  voucherSecretGate.invalidate();
  const secret = el('labCredentials');
  if (secret) { secret.textContent = ''; secret.hidden = true; }
  window.dispatchEvent(new Event('radius-voucher-creator-clear'));
}
function closeMenu() {
  el('sidebar').classList.remove('is-open');
  el('mobileBackdrop').hidden = true;
  el('menuToggle').setAttribute('aria-expanded', 'false');
}
function switchView(view, focusId = '') {
  if (!Object.hasOwn(viewLabels, view)) return;
  for (const section of document.querySelectorAll('[data-page]')) section.hidden = section.dataset.page !== view;
  for (const button of document.querySelectorAll('[data-view]')) {
    const current = button.dataset.view === view;
    button.classList.toggle('is-active', current);
    if (current) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  }
  el('breadcrumbCurrent').textContent = viewLabels[view];
  el('pageError').hidden = true;
  if (view !== 'vouchers') clearCredentials();
  if (view !== 'accounting') resetUsage();
  window.dispatchEvent(new CustomEvent('radius-view-changed', { detail: { view } }));
  if (view === 'networks' && !el('dashboard').hidden) nasDrafts?.refresh(); // one-time password must not linger across navigation
  closeMenu();
  noc?.onViewChanged();
  window.scrollTo({ top: 0, behavior: 'smooth' });
  if (focusId) requestAnimationFrame(() => el(focusId)?.focus());
}
function encodeAuth(user, pass) {
  const bytes = new TextEncoder().encode(`${user}:${pass}`);
  let encoded = '';
  for (const b of bytes) encoded += String.fromCharCode(b);
  return btoa(encoded);
}
async function call(url, options = {}) {
  const method = (options.method || 'GET').toUpperCase();
  const headers = sessionMode ? { ...(options.headers || {}) }
    : { Authorization: `Basic ${auth}`, ...(options.headers || {}) };
  if (sessionMode && !['GET', 'HEAD', 'OPTIONS'].includes(method)) {
    if (!sessionCsrf) throw new Error('رمز حماية الجلسة غير متاح. أعد تسجيل الدخول.');
    headers['X-CSRF-TOKEN'] = sessionCsrf;
  }
  const response = await fetch(url, {
    ...options, headers, cache: 'no-store', credentials: 'same-origin',
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && !el('dashboard').hidden) {
      logout(false);
      throw new Error('انتهت صلاحية بيانات المسؤول. أعد تسجيل الدخول.');
    }
    throw new Error(body.error || (response.status === 401 ? 'بيانات الدخول غير صحيحة' : `خطأ HTTP ${response.status}`));
  }
  return body;
}
function publishPlans() {
  const payload = planHealth === 'unloaded'
    ? { data: null, health: 'unloaded' }
    : { data: buildPlanViewSnapshot(plans, el('planSearch').value), health: planHealth };
  window.dispatchEvent(new CustomEvent('radius-plans-updated', { detail: payload }));
}
window.addEventListener('radius-plans-request', publishPlans);
// Only allowlisted voucher fields enter React; creation secrets stay in the
// legacy one-time credential panel and are never included in this event.
function publishVouchers() {
  const payload = voucherHealth === 'unloaded'
    ? { data: null, health: 'unloaded' }
    : { data: buildVoucherViewSnapshot(accounts, el('labSearch').value, el('labFilter').value),
        health: voucherHealth };
  window.dispatchEvent(new CustomEvent('radius-vouchers-updated', { detail: payload }));
}
window.addEventListener('radius-vouchers-request', publishVouchers);
// Only active plans with no unenforced quota/expiry are offered for lab vouchers.
function publishVoucherPlans() {
  window.dispatchEvent(new CustomEvent('radius-voucher-plans-updated', {
    detail: { plans: eligibleVoucherPlans(plans) },
  }));
}
window.addEventListener('radius-voucher-plans-request', publishVoucherPlans);
function renderSelectors() {
  publishVoucherPlans();
  const usageSelect = el('usageAccount');
  const currentUser = usageSelect.value;
  usageSelect.replaceChildren();
  for (const a of accounts) {
    const opt = document.createElement('option');
    opt.value = a.username;
    opt.textContent = `${a.username} — ${a.planName}`;
    usageSelect.append(opt);
  }
  if ([...usageSelect.options].some(o => o.value === currentUser))
    usageSelect.value = currentUser;
  el('loadUsage').disabled = usageSelect.options.length === 0;
}
function publishOverview() {
  window.dispatchEvent(new CustomEvent('radius-overview-updated', {
    detail: { snapshot: overviewSnapshot, health: overviewHealth },
  }));
}
window.addEventListener('radius-overview-request', () => {
  if (overviewSnapshot !== null) publishOverview();
});
function onOverviewError() {
  // Previously loaded counts are stale until the next successful API response.
  overviewHealth = 'error';
  publishOverview();
}
function renderAll(summary) {
  overviewSnapshot = buildOverviewSnapshot(summary, accounts);
  overviewHealth = 'online';
  planHealth = 'online';
  voucherHealth = 'online';
  renderSelectors();publishPlans();publishVouchers();
  noc?.render();
  publishOverview();
}
async function reload() {
  if (pendingRequest) return;
  pendingRequest = true;loading(el('refreshAll'), true);loading(el('refresh'), true);
  el('pageError').hidden = true;
  try {
    const [summary, all, lab] = await Promise.all([call('/api/summary'), call('/api/plans'), call('/api/lab-accounts')]);
    plans = all; accounts = lab;
    renderAll(summary);
    noc?.status(true);
  } catch (err) {
    noc?.status(false);
    onOverviewError();
    planHealth = 'error';publishPlans();
    voucherHealth = 'error';publishVouchers();
    el('pageError').textContent = err.message;
    el('pageError').hidden = false;
    throw err;
  } finally {
    pendingRequest = false;loading(el('refreshAll'), false);loading(el('refresh'), false);
  }
}
async function disableAccount(username) {
  if (!window.confirm(`تعطيل الكرت ${username}؟ سيُمنع تسجيل الدخول الجديد فقط، ولا تُفصل جلسة حالية.`)) return;
  setError('labError');
  try {
    await call(`/api/lab-accounts/${encodeURIComponent(username)}/disable`, { method: 'POST' });
    toast('تم تعطيل الكرت للدخول الجديد فقط.', 'success');
    noc?.record(`تعطيل تسجيل الدخول الجديد للكرت ${username}`);
    await reload();
  } catch (err) { setError('labError', err.message);toast(err.message, 'error'); }
}
async function queryUsage(username) {
  if (!username) { resetUsage(); return; }
  const generation = ++usageGeneration;
  loading(el('loadUsage'), true);
  publishUsage({ kind: 'loading' });
  try {
    const response = await call(`/api/lab-accounts/${encodeURIComponent(username)}/usage`);
    // Ignore late replies after a new selection, logout or navigation.
    if (!isCurrentUsage(generation, username)) return;
    const snapshot = buildUsageViewSnapshot(username, response);
    publishUsage({ kind: 'success', snapshot });
  } catch (err) {
    if (!isCurrentUsage(generation, username)) return;
    const message = err instanceof Error ? err.message : 'تعذر قراءة الاستهلاك.';
    publishUsage({ kind: 'error', error: message });
    toast(message, 'error');
  } finally {
    if (generation === usageGeneration) loading(el('loadUsage'), false);
  }
}
async function logout(showToast = true) {
  if (sessionMode && showToast) {
    try {
      // Server revocation is mandatory: merely hiding the dashboard is not logout.
      await call('/api/admin/auth/logout', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
      });
    } catch {
      toast('تعذر إبطال الجلسة في الخادم. حاول تسجيل الخروج مرة أخرى.', 'error');
      return;
    }
  }
  auth = '';plans = [];accounts = [];clearCredentials();resetUsage();
  window.dispatchEvent(new Event('radius-plan-clear-edit'));
  planHealth = 'unloaded';publishPlans();
  voucherHealth = 'unloaded';publishVouchers();
  overviewSnapshot = null;overviewHealth = 'unloaded';publishOverview();
  el('loginPass').value = '';
  el('dashboard').hidden = true;
  el('loginPanel').hidden = false;
  closeMenu();noc?.reset();ultra?.reset();nasDrafts?.reset();
  if (sessionMode) {
    sessionCsrf = '';
    window.dispatchEvent(new Event('radius-session-logged-out'));
  }
  if (showToast) toast('تم تسجيل الخروج.');
}

// React/TypeScript owns the HTTPS login form; the legacy dashboard still
// trusts only the server cookie/RBAC response, not a DOM event as authority.
window.addEventListener('radius-session-ready', async event => {
  const token = event.detail?.csrf;
  if (typeof token !== 'string' || token.length < 20) return;
  sessionMode = true;
  sessionCsrf = token;
  auth = '';
  setError('loginError');
  try {
    await reload();
    el('loginPanel').hidden = true;
    el('dashboard').hidden = false;
    switchView('overview');
  } catch (err) {
    setError('loginError', err.message);
  }
});

el('loginForm').addEventListener('submit', async event => {
  event.preventDefault();setError('loginError');
  if (sessionMode) return; // No Basic fallback when HTTPS Identity is enabled.
  if (!el('loginForm').reportValidity()) return;
  auth = encodeAuth(el('loginUser').value, el('loginPass').value);
  const submit = el('loginForm').querySelector('button[type="submit"]');
  loading(submit, true);
  try {
    await reload();
    el('loginPanel').hidden = true;
    el('dashboard').hidden = false;
    el('loginPass').value = '';
    switchView('overview');
  } catch (err) { auth = '';setError('loginError', err.message); }
  finally { loading(submit, false); }
});
el('logout').addEventListener('click', () => { void logout(); });
el('refreshAll').addEventListener('click', () => reload().then(() => toast('تم تحديث البيانات.')).catch(err => toast(err.message, 'error')));
el('refresh').addEventListener('click', () => reload().then(() => toast('تم تحديث الباقات.')).catch(err => toast(err.message, 'error')));
el('menuToggle').addEventListener('click', () => {
  const open = !el('sidebar').classList.contains('is-open');
  el('sidebar').classList.toggle('is-open', open);
  el('mobileBackdrop').hidden = !open;
  el('menuToggle').setAttribute('aria-expanded', String(open));
});
el('mobileBackdrop').addEventListener('click', closeMenu);
document.addEventListener('keydown', event => { if (event.key === 'Escape') closeMenu(); });
for (const nav of document.querySelectorAll('[data-view]')) nav.addEventListener('click', () => switchView(nav.dataset.view));
for (const go of document.querySelectorAll('[data-goto]')) go.addEventListener('click', () => switchView(go.dataset.goto, go.dataset.focus || ''));
el('planSearch').addEventListener('input', publishPlans);
el('labSearch').addEventListener('input', publishVouchers);
el('labFilter').addEventListener('change', publishVouchers);
// React sends only loaded voucher IDs; the original client still owns
// confirmation, session CSRF, disabling, usage queries and audit feedback.
window.addEventListener('radius-voucher-usage', event => {
  const username = event.detail?.username;
  if (typeof username !== 'string' || !accounts.some(a => a.username === username)) return;
  switchView('accounting');
  el('usageAccount').value = username;
  void queryUsage(username);
});
window.addEventListener('radius-voucher-disable', event => {
  const username = event.detail?.username;
  if (typeof username !== 'string' || !accounts.some(a => a.username === username && a.active)) return;
  void disableAccount(username);
});

el('openPlanForm').addEventListener('click', () => {
  window.dispatchEvent(new Event('radius-plan-clear-edit'));
  requestAnimationFrame(() => el('planName')?.focus());
});
el('loadUsage').addEventListener('click', () => queryUsage(el('usageAccount').value));
el('usageAccount').addEventListener('change', resetUsage);

// React submits only the raw form fields. This controller preserves the original
// normalizedPlan validation, CSRF session mode, API URLs, and POST/PUT behavior.
window.addEventListener('radius-plan-save-request', async event => {
  const { id, fields, respond } = event.detail ?? {};
  if (typeof respond !== 'function') return;
  if (el('dashboard').hidden) {
    respond({ ok: false, error: 'سجل الدخول قبل تعديل الباقات.' });
    return;
  }
  try {
    const data = normalizedPlan(fields?.name, fields?.down, fields?.up, fields?.quota, fields?.days);
    const changing = typeof id === 'string' && id.length > 0;
    if (changing && !plans.some(p => p.id === id)) {
      throw new Error('هذه الباقة غير موجودة في البيانات المحملة. حدث القائمة وأعد المحاولة.');
    }
    if (id !== null && id !== undefined && !changing) throw new Error('معرف الباقة غير صالح.');
    await call(changing ? `/api/plans/${encodeURIComponent(id)}` : '/api/plans', {
      method: changing ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    respond({ ok: true });
    toast(changing ? 'تم تعديل الباقة بنجاح.' : 'تم إنشاء الباقة التجريبية.', 'success');
    noc?.record(changing ? 'تعديل إعدادات باقة تجريبية' : 'إنشاء باقة تجريبية');
    try { await reload(); }
    catch { toast('تم الحفظ، لكن تعذر تحديث القائمة. استخدم تحديث البيانات.', 'error'); }
  } catch (err) {
    respond({ ok: false, error: err instanceof Error ? err.message : 'تعذر حفظ الباقة.' });
  }
});
window.addEventListener('radius-plan-edit', () => {
  switchView('plans', 'planName');
});

// No credential ever crosses React props/state: app.mjs alone receives the
// one-time API response and writes it directly to an ephemeral React-owned <pre>.
window.addEventListener('radius-voucher-secret-reset-request', clearCredentials);
window.addEventListener('radius-voucher-create-request', async event => {
  const { planId, respond, isCurrent } = event.detail ?? {};
  if (typeof respond !== 'function') return;
  if (el('dashboard').hidden) {
    respond({ ok: false, error: 'سجل الدخول قبل إنشاء الكرت.' }); return;
  }
  if (typeof planId !== 'string' ||
      !eligibleVoucherPlans(plans).some(p => p.id === planId)) {
    respond({ ok: false, error: 'اختر باقة اختبار بدون حجم أو مدة.' }); return;
  }
  const generation = voucherSecretGate.begin();
  try {
    const data = await call('/api/lab-accounts', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ planId }),
    });
    const validReply = data?.labOnly === true &&
      data?.passwordDisplayedOnce === true &&
      typeof data.username === 'string' && typeof data.password === 'string';
    let shown = false;
    const viewActive = !el('view-vouchers').hidden && !el('dashboard').hidden;
    // Only the current active screen can display the password. A late reply
    // after navigation/logout/new attempt is discarded, never cached.
    if (validReply && voucherSecretGate.isCurrent(generation) &&
        typeof isCurrent === 'function' && isCurrent() && viewActive) {
      const secret = el('labCredentials');
      if (secret) {
        secret.textContent = `رقم الكرت: ${data.username}\nكلمة المرور (تظهر مرة واحدة): ${data.password}`;
        secret.hidden = false;
        shown = true;
        window.dispatchEvent(new Event('radius-voucher-created-visible'));
      }
    }
    // Drop the parsed network response's secret as soon as the once-only
    // DOM write has completed. JS strings themselves cannot be zeroized.
    if (data && Object.hasOwn(data, 'password')) delete data.password;
    if (!validReply) {
      respond({ ok: false, error: 'اكتمل طلب الإنشاء لكن استجابة بيانات الدخول غير صالحة. لا يمكن استعادة الكلمة.' });
      toast('تعذر التحقق من استجابة كرت الاختبار. لا تعاود المحاولة قبل مراجعة السجل.', 'error');
      return;
    }
    respond({ ok: true, shown });
    if (shown) toast('تم إنشاء الكرت. احفظ كلمة المرور الآن؛ لن تظهر ثانية.', 'success');
    else toast('تم إنشاء الكرت، لكن لم تعرض كلمة المرور لأنك غادرت الصفحة أو بدأت طلبا آخر. لا يمكن استعادتها.', 'error');
    noc?.record(`إنشاء كرت مختبر ${data.username}`);
    try { await reload(); }
    catch { toast('تم إنشاء الكرت، لكن تعذر تحديث القائمة. لا تعاود الطلب قبل التحقق.', 'error'); }
  } catch (err) {
    respond({ ok: false, error: err instanceof Error ? err.message : 'تعذر إنشاء كرت الاختبار.' });
  }
});

// NOC presentation wiring is independent of API, database and RADIUS authentication.
noc = initializeNocUi({ getPlans: () => plans, getAccounts: () => accounts, navigate: switchView, showToast: toast });

// Ultra v4: safe read-only lab session browser and offline capacity planner.
ultra = initializeUltraFeatures({ request: call, notify: toast, record: message => noc?.record(message) });

// Phase 7A inventory: no RouterOS API, VPN connection or RADIUS client updates.
nasDrafts = initializeNasDrafts({request:call, notify:toast, record:message=>noc?.record(message)});
