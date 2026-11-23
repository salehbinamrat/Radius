using RadiusManager.Api;
using Xunit;

public sealed class LabAccountRulesTests
{
    [Fact]
    public void GeneratedNamesAreValidAndCollisionResistant()
    {
        var names = Enumerable.Range(0, 200).Select(_ => LabAccountRules.GenerateUsername()).ToArray();
        Assert.All(names, name => Assert.True(LabAccountRules.IsLabUsername(name)));
        Assert.Equal(names.Length, names.Distinct().Count());
        Assert.False(LabAccountRules.IsLabUsername("12345678"));
        Assert.False(LabAccountRules.IsLabUsername("lab_abcdefABCDEF"));
    }

    [Fact]
    public void SecretsAreStrongAndNotIdentical()
    {
        var a = LabAccountRules.GeneratePassword();
        var b = LabAccountRules.GeneratePassword();
        Assert.Matches("^[a-f0-9]{48}$", a);
        Assert.NotEqual(a, b);
    }

    [Theory]
    [InlineData(null, null, true)]
    [InlineData(1024L, null, false)]
    [InlineData(null, 30, false)]
    [InlineData(1024L, 30, false)]
    public void UnenforcedLimitsAreForbiddenForLabVouchers(long? quotaBytes,int? days,bool expected) =>
        Assert.Equal(expected, LabAccountRules.PlanIsSafeForLab(quotaBytes, days));
}
