using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Security.Claims;
using Microsoft.AspNetCore.SignalR;

namespace RadiusManager.Api;

public static class LabStatusHubRules
{
    public const string Policy = "lab-status-read";
    public static bool IsReadRole(string? role) =>
        role is "super-admin" or "noc-operator" or "auditor";

    public static bool CanRead(ClaimsPrincipal? user) =>
        AdminAuthorizationRules.CanAccessSharedLab(user)
        && user!.FindAll(ClaimTypes.Role).Any(c => IsReadRole(c.Value));

    public static bool IsTrustedTransport(bool https, string? origin, string? fetchSite, string? host) =>
        https && !string.IsNullOrWhiteSpace(origin)
        && RequestOriginRules.IsAllowed("POST", origin, fetchSite, "https", host);
}

public sealed record LabStatusSnapshot(string Scope, string Api, string Database,
    double SessionCheckMs, DateTime ObservedAtUtc, RadiusHealthSnapshot Radius);

/// <summary>Bounded, read-only laboratory feed. No NAS actions or subscriber data.</summary>
public sealed class LabStatusHub(IServiceScopeFactory scopes) : Hub
{
    private const string ActiveKey = "lab-status-stream-active";
    private const string LastStartKey = "lab-status-stream-start";
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(10);

    public async IAsyncEnumerable<LabStatusSnapshot> Watch(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var items = Context.Items;
        lock (items)
        {
            if (items.ContainsKey(ActiveKey)
                || (items.TryGetValue(LastStartKey, out var previous)
                    && previous is long ticks && Environment.TickCount64 - ticks < 10_000))
                throw new HubException("Status stream is limited.");
            items[ActiveKey] = true;
            items[LastStartKey] = Environment.TickCount64;
        }
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, Context.ConnectionAborted);
        var ct = linked.Token;
        try
        {
            // A subscription is finite; no replay or background task outlives it.
            for (var i = 0; i < 6; i++)
            {
                if (i != 0) await Task.Delay(Interval, ct);
                // Measure only the authenticated read path, not a network ping or
                // a claim about general PostgreSQL/FreeRADIUS performance.
                var started = Stopwatch.GetTimestamp();
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                var allowed = false;
                try { allowed = await IsCurrentSessionAllowedAsync(deadline.Token); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
                if (!allowed || deadline.IsCancellationRequested)
                {
                    Context.Abort();
                    yield break;
                }
                ct.ThrowIfCancellationRequested();
                var elapsed = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
                yield return new LabStatusSnapshot("lab", "running", "reachable",
                    Math.Round(elapsed, 2), DateTime.UtcNow, RadiusHealthEvidence.Read());
            }
        }
        finally
        {
            lock (items) items.Remove(ActiveKey);
        }
    }

    private async Task<bool> IsCurrentSessionAllowedAsync(CancellationToken ct)
    {
        var principal = Context.User;
        var uid = principal?.FindFirst(ClaimTypes.NameIdentifier)?.Value;
        var token = principal?.FindFirst("radius-session")?.Value;
        if (principal?.Identity?.IsAuthenticated != true
            || string.IsNullOrEmpty(uid) || string.IsNullOrEmpty(token))
            return false;

        // A new scope for each sample. Same role/stamp validation as HTTP,
        // without extending idle expiry from a background subscription.
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<AdminIdentityDbContext>();
        var session = await AdminSessionSecurity.GetCurrentAsync(db, principal, DateTime.UtcNow, ct);
        return session is not null && LabStatusHubRules.CanRead(principal);
    }
}
