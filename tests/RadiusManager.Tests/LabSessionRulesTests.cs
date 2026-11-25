using RadiusManager.Api;
using Xunit;

public sealed class LabSessionRulesTests
{
    [Theory]
    [InlineData("all", null)]
    [InlineData("open", "lab_123456abcdef")]
    [InlineData("closed", "lab_0123456789ab")]
    [InlineData("stale", "")]
    public void SupportedFiltersAreAccepted(string state, string? username) =>
        Assert.Null(LabSessionRules.Validate(state, username));

    [Theory]
    [InlineData("invalid", "")]
    [InlineData("all", "production-card")]
    [InlineData("all", "lab_123456789abZ")]
    [InlineData("all", "lab_123456789abc' OR 1=1 --")]
    public void UnsupportedStateAndNonLabUsernamesRejected(string state, string username) =>
        Assert.NotNull(LabSessionRules.Validate(state, username));

    [Fact]
    public void ObservationTimestampUsesPostgreSqlMicrosecondPrecision()
    {
        var input = new DateTime(2026, 11, 25, 0, 0, 0, DateTimeKind.Utc).AddTicks(17);
        var observed = LabSessionRules.NormalizeObservationTime(input);
        Assert.Equal(DateTimeKind.Utc, observed.Kind);
        Assert.Equal(input.AddTicks(-7), observed);
    }

    [Fact]
    public void StaleBoundaryUsesStrictlyOlderThanTenMinutes()
    {
        var observed = new DateTime(2026, 11, 25, 0, 0, 0, DateTimeKind.Utc);
        var cutoff = LabSessionRules.StaleCutoff(observed);
        Assert.Equal(observed.AddMinutes(-10), cutoff);
        Assert.Equal("stale", LabSessionRules.Classify(null, cutoff.AddTicks(-10), false, observed));
        Assert.Equal("open-unconfirmed", LabSessionRules.Classify(null, cutoff, false, observed));
        Assert.Equal("open-unconfirmed", LabSessionRules.Classify(null, cutoff.AddTicks(10), false, observed));
        Assert.Equal("anomaly", LabSessionRules.Classify(null, cutoff, true, observed));
        Assert.Equal("closed", LabSessionRules.Classify(observed, cutoff, false, observed));
    }

    [Theory]
    [InlineData(false, 1, false, "closed")]
    [InlineData(true, 2, false, "open-unconfirmed")]
    [InlineData(true, 12, false, "stale")]
    [InlineData(true, 2, true, "anomaly")]
    public void SessionStatusNeverClaimsSomeoneIsConnected(bool open, int ageMinutes, bool anomaly, string expected)
    {
        var now=DateTime.UtcNow;
        Assert.Equal(expected, LabSessionRules.Classify(open ? null : now, now.AddMinutes(-ageMinutes), anomaly, now));
    }
}
