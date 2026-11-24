/** Accept only the server's laboratory status contract, never arbitrary payloads. */
export function parseLabStatus(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  if (Object.keys(value).length !== 3 || value.scope !== 'lab' || value.database !== 'reachable'
      || typeof value.observedAtUtc !== 'string'
      || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$/.test(value.observedAtUtc)
      || !Number.isFinite(Date.parse(value.observedAtUtc))) return null;
  return { scope: 'lab', database: 'reachable', observedAtUtc: value.observedAtUtc };
}

export const LIVE_RETRY_DELAYS_MS = Object.freeze([2000, 5000, 10000]);
export const LIVE_STALE_MS = 25000;
export function nextRetryDelay(failures) {
  return Number.isInteger(failures) && failures >= 0
    ? LIVE_RETRY_DELAYS_MS[failures] ?? null : null;
}
