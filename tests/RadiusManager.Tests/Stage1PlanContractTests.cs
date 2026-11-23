using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

/// <summary>Stage 1 guards: the plan API is a composable module and its policy remains unchanged.</summary>
public sealed class Stage1PlanContractTests
{
    [Fact]
    public void PlanApiHasExplicitRouteRegistration()
    {
        // This intentionally fails to compile until the route extraction is implemented.
        Assert.NotNull(typeof(PlanEndpoints).GetMethod(nameof(PlanEndpoints.MapPlanEndpoints)));
    }

    [Theory]
    [InlineData(256, 1024, "256k/1024k")]
    [InlineData(512, 3072, "512k/3072k")]
    public void RateLimitPreservesMikrotikUploadDownloadOrder(int upload, int download, string expected)
        => Assert.Equal(expected, PlanRules.MikroTikRate(upload, download));

    [Fact]
    public void LabPlanWithoutQuotaOrValidityIsValid()
        => Assert.Null(PlanRules.Validate(new PlanInput("Offline lab", 1024, 256, null, null)));

    [Theory]
    [InlineData(63, 256)]
    [InlineData(1024, 63)]
    [InlineData(1000001, 256)]
    public void InvalidSpeedNeverReachesDatabase(int down, int up)
        => Assert.NotNull(PlanRules.Validate(new PlanInput("Lab", down, up, null, null)));

    [Fact]
    public void QuotaUnitAndGroupIdentityRemainStable()
    {
        var id = Guid.Parse("d6e2ce7e-e82d-4a9f-87bf-9b555690e579");
        Assert.Equal("plan-d6e2ce7ee82d4a9f87bf9b555690e579", PlanRules.GroupName(id));
        Assert.Equal(1048576L, PlanRules.QuotaBytes(1));
    }
}
