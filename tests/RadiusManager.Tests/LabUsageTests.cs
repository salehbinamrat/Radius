using RadiusManager.Api;
using Xunit;

public sealed class LabUsageTests
{
    private static LabUsageReport Report(decimal up, decimal down, long sessions, long active = 0,
        long stale = 0, long anomalies = 0) =>
        new("lab_123456789abc", up, down, sessions, active, stale, anomalies, 2, DateTime.UtcNow);

    [Fact]
    public void TotalIsUploadPlusDownload() =>
        Assert.Equal(1_500_000m, Report(500_000m, 1_000_000m, 2).TotalBytes);

    [Fact]
    public void CompletedSessionsCanBeMarkedClosed_NotBillingVerified() =>
        Assert.True(Report(12, 24, 2).IsClosedAndUnanomalous);

    [Theory]
    [InlineData(0, 0, 0, 0)]
    [InlineData(1, 1, 0, 0)]
    [InlineData(1, 0, 1, 0)]
    [InlineData(1, 0, 0, 1)]
    public void MissingOpenStaleAndAnomalousCannotBeFinal(long sessions, long open, long stale, long anomaly) =>
        Assert.False(Report(10, 20, sessions, open, stale, anomaly).IsClosedAndUnanomalous);

    [Fact]
    public void OverflowFailsRatherThanWrapping() =>
        Assert.Throws<OverflowException>(() => Report(decimal.MaxValue, 1m, 2).TotalBytes);
}
