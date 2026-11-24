using System.Security.Claims;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class LabMutationAuditTests
{
    [Theory]
    [InlineData(LabMutation.PlanCreated, "plan_created", "plan")]
    [InlineData(LabMutation.PlanUpdated, "plan_updated", "plan")]
    [InlineData(LabMutation.VoucherCreated, "voucher_created", "lab_account")]
    [InlineData(LabMutation.VoucherDisabled, "voucher_disabled", "lab_account")]
    [InlineData(LabMutation.NasDraftCreated, "nas_draft_created", "nas_draft")]
    [InlineData(LabMutation.NasDraftRetired, "nas_draft_retired", "nas_draft")]
    public void FixedActionAndSubject(LabMutation mutation, string action, string kind) =>
        Assert.Equal((action, kind), LabMutationAudit.Describe(mutation));

    [Fact]
    public void BasicNeverClaimsNamedActorAndSessionRequiresVerifiedIdentity()
    {
        var verified = new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.NameIdentifier, "actor")], "test"));
        var missing = new ClaimsPrincipal(new ClaimsIdentity([], "test"));
        var duplicate = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.NameIdentifier, "actor"), new Claim(ClaimTypes.NameIdentifier, "other")], "test"));
        Assert.Equal("actor", LabMutationAudit.ActorId(verified, true));
        Assert.Null(LabMutationAudit.ActorId(verified, false));
        Assert.Throws<InvalidOperationException>(() => LabMutationAudit.ActorId(missing, true));
        Assert.Throws<InvalidOperationException>(() => LabMutationAudit.ActorId(duplicate, true));
    }
}
