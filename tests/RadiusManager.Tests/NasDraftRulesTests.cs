using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class NasDraftRulesTests
{
    [Theory]
    [InlineData("10.255.70.21")]
    [InlineData("172.16.25.10")]
    [InlineData("172.31.255.254")]
    [InlineData("192.168.12.6")]
    public void AcceptsPrivateVpnAddresses(string ip)
    {
        Assert.True(NasDraftRules.TryPrivateIpv4(ip, out var normalized));
        Assert.Equal(ip, normalized);
    }

    [Theory]
    [InlineData("8.8.8.8")]
    [InlineData("1.1.1.1")]
    [InlineData("127.0.0.1")]
    [InlineData("169.254.10.2")]
    [InlineData("100.64.0.1")]
    [InlineData("172.32.0.1")]
    [InlineData("10.1.2.0")]
    [InlineData("10.1.2.255")]
    [InlineData("10.1.02.3")]
    [InlineData("10.1.2.999")]
    [InlineData("10.1.2.3/24")]
    [InlineData("vpn.example.com")]
    [InlineData("2001:db8::1")]
    [InlineData("10.1.2.3 ")]
    [InlineData("")]
    public void RejectsUnsafeAddresses(string ip)
        => Assert.False(NasDraftRules.TryPrivateIpv4(ip, out _));

    [Fact]
    public void RejectsUnsafeLabelsAndAcceptsArabic()
    {
        Assert.NotNull(NasDraftRules.Validate(null));
        Assert.NotNull(NasDraftRules.Validate(new NasDraftInput("R1", "Test Site", "10.1.2.3")));
        Assert.NotNull(NasDraftRules.Validate(new NasDraftInput("router\nbad", "Test Site", "10.1.2.3")));
        Assert.NotNull(NasDraftRules.Validate(new NasDraftInput("Lab Router", "<script>", "10.1.2.3")));
        Assert.Null(NasDraftRules.Validate(new NasDraftInput("راوتر المختبر", "الموقع التجريبي", "10.255.70.21")));
    }
}
