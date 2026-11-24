import { filterAccounts } from './dashboard-utils.mjs';

// A voucher list must NEVER receive a password or any other account secret.
export function buildVoucherViewSnapshot(accounts, term = '', status = 'all') {
  const loaded = Array.isArray(accounts) ? accounts.slice(0, 100) : [];
  const visible = filterAccounts(loaded, term, status).map(account => ({
    username: String(account.username ?? ''),
    planName: String(account.planName ?? ''),
    active: Boolean(account.active),
  }));
  return { loadedCount: loaded.length, visibleCount: visible.length,
    visible, scope: 'first-100-loaded' };
}
