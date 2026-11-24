import { filterPlans, formatKbps } from './dashboard-utils.mjs';

// Only the list's approved public lab-plan fields cross into React; never pass
// subscriber secrets, network credentials or raw database records.
export function buildPlanViewSnapshot(plans, term = '') {
  const loaded = Array.isArray(plans) ? plans.slice(0, 100) : [];
  const visible = filterPlans(loaded, term).map(p => ({
    id: String(p.id ?? ''),
    name: String(p.name ?? ''),
    downloadKbps: Number(p.downloadKbps),
    uploadKbps: Number(p.uploadKbps),
    quotaBytes: p.quotaBytes == null ? null : Number(p.quotaBytes),
    validityDays: p.validityDays == null ? null : Number(p.validityDays),
    active: p.active === true,
    downloadText: formatKbps(p.downloadKbps),
    uploadText: formatKbps(p.uploadKbps),
  }));
  return { loadedCount: loaded.length, visibleCount: visible.length,
    visible, scope: 'first-100-loaded' };
}
