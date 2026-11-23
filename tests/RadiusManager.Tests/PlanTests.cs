using RadiusManager.Api;
using Xunit;

public sealed class PlanTests
{
    [Fact]
    public void CorrectRateLimitOrder() => Assert.Equal("256k/1024k", PlanRules.MikroTikRate(256,1024));

    [Theory]
    [InlineData("",1024,256)]
    [InlineData("valid",0,256)]
    [InlineData("valid",1024,-1)]
    public void InvalidPlanIsRejected(string name,int download,int upload) =>
        Assert.NotNull(PlanRules.Validate(new PlanInput(name,download,upload,null,null)));

    [Fact]
    public void QuotaUnitsAreBytes() => Assert.Equal(5242880L, PlanRules.QuotaBytes(5));

    [Fact]
    public void PlanGroupNamesStayStable() => Assert.Equal("plan-00000000000000000000000000000001",PlanRules.GroupName(Guid.Parse("00000000-0000-0000-0000-000000000001")));

    [Fact]
    public void BasicAuthAcceptsCorrectCredentials()
    {
        var h="Basic "+Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("admin:correct-password"));
        Assert.True(AdminBasicAuth.Matches(h,"admin","correct-password"));
        Assert.False(AdminBasicAuth.Matches(h,"admin","incorrect-password"));
    }

    [Fact]
    public void BasicAuthRejectsMalformedInput() => Assert.False(AdminBasicAuth.Matches("Basic not-base64", "admin", "password"));
}
