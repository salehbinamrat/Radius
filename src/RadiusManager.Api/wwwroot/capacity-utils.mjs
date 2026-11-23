/** Pure hypothetical planning calculator. No RADIUS/NAS command or quota changes. */
export function estimateCapacity({ users, averageMbps, peakConcurrencyPercent, contentionRatio, dailyPeakEquivalentHours }) {
  const input = [users, averageMbps, peakConcurrencyPercent, contentionRatio, dailyPeakEquivalentHours].map(Number);
  const [u, speed, peak, sharing, hours] = input;
  if (!input.every(Number.isFinite) || !Number.isSafeInteger(u) || u < 1 || u > 1_000_000
      || speed <= 0 || speed > 10_000 || peak <= 0 || peak > 100
      || sharing < 1 || sharing > 1000 || hours <= 0 || hours > 24)
    throw new Error('أدخل قيما منطقية: مشتركون 1–1,000,000، سرعة موجبة، تزامن 1–100%، مشاركة 1–1000، وساعات 1–24.');
  const peakUsers = Math.ceil(u * peak / 100);
  const upstreamMbps = Math.round(peakUsers * speed / sharing * 100) / 100;
  // Decimal TB, assuming the estimated throughput is sustained for N hours each day.
  const monthlyDecimalTb = Math.round((upstreamMbps * hours * 3600 * 30 / 8 / 1_000_000) * 1000) / 1000;
  return { peakUsers, upstreamMbps, monthlyDecimalTb };
}
