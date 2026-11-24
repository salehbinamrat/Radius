namespace RadiusManager.Api;

public sealed record ServiceAlertCursor(DateTimeOffset? LastObservation, DateTimeOffset? LastEvidence,
    int Failures, int Successes, bool IncidentOpen, string State)
{
    public static ServiceAlertCursor Empty { get; } = new(null, null, 0, 0, false, "unknown");
}

/// <summary>Single confirmation algorithm for the retained-window view and durable incident archive.</summary>
public static class ServiceAlertRules
{
    public const int ConfirmationCount = 2;
    private static readonly TimeSpan MaxGap = TimeSpan.FromSeconds(35);
    public static string Service(bool radius) => radius ? "freeradius" : "postgresql";

    public static ServiceAlertCursor Advance(ServiceAlertCursor cursor, ServiceObservation sample,
        bool radius, out ServiceAlertEvent? transition)
    {
        transition = null;
        var observed = sample.ObservedAtUtc;
        if (cursor.LastObservation is DateTimeOffset previous && observed <= previous)
            return cursor;
        if (cursor.LastObservation is DateTimeOffset priorObservation && observed - priorObservation > MaxGap)
            cursor = Reset(cursor);
        cursor = cursor with { LastObservation = observed };
        var value = radius ? sample.Radius : sample.Database;
        DateTimeOffset? evidence = radius
            ? sample.RadiusCheckedAtUtc is DateTime at && at.Kind == DateTimeKind.Utc
                ? new DateTimeOffset(at) : null
            : observed;
        if (value == "unknown" || evidence is null || evidence > observed
            || observed - evidence.Value > MaxGap)
            return Reset(cursor);
        if (cursor.LastEvidence is DateTimeOffset prior && evidence.Value <= prior)
            return cursor;
        if (cursor.LastEvidence is DateTimeOffset earlier && evidence.Value - earlier > MaxGap)
            cursor = Reset(cursor);
        cursor = cursor with { LastEvidence = evidence };
        if (value == "no-response")
        {
            var count = Math.Min(ConfirmationCount, cursor.Failures + 1);
            if (count == ConfirmationCount && !cursor.IncidentOpen)
                transition = new(Service(radius), "failure-confirmed", "critical", observed);
            return cursor with { Failures = count, Successes = 0,
                IncidentOpen = cursor.IncidentOpen || count == ConfirmationCount,
                State = count == ConfirmationCount ? "failed" : "pending" };
        }
        if (value == (radius ? "responsive" : "reachable"))
        {
            var count = Math.Min(ConfirmationCount, cursor.Successes + 1);
            if (count == ConfirmationCount && cursor.IncidentOpen)
                transition = new(Service(radius), "recovery-confirmed", "info", observed);
            return cursor with { Successes = count, Failures = 0,
                IncidentOpen = cursor.IncidentOpen && count != ConfirmationCount,
                State = count == ConfirmationCount ? "healthy" : "pending" };
        }
        return Reset(cursor);
    }

    private static ServiceAlertCursor Reset(ServiceAlertCursor cursor) =>
        cursor with { Failures = 0, Successes = 0, State = "unknown" };

    public static ServiceAlertState State(ServiceAlertCursor cursor, bool radius, DateTimeOffset now)
    {
        var state = cursor.State;
        if (cursor.LastEvidence is not DateTimeOffset evidence || now < evidence || now - evidence > MaxGap
            || cursor.LastObservation is not DateTimeOffset observed || now < observed || now - observed > MaxGap)
            state = "unknown";
        return new(Service(radius), state, state switch
        {
            "failed" => "critical", "pending" or "unknown" => "warning", _ => "info"
        }, cursor.LastEvidence);
    }
}
