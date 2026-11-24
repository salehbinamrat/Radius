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

export function parseServiceIncidents(value) {
  if (!exact(value,['scope','retention','closedCapacity','services','incidents'])
      || value.scope !== 'lab' || !['process-memory','volume-snapshot','storage-degraded'].includes(value.retention)
      || value.closedCapacity !== 256 || !Array.isArray(value.incidents) || value.incidents.length > 258)
    return null;
  const status = parseServiceAlerts({scope:'lab',window:'retained-samples',confirmationCount:2,services:value.services,events:[]});
  if (!status) return null;
  const incidents=[], ids=new Set(), open=new Set();
  let closed=0, previous=-Infinity;
  for (const row of value.incidents) {
    if (!exact(row,['id','service','failureConfirmedAtUtc','recoveryConfirmedAtUtc'])
        || typeof row.id !== 'string'
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(row.id)
        || row.id === '00000000-0000-0000-0000-000000000000' || ids.has(row.id.toLowerCase())
        || !isService(row.service) || !utc(row.failureConfirmedAtUtc)) return null;
    const failure=Date.parse(row.failureConfirmedAtUtc);
    if (failure<previous) return null;
    previous=failure;
    ids.add(row.id.toLowerCase());
    if (row.recoveryConfirmedAtUtc===null) {
      if (open.has(row.service)) return null;
      open.add(row.service);
    } else {
      if (!utc(row.recoveryConfirmedAtUtc) || Date.parse(row.recoveryConfirmedAtUtc)<failure || ++closed>256)
        return null;
    }
    incidents.push({id:row.id,service:row.service,failureConfirmedAtUtc:row.failureConfirmedAtUtc,
      recoveryConfirmedAtUtc:row.recoveryConfirmedAtUtc});
  }
  for (const service of status.services) {
    if (service.state==='failed'&&!open.has(service.service) || service.state==='healthy'&&open.has(service.service))
      return null;
  }
  return {scope:'lab',retention:value.retention,closedCapacity:256,services:status.services,incidents};
}
