export interface CapacityInput {
  users: number;
  averageMbps: number;
  peakConcurrencyPercent: number;
  contentionRatio: number;
  dailyPeakEquivalentHours: number;
}
export interface CapacityEstimate {
  peakUsers: number;
  upstreamMbps: number;
  monthlyDecimalTb: number;
}
export declare function estimateCapacity(input: CapacityInput): CapacityEstimate;
