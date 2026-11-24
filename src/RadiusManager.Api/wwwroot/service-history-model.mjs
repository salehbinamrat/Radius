const timestamp = value => typeof value === 'string'
  && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$/.test(value)
  && Number.isFinite(Date.parse(value));
const exact = (value, keys) => !!value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value,key));

export function parseServiceHistory(value) {
  if (!exact(value,['scope','retention','intervalSeconds','capacity','samples'])
      || value.scope !== 'lab' || !['process-memory','volume-snapshot','storage-degraded'].includes(value.retention)
      || value.intervalSeconds !== 15 || value.capacity !== 240
      || !Array.isArray(value.samples) || value.samples.length > 240) return null;
  const samples = [];
  let previous = -Infinity;
  for (const row of value.samples) {
    if (!exact(row,['observedAtUtc','database','databaseCheckMs','radius','radiusCheckedAtUtc'])
        || !timestamp(row.observedAtUtc)
        || !['reachable','no-response','unknown'].includes(row.database)
        || !['responsive','no-response','unknown'].includes(row.radius)) return null;
    const time = Date.parse(row.observedAtUtc);
    if (time < previous) return null;
    previous = time;
    if (row.database === 'reachable'
        ? typeof row.databaseCheckMs !== 'number' || !Number.isFinite(row.databaseCheckMs)
          || row.databaseCheckMs < 0 || row.databaseCheckMs > 10000
        : row.databaseCheckMs !== null) return null;
    if (row.radius === 'unknown' ? row.radiusCheckedAtUtc !== null :
        !timestamp(row.radiusCheckedAtUtc) || time - Date.parse(row.radiusCheckedAtUtc) < 0
          || time - Date.parse(row.radiusCheckedAtUtc) > 40000) return null;
    samples.push({observedAtUtc:row.observedAtUtc,database:row.database,
      databaseCheckMs:row.databaseCheckMs,radius:row.radius,radiusCheckedAtUtc:row.radiusCheckedAtUtc});
  }
  return {scope:'lab',retention:value.retention,intervalSeconds:15,capacity:240,samples};
}

export function historyMetrics(samples) {
  const measured = samples.filter(row => row.database === 'reachable').map(row => row.databaseCheckMs);
  return {count:samples.length,mean:measured.length ? measured.reduce((a,b)=>a+b,0)/measured.length : null,
    databaseFailures:samples.filter(row=>row.database==='no-response').length,
    radiusFailures:samples.filter(row=>row.radius==='no-response').length,
    unknown:samples.filter(row=>row.database==='unknown'||row.radius==='unknown').length};
}

/** Time-positioned chart segments. Failures, unknowns and sampling gaps break a line. */
export function latencySegments(samples) {
  const segments = [];
  let segment = [];
  let previous = null;
  for (const row of samples) {
    const t = Date.parse(row.observedAtUtc);
    if (previous !== null && t-previous > 30000 || row.databaseCheckMs === null) {
      if (segment.length) segments.push(segment);
      segment = [];
    }
    if (row.databaseCheckMs !== null) segment.push({time:t,ms:row.databaseCheckMs});
    previous = t;
  }
  if (segment.length) segments.push(segment);
  return segments;
}
