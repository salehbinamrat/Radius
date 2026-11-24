import { buildSafeCsv, searchLoadedRecords } from './noc-utils.mjs';

/** NOC-inspired presentation of EXISTING lab data. No backend simulation. */
export function initializeNocUi({ getPlans, getAccounts, navigate, showToast }) {
  const el = id => document.getElementById(id);
  const search = el('nocQuickSearch');
  const results = el('nocSearchResults');
  const drawer = el('nocActivityDrawer');
  const backdrop = el('nocDrawerBackdrop');
  const toggle = el('nocActivityToggle');
  const activityList = el('nocActivityList');
  let activity = [];
  let lastDrawerFocus = null;

  function closeSearch() {
    results.replaceChildren();
    results.hidden = true;
    search.setAttribute('aria-expanded', 'false');
  }
  function renderSearch() {
    const query = search.value.trim();
    if (!query) return closeSearch();
    const found = searchLoadedRecords(getPlans(), getAccounts(), query);
    results.replaceChildren();
    results.hidden = false;
    search.setAttribute('aria-expanded', 'true');
    const heading = document.createElement('div');
    heading.className = 'noc-search-caption';
    heading.textContent = 'نتائج من أول 100 باقة وكرت محمل';
    results.append(heading);
    if (!found.length) {
      const empty = document.createElement('p');
      empty.className = 'noc-search-empty';
      empty.textContent = 'لا توجد نتائج في البيانات المحملة.';
      results.append(empty);
      return;
    }
    for (const item of found) {
      const option = document.createElement('button');
      option.type = 'button';
      option.className = 'noc-search-option';
      option.setAttribute('role', 'option');
      const kind = document.createElement('span');
      kind.className = 'noc-search-kind';
      kind.textContent = item.kind === 'plan' ? 'باقة' : 'كرت';
      const label = document.createElement('span');
      label.textContent = item.label;
      option.append(kind, label);
      option.addEventListener('click', () => {
        closeSearch();
        search.value = '';
        if (item.kind === 'plan') {
          el('planSearch').value = item.label;
          navigate('plans');
          el('planSearch').dispatchEvent(new Event('input'));
        } else {
          el('labSearch').value = item.value;
          el('labFilter').value = 'all';
          navigate('vouchers');
          el('labSearch').dispatchEvent(new Event('input'));
        }
      });
      results.append(option);
    }
  }

  function closeDrawer() {
    drawer.hidden = true;
    backdrop.hidden = true;
    toggle.setAttribute('aria-expanded', 'false');
    if (lastDrawerFocus?.isConnected) lastDrawerFocus.focus();
  }
  function openDrawer() {
    closeSearch();
    lastDrawerFocus = document.activeElement;
    drawer.hidden = false;
    backdrop.hidden = false;
    toggle.setAttribute('aria-expanded', 'true');
    el('nocActivityClose').focus();
  }
  function renderActivity() {
    activityList.replaceChildren();
    const count = el('nocActivityCount');
    count.hidden = !activity.length;
    count.textContent = String(activity.length);
    if (!activity.length) {
      const p = document.createElement('p');
      p.className = 'noc-empty-activity';
      p.textContent = 'لا توجد عمليات مسجلة في هذه الجلسة.';
      activityList.append(p);
    }
    for (const entry of activity) {
      const card = document.createElement('article');
      card.className = 'noc-activity-item';
      const heading = document.createElement('strong');
      heading.textContent = entry.message;
      const time = document.createElement('small');
      time.textContent = entry.time;
      card.append(heading, time);
      activityList.append(card);
    }
  }
  function record(message) {
    activity.unshift({ message: String(message), time: new Date().toLocaleTimeString('ar', { hour: '2-digit', minute: '2-digit' }) });
    activity = activity.slice(0, 20);
    renderActivity();
  }
  function status(connected) {
    // The React overview now owns the detailed health status and last-sync timestamp.
    el('nocTopStatusText').textContent = connected ? 'API متصل • مختبر' : 'API غير متصل • مختبر';
  }
  function downloadFilteredCsv(type) {
    let header, rows, filename;
    if (type === 'plans') {
      const term = el('planSearch').value.trim().toLocaleLowerCase('ar');
      const visible = getPlans().filter(p => p.name.toLocaleLowerCase('ar').includes(term));
      header = ['الباقة', 'التنزيل Kbps', 'الرفع Kbps', 'الحالة'];
      rows = visible.map(p => [p.name, p.downloadKbps, p.uploadKbps, p.active ? 'مفعلة' : 'موقوفة']);
      filename = 'radius-lab-plans-visible.csv';
    } else {
      const term = el('labSearch').value.trim().toLocaleLowerCase('ar');
      const filter = el('labFilter').value;
      const visible = getAccounts().filter(a => `${a.username} ${a.planName}`.toLocaleLowerCase('ar').includes(term)
        && (filter === 'all' || (filter === 'active' && a.active) || (filter === 'disabled' && !a.active)));
      header = ['رقم الكرت', 'الباقة', 'الحالة'];
      rows = visible.map(a => [a.username, a.planName, a.active ? 'مفعل' : 'موقوف']);
      filename = 'radius-lab-accounts-visible.csv';
    }
    if (!rows.length) {
      showToast('لا توجد سجلات معروضة للتصدير.', 'error');
      return;
    }
    const blob = new Blob([buildSafeCsv(header, rows)], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.append(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    record(`تصدير ${rows.length} سجل من ${type === 'plans' ? 'الباقات' : 'كروت المختبر'} المعروضة`);
    showToast(`تم إعداد CSV لعدد ${rows.length} سجل محمل فقط.`, 'success');
  }
  search.addEventListener('input', renderSearch);
  search.addEventListener('keydown', event => {
    if (event.key === 'Enter') {
      event.preventDefault();
      results.querySelector('button')?.click();
    }
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') { closeSearch(); if (!drawer.hidden) closeDrawer(); }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && !el('dashboard').hidden) {
      event.preventDefault();search.focus();search.select();
    }
  });
  // Click outside the search surface closes the palette.
  document.addEventListener('pointerdown', event => {
    if (!event.target.closest('.noc-global-search')) closeSearch();
  });
  toggle.addEventListener('click', () => drawer.hidden ? openDrawer() : closeDrawer());
  el('nocActivityClose').addEventListener('click', closeDrawer);
  backdrop.addEventListener('click', closeDrawer);
  el('nocThemeToggle').addEventListener('click', () => {
    const isDark = document.documentElement.classList.toggle('noc-dark');
    el('nocThemeToggle').setAttribute('aria-pressed', String(isDark));
    showToast(isDark ? 'تم تفعيل الوضع الليلي.' : 'تم تفعيل الوضع النهاري.');
  });
  el('sidebarCollapse').addEventListener('click', () => {
    const collapsed = el('sidebar').classList.toggle('is-compact');
    el('sidebarCollapse').setAttribute('aria-expanded', String(!collapsed));
  });
  el('nocExportPlans').addEventListener('click', () => downloadFilteredCsv('plans'));
  el('nocExportAccounts').addEventListener('click', () => downloadFilteredCsv('accounts'));
  renderActivity();
  return {
    render() { if (!results.hidden) renderSearch(); },
    status, record,
    onViewChanged() { closeSearch(); },
    reset() {
      activity = [];renderActivity();closeDrawer();closeSearch();search.value = '';
      el('nocTopStatusText').textContent = 'مختبر • الحالة غير مفحوصة';
    }
  };
}
