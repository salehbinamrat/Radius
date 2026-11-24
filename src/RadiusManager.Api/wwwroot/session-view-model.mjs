// Read-only presentation of already-authorized laboratory accounting rows.
// "open-unconfirmed" is NOT a live session or evidence of RouterOS reachability.
const labels = {
  closed: 'مغلقة',
  stale: 'قديمة / غير مؤكدة',
  'open-unconfirmed': 'مفتوحة (غير مؤكدة)',
  anomaly: 'بيانات غير سليمة',
};

function formattedDate(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—'
    : date.toLocaleString('ar', { dateStyle: 'short', timeStyle: 'short' });
}
function formattedBytes(value) {
  if (value === null || value === undefined ||
      !Number.isFinite(Number(value)) || Number(value) < 0) return 'غير سليم';
  const mb = Number(value) / 1048576;
  return mb >= 1024 ? (mb / 1024).toFixed(2) + ' GB' : mb.toFixed(2) + ' MB';
}

export function buildSessionViewSnapshot(sessions, term = '') {
  const loaded = Array.isArray(sessions) ? sessions.slice(0, 100) : [];
  const query = String(term).trim().toLowerCase();
  const filtered = loaded.filter(s =>
    (String(s.username) + ' ' + String(s.framedIp) + ' ' +
     String(s.callingStationId) + ' ' + String(s.nasIp))
      .toLowerCase().includes(query));
  const visible = filtered.map(s => {
    const known = Object.hasOwn(labels, s.classification);
    return {
      username: String(s.username ?? '—'),
      framedIp: String(s.framedIp || '—'),
      callingStationId: String(s.callingStationId || '—'),
      nasIp: String(s.nasIp || '—'),
      status: known ? labels[s.classification] : 'غير معروف',
      classification: known ? s.classification : 'unknown',
      startedAt: formattedDate(s.startedAt),
      updatedAt: formattedDate(s.updatedAt),
      transfer: formattedBytes(s.uploadBytes) + ' / ' + formattedBytes(s.downloadBytes),
      terminateCause: String(s.terminateCause || '—'),
    };
  });
  return {
    loadedCount: loaded.length,
    visibleCount: visible.length,
    visible,
    scope: 'first-100-loaded',
  };
}
