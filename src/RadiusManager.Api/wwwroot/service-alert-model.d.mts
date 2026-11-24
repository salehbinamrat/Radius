export type AlertService='postgresql'|'freeradius';
export type AlertState='healthy'|'pending'|'failed'|'unknown';
export type AlertSeverity='info'|'warning'|'critical';
export type ServiceAlertSnapshot={scope:'lab';window:'retained-samples';confirmationCount:2;
 services:{service:AlertService;state:AlertState;severity:AlertSeverity;lastEvidenceAtUtc:string|null}[];
 events:{service:AlertService;kind:'failure-confirmed'|'recovery-confirmed';severity:AlertSeverity;confirmedAtUtc:string}[]};
export function parseServiceAlerts(value:unknown):ServiceAlertSnapshot|null;
