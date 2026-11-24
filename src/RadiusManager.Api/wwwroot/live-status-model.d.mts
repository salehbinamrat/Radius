export type LabStatus = { scope: 'lab'; database: 'reachable'; observedAtUtc: string };
export function parseLabStatus(value: unknown): LabStatus | null;
export const LIVE_RETRY_DELAYS_MS: readonly number[];
export const LIVE_STALE_MS: number;
export function nextRetryDelay(failures: number): number | null;
