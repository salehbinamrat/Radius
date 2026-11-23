export function normalizedPlan(name, down, up, quota, days) {
  const clean = String(name).trim();
  const result = { name: clean, downloadKbps: Number(down), uploadKbps: Number(up),
    quotaMb: quota === '' ? null : Number(quota), validityDays: days === '' ? null : Number(days) };
  if (!clean || clean.length > 80) throw new Error('اسم الباقة غير صالح');
  if (![result.downloadKbps,result.uploadKbps].every(n => Number.isInteger(n) && n >= 64 && n <= 1_000_000))
    throw new Error('سرعة غير صالحة');
  if (result.quotaMb !== null && (!Number.isSafeInteger(result.quotaMb) || result.quotaMb < 1 || result.quotaMb > 100_000_000))
    throw new Error('رصيد غير صالح');
  if (result.validityDays !== null && (!Number.isInteger(result.validityDays) || result.validityDays < 1 || result.validityDays > 3650))
    throw new Error('صلاحية غير صالحة');
  return result;
}
export function rateLimit(uploadKbps,downloadKbps) { return `${uploadKbps}k/${downloadKbps}k`; }
