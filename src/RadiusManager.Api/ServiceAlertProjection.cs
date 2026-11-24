namespace RadiusManager.Api;

public sealed record ServiceAlertState(string Service, string State, string Severity, DateTimeOffset? LastEvidenceAtUtc);
public sealed record ServiceAlertEvent(string Service, string Kind, string Severity, DateTimeOffset ConfirmedAtUtc);
public sealed record ServiceAlertSnapshot(string Scope, string Window, int ConfirmationCount,
    ServiceAlertState[] Services, ServiceAlertEvent[] Events);

/// <summary>Deterministic, read-only projection of retained observations. No external notifications.</summary>
public static class ServiceAlertProjection
{
    private const int ConfirmationCount = 2;
    private static readonly TimeSpan MaxGap = TimeSpan.FromSeconds(35);

    public static ServiceAlertSnapshot Build(ServiceObservation[] samples, DateTimeOffset now)
    {
        var events = new List<ServiceAlertEvent>();
        var states = new[]
        {
            Project("postgresql", samples, now, events, false),
            Project("freeradius", samples, now, events, true)
        };
        return new("lab", "retained-samples", ConfirmationCount, states,
            events.OrderBy(x => x.ConfirmedAtUtc).ThenBy(x => x.Service, StringComparer.Ordinal).ToArray());
    }

    private static ServiceAlertState Project(string service, ServiceObservation[] samples,
        DateTimeOffset now, List<ServiceAlertEvent> events, bool radius)
    {
        DateTimeOffset? previousObservation = null;
        DateTimeOffset? previousEvidence = null;
        int failures = 0, successes = 0;
        bool incident = false;
        string state = "unknown";
        foreach (var sample in samples)
        {
            var observed = sample.ObservedAtUtc;
            if (observed > now) continue;
            if (previousObservation is DateTimeOffset previous
                && (observed < previous || observed - previous > MaxGap))
            {
                failures = successes = 0;
                state = "unknown";
            }
            previousObservation = observed;
            var value = radius ? sample.Radius : sample.Database;
            DateTimeOffset? evidence = radius
                ? sample.RadiusCheckedAtUtc is DateTime at && at.Kind == DateTimeKind.Utc
                    ? new DateTimeOffset(at) : null
                : observed;
            if (value == "unknown" || evidence is null || evidence > observed
                || observed - evidence.Value > MaxGap)
            {
                failures = successes = 0;
                state = "unknown";
                continue;
            }
            // Several API samples may refer to the same RADIUS probe. Count it once.
            if (previousEvidence is DateTimeOffset prior && evidence.Value <= prior) continue;
            if (previousEvidence is DateTimeOffset earlier && evidence.Value - earlier > MaxGap)
            {
                failures = successes = 0;
                state = "unknown";
            }
            previousEvidence = evidence;
            if (value == "no-response")
            {
                successes = 0;
                failures = Math.Min(ConfirmationCount, failures + 1);
                if (failures == ConfirmationCount)
                {
                    state = "failed";
                    if (!incident)
                    {
                        incident = true;
                        events.Add(new(service, "failure-confirmed", "critical", observed));
                    }
                }
                else state = "pending";
            }
            else if (value == (radius ? "responsive" : "reachable"))
            {
                failures = 0;
                successes = Math.Min(ConfirmationCount, successes + 1);
                if (successes == ConfirmationCount)
                {
                    state = "healthy";
                    if (incident)
                    {
                        incident = false;
                        events.Add(new(service, "recovery-confirmed", "info", observed));
                    }
                }
                else state = "pending";
            }
            else
            {
                failures = successes = 0;
                state = "unknown";
            }
        }
        if (previousEvidence is null || now - previousEvidence.Value > MaxGap
            || previousObservation is null || now - previousObservation.Value > MaxGap)
            state = "unknown";
        return new(service, state, state switch
        {
            "failed" => "critical",
            "pending" or "unknown" => "warning",
            _ => "info"
        }, previousEvidence);
    }
}
