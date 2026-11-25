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

    [Theory]
    [InlineData("a\0b")]
    [InlineData("a\nb")]
    [InlineData("a\rb")]
    [InlineData("a\tb")]
    [InlineData("a\u007fb")]
    [InlineData("a\u0085b")]
    public void EmbeddedControlCharactersAreRejected(string name) =>
        Assert.NotNull(PlanRules.Validate(new PlanInput(name, 1024, 256, null, null)));

    [Theory]
    [InlineData("باقة الإنترنت")]
    [InlineData("باقة 5 GB")]
    [InlineData("  باقة تجريبية  ")]
    public void ValidArabicAndTrimmedNamesRemainAccepted(string name) =>
        Assert.Null(PlanRules.Validate(new PlanInput(name, 1024, 256, null, null)));

    [Fact]
    public void ExistingPlanNameLengthLimitsArePreserved()
    {
        Assert.Null(PlanRules.Validate(new PlanInput(new string('a', 80), 1024, 256, null, null)));
        Assert.NotNull(PlanRules.Validate(new PlanInput(new string('a', 81), 1024, 256, null, null)));
        Assert.NotNull(PlanRules.Validate(new PlanInput(null!, 1024, 256, null, null)));
    }

    [Theory]
    [InlineData(64, 64, 1, 1)]
    [InlineData(1000000, 1000000, 100000000, 3650)]
    public void ExistingValidNumericBoundariesRemainAccepted(int down, int up, long quota, int days) =>
        Assert.Null(PlanRules.Validate(new PlanInput("باقة", down, up, quota, days)));

    [Theory]
    [InlineData(63, 64, 1, 1)]
    [InlineData(64, 1000001, 1, 1)]
    [InlineData(64, 64, 0, 1)]
    [InlineData(64, 64, 100000001, 1)]
    [InlineData(64, 64, 1, 0)]
    [InlineData(64, 64, 1, 3651)]
    public void InvalidNumericBoundariesRemainRejected(int down, int up, long quota, int days) =>
        Assert.NotNull(PlanRules.Validate(new PlanInput("باقة", down, up, quota, days)));

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
