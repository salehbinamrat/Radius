export type ServiceSample = { observedAtUtc:string; database:'reachable'|'no-response'|'unknown';
 databaseCheckMs:number|null; radius:'responsive'|'no-response'|'unknown'; radiusCheckedAtUtc:string|null };
export type ServiceHistory = {scope:'lab';retention:'process-memory';intervalSeconds:15;capacity:240;samples:ServiceSample[]};
export function parseServiceHistory(value:unknown):ServiceHistory|null;
export function historyMetrics(samples:ServiceSample[]):{count:number;mean:number|null;databaseFailures:number;radiusFailures:number;unknown:number};
export function latencySegments(samples:ServiceSample[]):{time:number;ms:number}[][];
