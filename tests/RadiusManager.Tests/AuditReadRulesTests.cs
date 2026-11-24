using System.Security.Claims;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class AuditReadRulesTests
{
    [Theory]
    [InlineData("super-admin", true)]
    [InlineData("auditor", true)]
    [InlineData("voucher-operator", false)]
    [InlineData("reseller", false)]
    [InlineData("noc-operator", false)]
    public void AuditReadRequiresNamedSuperAdminOrReviewer(string role, bool expected)
    {
        var user = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role,role), new Claim(ClaimTypes.NameIdentifier,"actor")
        ],"test"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user,"GET","/api/admin-audit"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user,"POST","/api/admin-audit"));
    }

    [Theory]
    [InlineData("super-admin")]
    [InlineData("voucher-operator")]
    [InlineData("noc-operator")]
    [InlineData("reseller")]
    public void MixedReviewerCannotInheritSharedPrivileges(string otherRole)
    {
        var user = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role,"auditor"), new Claim(ClaimTypes.Role,otherRole),
            new Claim(ClaimTypes.NameIdentifier,"actor")
        ],"test"));
        Assert.Null(AuditReadRules.ActorId(user));
        Assert.False(AdminAuthorizationRules.IsAllowed(user,"GET","/api/admin-audit"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user,"POST","/api/plans"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user,"GET","/api/ownership/accounts"));
        Assert.False(LabStatusHubRules.CanRead(user));
    }

    [Fact]
    public void ReviewerRequiresSingleVerifiedIdentifier()
    {
        var missing = new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.Role,"auditor")],"test"));
        var duplicate = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role,"auditor"), new Claim(ClaimTypes.NameIdentifier,"one"),
            new Claim(ClaimTypes.NameIdentifier,"two")],"test"));
        Assert.Null(AuditReadRules.ActorId(missing));
        Assert.Null(AuditReadRules.ActorId(duplicate));
    }

    [Theory]
    [InlineData("2026-11-24",true)]
    [InlineData("2026-02-30",false)]
    [InlineData("2026-1-1",false)]
    [InlineData("9999-12-31",false)]
    public void DateFilterIsStrictUtc(string value,bool valid)
    {
        Assert.Equal(valid,AuditReadRules.TryDate(value,out var date));
        if(valid) Assert.Equal(DateTimeKind.Utc,date!.Value.Kind);
    }
}
