using System.Security.Claims;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class AuditReadRulesTests
{
    [Theory]
    [InlineData("super-admin", true)]
    [InlineData("auditor", false)]
    [InlineData("reseller", false)]
    [InlineData("noc-operator", false)]
    public void AuditReadRequiresNamedSuperAdmin(string role, bool expected)
    {
        var user = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role,role), new Claim(ClaimTypes.NameIdentifier,"actor")
        ],"test"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user,"GET","/api/admin-audit"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user,"POST","/api/admin-audit"));
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
