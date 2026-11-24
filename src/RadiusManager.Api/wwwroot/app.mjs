import { normalizedPlan } from './plan-utils.mjs';
import { buildOverviewSnapshot } from './overview-model.mjs';
import { buildPlanViewSnapshot } from './plan-view-model.mjs';
import { buildVoucherViewSnapshot } from './voucher-view-model.mjs';
import { initializeNocUi } from './noc-ui.mjs';
import { initializeUltraFeatures } from './ultra-features.mjs';
import { initializeNasDrafts } from './nas-drafts.mjs';
import { formatBytes } from './dashboard-utils.mjs';

const el = id => document.getElementById(id);
let auth = '';
let sessionMode = false;
let sessionCsrf = '';
let planHealth = 'unloaded';
let voucherHealth = 'unloaded';
let plans = [];
let accounts = [];
let overviewSnapshot = null;
let overviewHealth = 'unloaded';
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
function resetUsage() {
  el('usageReport').hidden = true;
  el('usageEmpty').hidden = false;
}
function clearCredentials() {
  el('labCredentials').textContent = '';
  el('labCredentials').hidden = true;
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
function renderSelectors() {
  const planSelect = el('labPlan');
  const currentPlan = planSelect.value;
  planSelect.replaceChildren();
  for (const p of plans.filter(p => p.active && p.quotaBytes === null && p.validityDays === null)) {
    const opt = document.createElement('option');opt.value = p.id;opt.textContent = p.name;planSelect.append(opt);
  }
  if ([...planSelect.options].some(o => o.value === currentPlan)) planSelect.value = currentPlan;
  el('generateLab').disabled = planSelect.options.length === 0;
  const usageSelect = el('usageAccount');
  const currentUser = usageSelect.value;
  usageSelect.replaceChildren();
  for (const a of accounts) {
    const opt = document.createElement('option');opt.value = a.username;opt.textContent = `${a.username} — ${a.planName}`;usageSelect.append(opt);
  }
  if ([...usageSelect.options].some(o => o.value === currentUser)) usageSelect.value = currentUser;
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
  if (!username) { resetUsage();return; }
  const loadButton = el('loadUsage');loading(loadButton, true);
  el('usageEmpty').hidden = false;
  el('usageReport').hidden = true;
  try {
    const r = await call(`/api/lab-accounts/${encodeURIComponent(username)}/usage`);
    el('usageTotal').textContent = formatBytes(r.totalBytes);
    el('usageDown').textContent = formatBytes(r.downloadBytes);
    el('usageUp').textContent = formatBytes(r.uploadBytes);
    el('usageSessions').textContent = r.sessions;
    el('usageOpen').textContent = r.openSessions;
    el('usageStale').textContent = r.staleSessions;
    el('usageAnomalous').textContent = r.anomalousSessions;
    el('usageNas').textContent = r.observedNas;
    el('usageFinal').textContent = r.reportIsFinal ? 'مغلق شكليا' : 'غير نهائي';
    el('usageWarning').textContent = r.warning || 'النتيجة استرشادية ولا تُستخدم لحساب الرصيد.';
    el('usageEmpty').hidden = true;el('usageReport').hidden = false;
  } catch (err) {
    toast(err.message, 'error');
    el('usageEmpty').querySelector('strong').textContent = 'تعذر قراءة الاستهلاك';
    el('usageEmpty').querySelector('span').textContent = err.message;
  } finally { loading(loadButton, false); }
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

el('labForm').addEventListener('submit', async event => {
  event.preventDefault();setError('labError');clearCredentials();
  if (!el('labPlan').value) {setError('labError', 'اختر باقة اختبار بدون حجم أو مدة.');return;}
  const createButton = el('generateLab');loading(createButton, true);
  try {
    const data = await call('/api/lab-accounts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({planId:el('labPlan').value}) });
    // Secrets are shown once in memory, never written to browser storage or the URL.
    el('labCredentials').textContent = `رقم الكرت: ${data.username}\nكلمة المرور (تظهر مرة واحدة): ${data.password}`;
    el('labCredentials').hidden = false;
    toast('تم إنشاء كرت اختبار. احفظ كلمة المرور الآن؛ لن تظهر ثانية.', 'success');
    noc?.record(`إنشاء كرت مختبر ${data.username}`);
    try { await reload(); } catch { toast('تم إنشاء الكرت، لكن تعذر تحديث القائمة. احتفظ بكلمة المرور المعروضة.', 'error'); }
  } catch (err) {setError('labError', err.message);}
  finally {loading(createButton, false);}
});

// NOC presentation wiring is independent of API, database and RADIUS authentication.
noc = initializeNocUi({ getPlans: () => plans, getAccounts: () => accounts, navigate: switchView, showToast: toast });

// Ultra v4: safe read-only lab session browser and offline capacity planner.
ultra = initializeUltraFeatures({ request: call, notify: toast, record: message => noc?.record(message) });

// Phase 7A inventory: no RouterOS API, VPN connection or RADIUS client updates.
nasDrafts = initializeNasDrafts({request:call, notify:toast, record:message=>noc?.record(message)});
