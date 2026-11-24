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
    [InlineData("voucher-operator", "PUT", "/api/plans/invalid")]
    [InlineData("voucher-operator", "PUT", "/api/plans/11111111-1111-4111-8111-111111111111/extra")]
    [InlineData("voucher-operator", "POST", "/api/lab-accounts/lab_0123456789ab/extra/disable")]
    [InlineData("voucher-operator", "POST", "/api/lab-accounts/external/disable")]
    [InlineData("auditor", "GET", "/api/lab-accounts/lab_0123456789ab/extra/usage")]
    [InlineData("auditor", "GET", "/api/lab-accounts/lab_0123456789ab\n/usage")]
    [InlineData("voucher-operator", "GET", "/api/service-status/incidents")]
    [InlineData("reseller", "GET", "/api/service-status/incidents")]
    [InlineData("noc-operator", "POST", "/api/service-status/incidents")]
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
    [InlineData("voucher-operator", "PUT", "/api/plans/11111111-1111-4111-8111-111111111111")]
    [InlineData("voucher-operator", "POST", "/api/lab-accounts/lab_0123456789ab/disable")]
    [InlineData("auditor", "GET", "/api/lab-accounts/lab_0123456789ab/usage")]
    [InlineData("noc-operator", "GET", "/api/service-status/incidents")]
    [InlineData("auditor", "GET", "/api/service-status/incidents")]
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

    [Theory]
    [InlineData("super-admin")]
    [InlineData("noc-operator")]
    [InlineData("voucher-operator")]
    [InlineData("auditor")]
    public void ResellerMembershipCannotInheritSharedResources(string otherRole)
    {
        var mixed = Principal("reseller", otherRole);
        Assert.False(AdminAuthorizationRules.IsAllowed(mixed, "GET", "/api/summary"));
        Assert.False(AdminAuthorizationRules.IsAllowed(mixed, "GET", "/api/service-status/incidents"));
        Assert.False(LabStatusHubRules.CanRead(mixed));
    }

    [Fact]
    public void ResellerReadIsIdentityBoundAndDoesNotGrantSharedAccess()
    {
        var user = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role, "reseller"), new Claim(ClaimTypes.NameIdentifier, "owner-a")
        ], "test"));
        Assert.Equal("owner-a", ResellerScope.OwnerId(user));
        Assert.True(AdminAuthorizationRules.IsAllowed(user, "GET", "/api/reseller/accounts"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user, "POST", "/api/reseller/accounts"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user, "GET", "/api/reseller/accounts/other"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user, "GET", "/api/lab-accounts"));
        Assert.False(AdminAuthorizationRules.IsAllowed(Principal("reseller"), "GET", "/api/reseller/accounts"));
        var mixed = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role, "reseller"), new Claim(ClaimTypes.Role, "auditor"),
            new Claim(ClaimTypes.NameIdentifier, "owner-a")
        ], "test"));
        Assert.Null(ResellerScope.OwnerId(mixed));
    }

    [Theory]
    [InlineData("super-admin", true)]
    [InlineData("voucher-operator", false)]
    [InlineData("reseller", false)]
    [InlineData("auditor", false)]
    [InlineData("noc-operator", false)]
    public void OwnershipManagementRequiresNamedSuperAdmin(string role, bool expected)
    {
        var user = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.Role, role), new Claim(ClaimTypes.NameIdentifier, "actor")
        ], "test"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user, "GET", "/api/ownership/resellers"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user, "GET", "/api/ownership/accounts"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user, "POST", "/api/ownership/accounts/lab_0123456789ab/assign"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user, "POST", "/api/ownership/accounts/external/assign"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user, "DELETE", "/api/ownership/accounts/lab_0123456789ab/assign"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user, "POST", "/api/ownership/accounts/lab_0123456789ab/transfer"));
        Assert.Equal(expected, AdminAuthorizationRules.IsAllowed(user, "GET", "/api/ownership/accounts/lab_0123456789ab"));
        Assert.False(AdminAuthorizationRules.IsAllowed(user, "DELETE", "/api/ownership/accounts/lab_0123456789ab/transfer"));
        Assert.False(AdminAuthorizationRules.IsAllowed(Principal("super-admin"), "GET", "/api/ownership/resellers"));
    }

    [Fact]
    public void TransferRequiresDistinctOwnersAndExplicitNonnegativeRevision()
    {
        Assert.True(OwnershipRules.ValidTransfer(new("a", 0, "b")));
        Assert.False(OwnershipRules.ValidTransfer(new("a", null, "b")));
        Assert.False(OwnershipRules.ValidTransfer(new("a", -1, "b")));
        Assert.False(OwnershipRules.ValidTransfer(new("a", long.MaxValue, "b")));
        Assert.False(OwnershipRules.ValidTransfer(new("a", 1, "a")));
        Assert.False(OwnershipRules.ValidTransfer(new("a", 1, " b")));
        Assert.False(OwnershipRules.ValidTransfer(null));
    }

    [Fact]
    public void NoRoleDoesNotInheritAnyAccess() =>
        Assert.False(AdminAuthorizationRules.IsAllowed(Principal(), "GET", "/api/summary"));

    [Fact]
    public void CookieRolesMustExactlyMatchCurrentMembership()
    {
        Assert.True(AdminSessionSecurity.RolesMatch(Principal("auditor", "noc-operator"), ["noc-operator", "auditor"]));
        Assert.False(AdminSessionSecurity.RolesMatch(Principal("super-admin"), ["auditor"]));
        Assert.False(AdminSessionSecurity.RolesMatch(Principal("auditor"), ["auditor", "super-admin"]));
        Assert.False(AdminSessionSecurity.RolesMatch(Principal("super-admin"), []));
        Assert.False(AdminSessionSecurity.RolesMatch(Principal(), []));
    }

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
