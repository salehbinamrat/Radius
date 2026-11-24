namespace RadiusManager.Api;

public sealed record ServiceObservation(DateTimeOffset ObservedAtUtc, string Database,
    double? DatabaseCheckMs, string Radius, DateTime? RadiusCheckedAtUtc);
public sealed record ServiceHistorySnapshot(string Scope, string Retention, int IntervalSeconds,
    int Capacity, ServiceObservation[] Samples);

/// <summary>Process-local observations, not a billing ledger or an uptime SLA.</summary>
public sealed class ServiceObservationHistory
{
    public const int Capacity = 240;
    public const int IntervalSeconds = 15;
    private readonly object gate = new();
    private readonly Queue<ServiceObservation> samples = new(Capacity);

    public void Add(ServiceObservation observation)
    {
        lock (gate)
        {
            if (samples.Count == Capacity) samples.Dequeue();
            samples.Enqueue(observation);
        }
    }

    public ServiceHistorySnapshot Snapshot()
    {
        lock (gate)
            return new("lab", "process-memory", IntervalSeconds, Capacity, samples.ToArray());
    }
}
