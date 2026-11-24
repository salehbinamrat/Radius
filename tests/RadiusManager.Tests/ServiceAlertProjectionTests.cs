using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class ServiceAlertProjectionTests
{
    private static readonly DateTimeOffset Start = DateTimeOffset.FromUnixTimeSeconds(1800000000);
    private static ServiceObservation Sample(int seconds, string database = "reachable",
        string radius = "unknown", int? radiusSecond = null) =>
        new(Start.AddSeconds(seconds), database, database == "reachable" ? 2 : null, radius,
            radiusSecond is int t ? Start.AddSeconds(t).UtcDateTime : null);

    [Fact]
    public void RequiresTwoFailuresAndTwoSuccessesWithoutDuplicateEvents()
    {
        ServiceObservation[] samples =
        [
            Sample(0), Sample(15), Sample(30, "no-response"), Sample(45, "no-response"),
            Sample(60, "no-response"), Sample(75), Sample(90), Sample(105)
        ];
        var snapshot = ServiceAlertProjection.Build(samples, Start.AddSeconds(105));
        Assert.Equal("healthy", snapshot.Services[0].State);
        Assert.Collection(snapshot.Events,
            e => { Assert.Equal("failure-confirmed", e.Kind); Assert.Equal(Start.AddSeconds(45), e.ConfirmedAtUtc); },
            e => { Assert.Equal("recovery-confirmed", e.Kind); Assert.Equal(Start.AddSeconds(90), e.ConfirmedAtUtc); });
        Assert.Equal(snapshot.Events, ServiceAlertProjection.Build(samples, Start.AddSeconds(105)).Events);
    }

    [Fact]
    public void UnknownAndGapsBreakConfirmationAndDoNotClaimRecovery()
    {
        var interrupted = ServiceAlertProjection.Build(
            [Sample(0, "no-response"), Sample(15, "unknown"), Sample(30, "no-response")],
            Start.AddSeconds(30));
        Assert.Empty(interrupted.Events);
        Assert.Equal("pending", interrupted.Services[0].State);
        var gap = ServiceAlertProjection.Build(
            [Sample(0, "no-response"), Sample(60, "no-response")], Start.AddSeconds(60));
        Assert.Empty(gap.Events);
        var active = ServiceAlertProjection.Build(
            [Sample(0, "no-response"), Sample(15, "no-response"), Sample(30, "unknown"), Sample(45)],
            Start.AddSeconds(45));
        Assert.Single(active.Events);
        Assert.Equal("pending", active.Services[0].State);
    }

    [Fact]
    public void RepeatedRadiusEvidenceCannotConfirmFailure()
    {
        var repeated = ServiceAlertProjection.Build(
            [Sample(15, radius: "no-response", radiusSecond: 15),
             Sample(30, radius: "no-response", radiusSecond: 15)], Start.AddSeconds(30));
        Assert.Empty(repeated.Events);
        Assert.Equal("pending", repeated.Services[1].State);
        var confirmed = ServiceAlertProjection.Build(
            [Sample(15, radius: "no-response", radiusSecond: 15),
             Sample(30, radius: "no-response", radiusSecond: 15),
             Sample(45, radius: "no-response", radiusSecond: 40)], Start.AddSeconds(45));
        Assert.Equal("failed", confirmed.Services[1].State);
        Assert.Equal("freeradius", Assert.Single(confirmed.Events).Service);
    }

    [Fact]
    public void StaleAndEmptyHistoryAreUnknownNotHealthyOrRecovered()
    {
        var stale = ServiceAlertProjection.Build(
            [Sample(0, "no-response"), Sample(15, "no-response")], Start.AddSeconds(60));
        Assert.Equal("unknown", stale.Services[0].State);
        Assert.Equal("failure-confirmed", Assert.Single(stale.Events).Kind);
        var empty = ServiceAlertProjection.Build([], Start);
        Assert.All(empty.Services, state => Assert.Equal("unknown", state.State));
        Assert.Empty(empty.Events);
    }
}
