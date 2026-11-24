using System.Security.Claims;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class DeniedMutationAuditTests
{
    [Theory]
    [InlineData("POST","/api/plans","plan_created")]
    [InlineData("PUT","/api/plans/11111111-1111-4111-8111-111111111111","plan_updated")]
    [InlineData("POST","/api/lab-accounts","voucher_created")]
    [InlineData("POST","/api/lab-accounts/lab_0123456789ab/disable","voucher_disabled")]
    [InlineData("POST","/api/nas-drafts","nas_draft_created")]
    [InlineData("POST","/api/nas-drafts/11111111-1111-4111-8111-111111111111/retire","nas_draft_retired")]
    [InlineData("POST","/api/ownership/accounts/lab_0123456789ab/assign","voucher_owner_assigned")]
    [InlineData("POST","/api/ownership/accounts/lab_0123456789ab/transfer","voucher_owner_transferred")]
    [InlineData("POST","/api/admin-audit",null)]
    [InlineData("GET","/api/plans",null)]
    [InlineData("POST","/api/lab-accounts/external/disable",null)]
    [InlineData("POST","/api/ownership/accounts/lab_0123456789ab/transfer/extra",null)]
    [InlineData("POST","/api/admin/auth/login",null)]
    [InlineData("POST","/api/unknown",null)]
    public void OnlyFixedOperationMetadata(string method,string path,string? expected) =>
        Assert.Equal(expected,DeniedMutationAudit.Operation(method,path));

    [Fact]
    public void OnlyAuthenticatedSingleIdentity()
    {
        var claims = new[]{new Claim(ClaimTypes.NameIdentifier,"reviewer")};
        Assert.Equal("reviewer",DeniedMutationAudit.ActorId(new ClaimsPrincipal(new ClaimsIdentity(claims,"test"))));
        Assert.Null(DeniedMutationAudit.ActorId(new ClaimsPrincipal(new ClaimsIdentity(claims))));
        Assert.Null(DeniedMutationAudit.ActorId(new ClaimsPrincipal(new ClaimsIdentity(claims.Concat(claims),"test"))));
    }
}
