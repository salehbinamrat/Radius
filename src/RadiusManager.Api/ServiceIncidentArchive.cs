namespace RadiusManager.Api;

public sealed record ServiceIncident(Guid Id, string Service, DateTimeOffset FailureConfirmedAtUtc,
    DateTimeOffset? RecoveryConfirmedAtUtc);
public sealed record ServiceIncidentCheckpoint(ServiceAlertCursor Database, ServiceAlertCursor Radius,
    ServiceIncident[] Incidents);
public sealed record ServiceIncidentSnapshot(string Scope, string Retention, int ClosedCapacity,
    ServiceAlertState[] Services, ServiceIncident[] Incidents);

/// <summary>Single-worker archive. Open incidents survive eviction of ordinary monitoring samples.</summary>
public sealed class ServiceIncidentArchive
{
    public const int ClosedCapacity = 256;
    private readonly object gate = new();
    private readonly ServiceIncidentStore? store;
    private ServiceIncidentCheckpoint checkpoint = new(ServiceAlertCursor.Empty, ServiceAlertCursor.Empty, []);
    private bool persistenceHealthy;

    public ServiceIncidentArchive() { }
    public ServiceIncidentArchive(ServiceIncidentStore store)
    {
        this.store = store;
        persistenceHealthy = store.TryLoad(out var restored);
        if (restored is not null) checkpoint = restored;
    }

    public void Observe(ServiceObservation sample)
    {
        lock (gate)
        {
            if (checkpoint.Database.LastObservation is DateTimeOffset previous && sample.ObservedAtUtc <= previous)
                return;
            var database = ServiceAlertRules.Advance(checkpoint.Database, sample, false, out var dbEvent);
            var radius = ServiceAlertRules.Advance(checkpoint.Radius, sample, true, out var radiusEvent);
            var rows = checkpoint.Incidents.ToList();
            Apply(rows, dbEvent);
            Apply(rows, radiusEvent);
            var retained = rows.Where(x => x.RecoveryConfirmedAtUtc is not null)
                .OrderByDescending(x => x.RecoveryConfirmedAtUtc).Take(ClosedCapacity)
                .Concat(rows.Where(x => x.RecoveryConfirmedAtUtc is null))
                .OrderBy(x => x.FailureConfirmedAtUtc).ThenBy(x => x.Id).ToArray();
            checkpoint = new(database, radius, retained);
            if (store is not null) persistenceHealthy = store.TrySave(checkpoint);
        }
    }

    private static void Apply(List<ServiceIncident> rows, ServiceAlertEvent? transition)
    {
        if (transition is null) return;
        var index = rows.FindIndex(x => x.Service == transition.Service && x.RecoveryConfirmedAtUtc is null);
        if (transition.Kind == "failure-confirmed" && index < 0)
            rows.Add(new(Guid.NewGuid(), transition.Service, transition.ConfirmedAtUtc, null));
        else if (transition.Kind == "recovery-confirmed" && index >= 0)
            rows[index] = rows[index] with { RecoveryConfirmedAtUtc = transition.ConfirmedAtUtc };
    }

    public ServiceIncidentSnapshot Snapshot(DateTimeOffset now)
    {
        lock (gate)
            return new("lab", store is null ? "process-memory" : persistenceHealthy ? "volume-snapshot" : "storage-degraded",
                ClosedCapacity, [ServiceAlertRules.State(checkpoint.Database, false, now),
                    ServiceAlertRules.State(checkpoint.Radius, true, now)], checkpoint.Incidents.ToArray());
    }
}
