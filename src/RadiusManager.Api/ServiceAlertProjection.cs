namespace RadiusManager.Api;

public sealed record ServiceAlertState(string Service, string State, string Severity, DateTimeOffset? LastEvidenceAtUtc);
public sealed record ServiceAlertEvent(string Service, string Kind, string Severity, DateTimeOffset ConfirmedAtUtc);
public sealed record ServiceAlertSnapshot(string Scope, string Window, int ConfirmationCount,
    ServiceAlertState[] Services, ServiceAlertEvent[] Events);

/// <summary>Deterministic read-only projection of retained observations.</summary>
public static class ServiceAlertProjection
{
    public static ServiceAlertSnapshot Build(ServiceObservation[] samples, DateTimeOffset now)
    {
        var events = new List<ServiceAlertEvent>();
        var database = ServiceAlertCursor.Empty;
        var radius = ServiceAlertCursor.Empty;
        foreach (var sample in samples)
        {
            if (sample.ObservedAtUtc > now) continue;
            database = ServiceAlertRules.Advance(database, sample, false, out var dbEvent);
            radius = ServiceAlertRules.Advance(radius, sample, true, out var radiusEvent);
            if (dbEvent is not null) events.Add(dbEvent);
            if (radiusEvent is not null) events.Add(radiusEvent);
        }
        return new("lab", "retained-samples", ServiceAlertRules.ConfirmationCount,
            [ServiceAlertRules.State(database, false, now), ServiceAlertRules.State(radius, true, now)],
            events.OrderBy(x => x.ConfirmedAtUtc).ThenBy(x => x.Service, StringComparer.Ordinal).ToArray());
    }
}
