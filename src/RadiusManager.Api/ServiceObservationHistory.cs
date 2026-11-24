namespace RadiusManager.Api;

public sealed record ServiceObservation(DateTimeOffset ObservedAtUtc, string Database,
    double? DatabaseCheckMs, string Radius, DateTime? RadiusCheckedAtUtc);
public sealed record ServiceHistorySnapshot(string Scope, string Retention, int IntervalSeconds,
    int Capacity, ServiceObservation[] Samples);

/// <summary>Bounded observations with optional independent local persistence, not an uptime SLA.</summary>
public sealed class ServiceObservationHistory
{
    public const int Capacity = 240;
    public const int IntervalSeconds = 15;
    private readonly object gate = new();
    private readonly Queue<ServiceObservation> samples = new(Capacity);

    private readonly ServiceHistoryStore? store;
    private bool persistenceHealthy;

    public ServiceObservationHistory() { }

    public ServiceObservationHistory(ServiceHistoryStore store)
    {
        this.store = store;
        persistenceHealthy = store.TryLoad(out var restored);
        foreach (var sample in restored) samples.Enqueue(sample);
    }

    public void Add(ServiceObservation observation)
    {
        lock (gate)
        {
            // Never invent or reorder observations if the wall clock moves backwards.
            if (samples.Count > 0 && observation.ObservedAtUtc < samples.Last().ObservedAtUtc)
                return;
            if (samples.Count == Capacity) samples.Dequeue();
            samples.Enqueue(observation);
            if (store is not null) persistenceHealthy = store.TrySave(samples.ToArray());
        }
    }

    public ServiceHistorySnapshot Snapshot()
    {
        lock (gate)
            return new("lab", store is null ? "process-memory" : persistenceHealthy ? "volume-snapshot" : "storage-degraded",
                IntervalSeconds, Capacity, samples.ToArray());
    }
}
