export type AlertService='postgresql'|'freeradius';
export type AlertState='healthy'|'pending'|'failed'|'unknown';
export type AlertSeverity='info'|'warning'|'critical';
export type ServiceAlertSnapshot={scope:'lab';window:'retained-samples';confirmationCount:2;
 services:{service:AlertService;state:AlertState;severity:AlertSeverity;lastEvidenceAtUtc:string|null}[];
 events:{service:AlertService;kind:'failure-confirmed'|'recovery-confirmed';severity:AlertSeverity;confirmedAtUtc:string}[]};
export function parseServiceAlerts(value:unknown):ServiceAlertSnapshot|null;

export type ServiceIncident={id:string;service:AlertService;failureConfirmedAtUtc:string;recoveryConfirmedAtUtc:string|null};
export type ServiceIncidentSnapshot={scope:'lab';retention:'process-memory'|'volume-snapshot'|'storage-degraded';closedCapacity:256;
 services:ServiceAlertSnapshot['services'];incidents:ServiceIncident[]};
export function parseServiceIncidents(value:unknown):ServiceIncidentSnapshot|null;
