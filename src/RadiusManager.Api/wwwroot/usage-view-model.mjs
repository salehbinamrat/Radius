import { formatBytes } from './dashboard-utils.mjs';

// Convert only approved, already-authorized lab accounting fields for the React
// display. Never copy raw API responses, passwords, NAS secrets or credentials.
function displayCount(value) {
  if (value === null || value === undefined || value === '') return '—';
  const number = typeof value === 'string' && /^\d+$/.test(value.trim())
    ? Number(value.trim()) : value;
  return typeof number === 'number' && Number.isSafeInteger(number) && number >= 0
    ? number.toLocaleString('en-US') : '—';
}

function displayBytes(value) {
  if (value === null || value === undefined || value === '' ||
      !Number.isFinite(Number(value)) || Number(value) < 0) return '—';
  return formatBytes(value);
}

export function buildUsageViewSnapshot(username, result) {
  if (typeof username !== 'string' || !username.trim() ||
      !result || typeof result !== 'object' || Array.isArray(result)) {
    throw new TypeError('لا يمكن عرض استهلاك كرت دون رد صالح من الخادم.');
  }
  return {
    username,
    total: displayBytes(result.totalBytes),
    download: displayBytes(result.downloadBytes),
    upload: displayBytes(result.uploadBytes),
    sessions: displayCount(result.sessions),
    openSessions: displayCount(result.openSessions),
    staleSessions: displayCount(result.staleSessions),
    anomalousSessions: displayCount(result.anomalousSessions),
    observedNas: displayCount(result.observedNas),
    finality: result.reportIsFinal === true ? 'مغلق شكليا' : 'غير نهائي',
    warning: typeof result.warning === 'string' && result.warning.trim()
      ? result.warning : 'النتيجة استرشادية ولا تُستخدم لحساب الرصيد.',
    scope: 'lab-accounting-estimate',
  };
}
