import { groupLoadedAccounts } from './noc-utils.mjs';

// Existing authenticated API is the only source of operator dashboard figures.
// Produce an allowlisted, credential-free snapshot for React (never expose account objects).
function asCount(value) {
  if (value === null || value === undefined || value === '' ||
      (typeof value !== 'string' && typeof value !== 'number')) return null;
  if (typeof value === 'string' && !/^\d+$/.test(value.trim())) return null;
  const count = Number(value);
  return Number.isSafeInteger(count) && count >= 0 ? count : null;
}

export function buildOverviewSnapshot(summary, accounts) {
  const loaded = (Array.isArray(accounts) ? accounts : []).slice(0, 100);
  const recent = loaded.slice(0, 5).map(account => ({
    username: String(account.username ?? '—'),
    planName: String(account.planName ?? '—'),
    active: Boolean(account.active),
  }));
  // Reuse the proven NOC aggregator, but pass ONLY allowlisted plan labels.
  const { groups } = groupLoadedAccounts(loaded.map(a => ({ planName: a.planName })));
  return {
    groups,
    lastSyncedAt: new Date().toISOString(),
    plans: asCount(summary?.plans),
    labAccounts: asCount(summary?.labAccounts),
    activeInLoadedAccounts: loaded.filter(account => account.active).length,
    loadedAccountCount: loaded.length,
    recent,
    scope: 'first-100-loaded',
  };
}
