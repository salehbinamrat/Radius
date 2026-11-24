const exact = (value,keys) => !!value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === keys.length && keys.every(k=>Object.hasOwn(value,k));
const utc = value => typeof value === 'string'
  && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$/.test(value)
  && Number.isFinite(Date.parse(value));
const stateSeverity = Object.freeze({healthy:'info',pending:'warning',failed:'critical',unknown:'warning'});
const eventSeverity = Object.freeze({'failure-confirmed':'critical','recovery-confirmed':'info'});
const isService = value => value === 'postgresql' || value === 'freeradius';

export function parseServiceAlerts(value) {
  if (!exact(value,['scope','window','confirmationCount','services','events'])
      || value.scope !== 'lab' || value.window !== 'retained-samples' || value.confirmationCount !== 2
      || !Array.isArray(value.services) || value.services.length !== 2
      || !Array.isArray(value.events) || value.events.length > 480) return null;
  const services = [];
  const seen = new Set();
  for (const row of value.services) {
    if (!exact(row,['service','state','severity','lastEvidenceAtUtc'])
        || !isService(row.service) || seen.has(row.service)
        || !Object.hasOwn(stateSeverity,row.state) || stateSeverity[row.state] !== row.severity
        || (row.lastEvidenceAtUtc === null ? row.state !== 'unknown' : !utc(row.lastEvidenceAtUtc))) return null;
    seen.add(row.service);
    services.push({service:row.service,state:row.state,severity:row.severity,lastEvidenceAtUtc:row.lastEvidenceAtUtc});
  }
  const events=[];
  let previous=-Infinity;
  for (const row of value.events) {
    if (!exact(row,['service','kind','severity','confirmedAtUtc'])
        || !isService(row.service) || !Object.hasOwn(eventSeverity,row.kind)
        || eventSeverity[row.kind] !== row.severity || !utc(row.confirmedAtUtc)) return null;
    const time=Date.parse(row.confirmedAtUtc);
    if (time<previous) return null;
    previous=time;
    events.push({service:row.service,kind:row.kind,severity:row.severity,confirmedAtUtc:row.confirmedAtUtc});
  }
  return {scope:'lab',window:'retained-samples',confirmationCount:2,services,events};
}
