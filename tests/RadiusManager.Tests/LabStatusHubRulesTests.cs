using System.Security.Claims;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class LabStatusHubRulesTests
{
    [Theory]
    [InlineData("super-admin", true)]
    [InlineData("noc-operator", true)]
    [InlineData("auditor", true)]
    [InlineData("voucher-operator", false)]
    [InlineData("reseller", false)]
    [InlineData("unknown", false)]
    public void RolesAreExplicit(string role, bool expected) =>
        Assert.Equal(expected, LabStatusHubRules.IsReadRole(role));

    [Theory]
    [InlineData(true, "https://localhost:18443", "same-origin", true)]
    [InlineData(true, "https://evil.invalid", "same-origin", false)]
    [InlineData(true, "https://localhost:18443", "cross-site", false)]
    [InlineData(true, null, null, false)]
    [InlineData(false, "https://localhost:18443", "same-origin", false)]
    [InlineData(true, "https://localhost:18443/path", "same-origin", false)]
    public void OriginGuardAlsoAppliesToWebSocketGet(bool https, string? origin, string? site, bool expected) =>
        Assert.Equal(expected, LabStatusHubRules.IsTrustedTransport(https, origin, site, "localhost:18443"));

    [Fact]
    public void SnapshotContainsOnlyAllowlistedServerHealthFields()
    {
        var now = DateTime.UtcNow;
        var snapshot = new LabStatusSnapshot("lab", "running", "reachable", 12.34, now, new RadiusHealthSnapshot("unknown", null));
        Assert.Equal("lab", snapshot.Scope);
        Assert.Equal("running", snapshot.Api);
        Assert.Equal("reachable", snapshot.Database);
        Assert.Equal(12.34, snapshot.SessionCheckMs);
        Assert.Equal(now, snapshot.ObservedAtUtc);
        Assert.Equal("unknown", snapshot.Radius.State);
    }
}
