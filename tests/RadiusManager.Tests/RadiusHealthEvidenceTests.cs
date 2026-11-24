using System.Text;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class RadiusHealthEvidenceTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1800000000);

    [Theory]
    [InlineData(0, "responsive", "responsive")]
    [InlineData(35, "no-response", "no-response")]
    [InlineData(36, "responsive", "unknown")]
    [InlineData(-1, "responsive", "unknown")]
    [InlineData(0, "fake", "unknown")]
    public void OnlyFreshAllowlistedEvidence(int age, string state, string expected)
    {
        var result = RadiusHealthEvidence.Parse($"{Now.ToUnixTimeSeconds() - age} {state}\n", Now);
        Assert.Equal(expected, result.State);
        Assert.Equal(expected == "unknown", result.CheckedAtUtc is null);
    }

    [Fact]
    public void ReaderAcceptsShortEvidenceWithoutRequiringAnEightyOneByteFile()
    {
        using var stream = new MemoryStream(Encoding.ASCII.GetBytes("1800000000 responsive\n"));
        Assert.Equal(new RadiusHealthSnapshot("responsive", Now.UtcDateTime),
            RadiusHealthEvidence.Read(stream, Now));
    }

    [Fact]
    public void ReaderRejectsOversizedEvidenceAndDoesNotConsumeUnboundedInput()
    {
        using var stream = new MemoryStream(new byte[10000]);
        Assert.Equal(new RadiusHealthSnapshot("unknown", null), RadiusHealthEvidence.Read(stream, Now));
        Assert.Equal(81L, stream.Position);
    }

    [Fact]
    public void ReaderRejectsAnEmptyFile()
    {
        using var stream = new MemoryStream();
        Assert.Equal(new RadiusHealthSnapshot("unknown", null), RadiusHealthEvidence.Read(stream, Now));
    }

    [Theory]
    [InlineData("")]
    [InlineData("1800000000 responsive")]
    [InlineData("1800000000 responsive\nextra\n")]
    [InlineData("9999999999999999999 responsive\n")]
    [InlineData("1800000000  responsive\n")]
    public void RejectMalformedEvidence(string raw) =>
        Assert.Equal(new RadiusHealthSnapshot("unknown", null), RadiusHealthEvidence.Parse(raw, Now));
}
