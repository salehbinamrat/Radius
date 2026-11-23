/** Source data only: never generate invented network status, sales or traffic. */
export function groupLoadedAccounts(accounts, maxGroups = 5) {
  const counts = new Map();
  for (const account of accounts) {
    const name = String(account.planName ?? '').trim() || 'غير محددة';
    counts.set(name, (counts.get(name) ?? 0) + 1);
  }
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'ar'));
  const limit = Math.max(1, Number.isInteger(maxGroups) ? maxGroups : 5);
  const total = accounts.length;
  const groups = ranked.slice(0, limit).map(([name, count]) => ({ name, count, percent: total ? 100 * count / total : 0 }));
  const otherCount = ranked.slice(limit).reduce((sum, [, count]) => sum + count, 0);
  if (otherCount) groups.push({ name: 'باقات أخرى', count: otherCount, percent: 100 * otherCount / total });
  return { groups, total };
}

/** A display-only CSV export of the loaded, filtered page. No passwords or live server state. */
export function csvCell(value) {
  let text = String(value ?? '');
  // Excel/Calc may interpret formula-like values after whitespace: neutralize those cells.
  if (/^\s*[=+@\-\t\r\n]/u.test(text)) text = "'" + text;
  return '"' + text.replaceAll('"', '""') + '"';
}
export function buildSafeCsv(header, rows) {
  return '\uFEFF' + [header, ...rows].map(row => row.map(csvCell).join(',')).join('\r\n') + '\r\n';
}
export function searchLoadedRecords(plans, accounts, query, limit = 8) {
  const needle = String(query).trim().toLocaleLowerCase('ar');
  if (!needle) return [];
  const found = [];
  for (const plan of plans) {
    if (String(plan.name).toLocaleLowerCase('ar').includes(needle))
      found.push({ kind: 'plan', label: String(plan.name), value: String(plan.id) });
  }
  for (const account of accounts) {
    if (`${account.username} ${account.planName}`.toLocaleLowerCase('ar').includes(needle))
      found.push({ kind: 'account', label: `${account.username} — ${account.planName}`, value: String(account.username) });
  }
  return found.slice(0, limit);
}
