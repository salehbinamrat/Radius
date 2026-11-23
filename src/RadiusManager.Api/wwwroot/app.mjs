import { normalizedPlan } from './plan-utils.mjs';
import { initializeNocUi } from './noc-ui.mjs';
import { initializeUltraFeatures } from './ultra-features.mjs';
import { filterPlans, filterAccounts, summarizeVisibleAccounts, formatBytes, formatKbps } from './dashboard-utils.mjs';

const el = id => document.getElementById(id);
let auth = '';
let editingId = null;
let plans = [];
let accounts = [];
let pendingRequest = false;
let toastTimeout = null;
let noc = null;
let ultra = null;
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
  if (view !== 'vouchers') clearCredentials(); // one-time password must not linger across navigation
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
  const response = await fetch(url, {
    ...options,
    headers: { Authorization: `Basic ${auth}`, ...(options.headers || {}) },
    cache: 'no-store',
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
function rowMessage(tbody, span, message) {
  const tr = tbody.insertRow();
  tr.className = 'empty-row';
  const cell = tr.insertCell();
  cell.colSpan = span;
  cell.textContent = message;
}
function appendCell(row, value) {
  const cell = row.insertCell();
  cell.textContent = String(value);
  return cell;
}
function appendPill(row, active) {
  const cell = row.insertCell();
  const span = document.createElement('span');
  span.className = active ? 'pill good' : 'pill off';
  span.textContent = active ? 'مفعّل' : 'موقوف';
  cell.append(span);
}
function button(label, className, onClick) {
  const element = document.createElement('button');
  element.type = 'button';
  element.className = `btn ${className}`;
  element.textContent = label;
  element.addEventListener('click', onClick);
  return element;
}
function renderRecent() {
  const body = el('recentAccounts');
  body.replaceChildren();
  const rows = accounts.slice(0, 5);
  if (rows.length === 0) return rowMessage(body, 3, 'لا توجد كروت اختبار مسجلة حتى الآن.');
  for (const a of rows) {
    const row = body.insertRow();
    appendCell(row, a.username); appendCell(row, a.planName); appendPill(row, a.active);
  }
}
function renderPlans() {
  const body = el('plansList');
  const visible = filterPlans(plans, el('planSearch').value);
  body.replaceChildren();
  if (!visible.length) rowMessage(body, 5, plans.length ? 'لا توجد باقات مطابقة للبحث.' : 'لا توجد باقات حتى الآن.');
  for (const p of visible) {
    const row = body.insertRow();
    appendCell(row, p.name);
    appendCell(row, formatKbps(p.downloadKbps));
    appendCell(row, formatKbps(p.uploadKbps));
    appendPill(row, p.active);
    const actions = row.insertCell();
    actions.append(button('تعديل', 'subtle', () => editPlan(p)));
  }
  el('planCount').textContent = `المعروض ${visible.length} من ${plans.length} باقة محملة (حد القراءة: 100)`;
}
function renderAccounts() {
  const visible = filterAccounts(accounts, el('labSearch').value, el('labFilter').value);
  const body = el('labList'); body.replaceChildren();
  if (!visible.length) rowMessage(body, 4, accounts.length ? 'لا توجد كروت مطابقة للبحث.' : 'لا توجد كروت مختبر حتى الآن.');
  for (const a of visible) {
    const row = body.insertRow();
    appendCell(row, a.username); appendCell(row, a.planName); appendPill(row, a.active);
    const actions = row.insertCell();
    actions.append(button('الاستهلاك', 'subtle', () => {
      switchView('accounting');
      el('usageAccount').value = a.username;
      queryUsage(a.username);
    }));
    if (a.active) actions.append(button('تعطيل', 'danger', () => disableAccount(a.username)));
  }
  el('labCount').textContent = `المعروض ${visible.length} من ${accounts.length} كرت محمل (حد القراءة: 100)`;
}
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
function renderAll(summary) {
  el('statPlans').textContent = Number(summary.plans).toLocaleString('en-US');
  el('statUsers').textContent = Number(summary.labAccounts).toLocaleString('en-US');
  el('statActive').textContent = summarizeVisibleAccounts(accounts).active.toLocaleString('en-US');
  el('statHealth').textContent = 'متصل';
  el('statHealth').className = 'health-metric good';
  renderSelectors();renderRecent();renderPlans();renderAccounts();
  noc?.render();
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
    el('statHealth').textContent = 'خطأ';el('statHealth').className = 'health-metric bad';
    el('pageError').textContent = err.message;
    el('pageError').hidden = false;
    throw err;
  } finally {
    pendingRequest = false;loading(el('refreshAll'), false);loading(el('refresh'), false);
  }
}
function clearEdit() {
  editingId = null;
  el('planFormTitle').textContent = 'إنشاء باقة تجريبية';
  el('planForm').reset();
  el('savePlan').textContent = 'حفظ الباقة';
  el('cancelEdit').hidden = true;
}
function editPlan(p) {
  editingId = p.id;
  el('planFormTitle').textContent = 'تعديل الباقة: ' + p.name;
  el('planName').value = p.name;
  el('planDown').value = p.downloadKbps;
  el('planUp').value = p.uploadKbps;
  el('planQuota').value = p.quotaBytes === null ? '' : String(Math.floor(p.quotaBytes / 1048576));
  el('planDays').value = p.validityDays ?? '';
  el('savePlan').textContent = 'حفظ التعديل';
  el('cancelEdit').hidden = false;
  switchView('plans', 'planName');
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
function logout(showToast = true) {
  auth = '';plans = [];accounts = [];clearCredentials();resetUsage();clearEdit();
  el('loginPass').value = '';
  el('dashboard').hidden = true;
  el('loginPanel').hidden = false;
  closeMenu();noc?.reset();ultra?.reset();
  if (showToast) toast('تم تسجيل الخروج.');
}

el('loginForm').addEventListener('submit', async event => {
  event.preventDefault();setError('loginError');
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
el('logout').addEventListener('click', () => logout());
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
el('planSearch').addEventListener('input', renderPlans);
el('labSearch').addEventListener('input', renderAccounts);
el('labFilter').addEventListener('change', renderAccounts);
el('cancelEdit').addEventListener('click', clearEdit);
el('openPlanForm').addEventListener('click', () => { clearEdit();el('planName').focus(); });
el('loadUsage').addEventListener('click', () => queryUsage(el('usageAccount').value));
el('usageAccount').addEventListener('change', resetUsage);

el('planForm').addEventListener('submit', async event => {
  event.preventDefault();setError('planError');
  let data;
  try { data = normalizedPlan(el('planName').value, el('planDown').value, el('planUp').value, el('planQuota').value, el('planDays').value); }
  catch (err) {setError('planError', err.message);return;}
  const saveButton = el('savePlan');loading(saveButton, true);
  try {
    const changing = Boolean(editingId);
    await call(changing ? `/api/plans/${editingId}` : '/api/plans', { method: changing ? 'PUT' : 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
    clearEdit();
    toast(changing ? 'تم تعديل الباقة بنجاح.' : 'تم إنشاء الباقة التجريبية.', 'success');
    noc?.record(changing ? 'تعديل إعدادات باقة تجريبية' : 'إنشاء باقة تجريبية');
    try { await reload(); } catch { toast('تم الحفظ، لكن تعذر تحديث القائمة. استخدم تحديث البيانات.', 'error'); }
  } catch (err) { setError('planError', err.message); }
  finally {loading(saveButton, false);}
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
