using System.Security.Claims;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class AdminSecurityRulesTests
{
    private static ClaimsPrincipal Principal(params string[] roles)
    {
        var claims = roles.Select(x => new Claim(ClaimTypes.Role, x));
        return new ClaimsPrincipal(new ClaimsIdentity(claims, "test"));
    }

    [Theory]
    [InlineData("GET", "/api/summary")]
    [InlineData("POST", "/api/plans")]
    [InlineData("DELETE", "/api/plans/unused")]
    public void SuperAdminCanPerformOperatorActions(string method, string path) =>
        Assert.True(AdminAuthorizationRules.IsAllowed(Principal("super-admin"), method, path));

    [Theory]
    [InlineData("voucher-operator", "GET", "/api/service-status/alerts")]
    [InlineData("reseller", "GET", "/api/service-status/alerts")]
    [InlineData("noc-operator", "POST", "/api/service-status/alerts")]
    [InlineData("voucher-operator", "GET", "/api/service-status/history")]
    [InlineData("reseller", "GET", "/api/service-status/history")]
    [InlineData("noc-operator", "POST", "/api/service-status/history")]
    [InlineData("noc-operator", "POST", "/api/nas-drafts")]
    [InlineData("auditor", "POST", "/api/plans")]
    [InlineData("reseller", "GET", "/api/lab-accounts")]
    [InlineData("voucher-operator", "POST", "/api/nas-drafts")]
    [InlineData("noc-operator", "POST", "/api/lab-accounts")]
    public void LeastPrivilegeAndMissingOwnershipDenyByDefault(string role, string method, string path) =>
        Assert.False(AdminAuthorizationRules.IsAllowed(Principal(role), method, path));

    [Theory]
    [InlineData("noc-operator", "GET", "/api/service-status/alerts")]
    [InlineData("auditor", "GET", "/api/service-status/alerts")]
    [InlineData("noc-operator", "GET", "/api/service-status/history")]
    [InlineData("auditor", "GET", "/api/service-status/history")]
    [InlineData("noc-operator", "GET", "/api/lab-sessions")]
    [InlineData("voucher-operator", "GET", "/api/lab-accounts")]
    [InlineData("voucher-operator", "POST", "/api/lab-accounts")]
    [InlineData("auditor", "GET", "/api/summary")]
    public void ExplicitAllowList(string role, string method, string path) =>
        Assert.True(AdminAuthorizationRules.IsAllowed(Principal(role), method, path));

    [Fact]
    public void NoRoleDoesNotInheritAnyAccess() =>
        Assert.False(AdminAuthorizationRules.IsAllowed(Principal(), "GET", "/api/summary"));

    [Fact]
    public void SessionSecretUsesRandomMaterialAndOneWayDigest()
    {
        var a = AdminSessionSecurity.NewToken();
        var b = AdminSessionSecurity.NewToken();
        Assert.NotEqual(a, b);
        Assert.Equal(64, a.Length);
        Assert.Equal(64, AdminSessionSecurity.HashToken(a).Length);
        Assert.NotEqual(a, AdminSessionSecurity.HashToken(a));
        Assert.Equal(AdminSessionSecurity.HashToken(a), AdminSessionSecurity.HashToken(a));
    }
}
