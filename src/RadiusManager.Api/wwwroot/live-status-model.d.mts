export type LabStatus = { scope: 'lab'; api: 'running'; database: 'reachable'; sessionCheckMs: number; observedAtUtc: string; radius: { state: 'responsive' | 'no-response' | 'unknown'; checkedAtUtc: string | null } };
export function parseLabStatus(value: unknown): LabStatus | null;
export const LIVE_RETRY_DELAYS_MS: readonly number[];
export const LIVE_STALE_MS: number;
export function nextRetryDelay(failures: number): number | null;
