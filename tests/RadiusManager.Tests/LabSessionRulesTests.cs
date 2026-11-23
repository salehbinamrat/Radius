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
