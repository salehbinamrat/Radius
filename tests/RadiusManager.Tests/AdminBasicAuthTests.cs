using System.Text;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class AdminBasicAuthTests
{
    private static string Header(byte[] bytes) => "Basic " + Convert.ToBase64String(bytes);

    [Fact]
    public void InvalidUtf8DoesNotAuthenticateAsReplacementCharacter()
    {
        var malformed = Header([0x61, 0x3a, 0xff]);
        var valid = Header(Encoding.UTF8.GetBytes("a:\uFFFD"));
        Assert.False(AdminBasicAuth.Matches(malformed, "a", "\uFFFD"));
        Assert.True(AdminBasicAuth.Matches(valid, "a", "\uFFFD"));
        Assert.False(AdminBasicAuth.Matches(Header([0xff, 0x3a, 0x70]), "\uFFFD", "p"));
    }

    [Fact]
    public void ValidUnicodeAndColonsInPasswordRemainSupported()
    {
        var header = Header(Encoding.UTF8.GetBytes("مدير:كلمة:مرور"));
        Assert.True(AdminBasicAuth.Matches(header, "مدير", "كلمة:مرور"));
        Assert.False(AdminBasicAuth.Matches(header, "مدير", "كلمةمرور"));
        Assert.False(AdminBasicAuth.Matches(header, "مشغل", "كلمة:مرور"));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Basic")]
    [InlineData("Basic not-base64")]
    [InlineData("Bearer YTpw")]
    [InlineData("Basic YQ==")]
    [InlineData("Basic OnA=")]
    public void InvalidHeadersAreRejected(string? header) =>
        Assert.False(AdminBasicAuth.Matches(header, "a", "p"));

    [Fact]
    public void SchemeRemainsCaseInsensitive() =>
        Assert.True(AdminBasicAuth.Matches("bAsIc YTpw", "a", "p"));

    [Fact]
    public void DistinctByteSequencesAreNotNormalized()
    {
        Assert.False(AdminBasicAuth.Matches(Header(Encoding.UTF8.GetBytes("a:e\u0301")), "a", "\u00e9"));
        Assert.False(AdminBasicAuth.Matches(Header([0x61, 0x3a, 0xc0, 0xaf]), "a", "/"));
    }
}
