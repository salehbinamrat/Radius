export function filterPlans(plans, term = '') {
  const needle = String(term).trim().toLocaleLowerCase('ar');
  return plans.filter(plan => String(plan.name).toLocaleLowerCase('ar').includes(needle));
}

export function filterAccounts(accounts, term = '', status = 'all') {
  const needle = String(term).trim().toLocaleLowerCase('ar');
  return accounts.filter(account =>
    (status === 'all' || (status === 'active' && account.active) || (status === 'disabled' && !account.active)) &&
    (`${account.username} ${account.planName}`.toLocaleLowerCase('ar').includes(needle)));
}

export function summarizeVisibleAccounts(accounts) {
  return { active: accounts.filter(account => account.active).length, total: accounts.length };
}

export function formatBytes(bytes) {
  const number = Number(bytes);
  if (!Number.isFinite(number) || number < 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let amount = number;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) { amount /= 1024; unit++; }
  return `${amount.toLocaleString('en-US', { maximumFractionDigits: unit === 0 ? 0 : 2 })} ${units[unit]}`;
}

export function formatKbps(speed) {
  const number = Number(speed);
  if (!Number.isFinite(number) || number < 0) return '—';
  return number >= 1024 && number % 1024 === 0 ? `${number / 1024} Mbps` : `${number} Kbps`;
}
