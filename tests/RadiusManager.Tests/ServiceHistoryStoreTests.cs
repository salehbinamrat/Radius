using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class ServiceHistoryStoreTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "radius-history-" + Guid.NewGuid().ToString("N"));
    public ServiceHistoryStoreTests() => Directory.CreateDirectory(directory);
    private static ServiceObservation Sample(int seconds) =>
        new(DateTimeOffset.UnixEpoch.AddSeconds(seconds), "reachable", 2, "unknown", null);

    [Fact]
    public void RestoresBoundedSamplesAfterReopening()
    {
        var first = new ServiceObservationHistory(new ServiceHistoryStore(directory));
        for (int i = 0; i < 3; i++) first.Add(Sample(i));
        var restored = new ServiceObservationHistory(new ServiceHistoryStore(directory));
        Assert.Equal("volume-snapshot", restored.Snapshot().Retention);
        Assert.Equal(first.Snapshot().Samples, restored.Snapshot().Samples);
        restored.Add(Sample(3));
        Assert.Equal(4, new ServiceObservationHistory(new ServiceHistoryStore(directory)).Snapshot().Samples.Length);
    }

    [Fact]
    public void CorruptSnapshotRemainsUntouchedAndHistoryReportsDegradation()
    {
        var path = Path.Combine(directory, "history-v1.json");
        File.WriteAllText(path, "{broken");
        var history = new ServiceObservationHistory(new ServiceHistoryStore(directory));
        history.Add(Sample(1));
        Assert.Equal("storage-degraded", history.Snapshot().Retention);
        Assert.Single(history.Snapshot().Samples);
        Assert.Equal("{broken", File.ReadAllText(path));
    }

    [Fact]
    public void UnavailableDirectoryDoesNotStopMemoryCollection()
    {
        var history = new ServiceObservationHistory(new ServiceHistoryStore(Path.Combine(directory, "absent")));
        history.Add(Sample(1));
        Assert.Equal("storage-degraded", history.Snapshot().Retention);
        Assert.Single(history.Snapshot().Samples);
    }

    [Fact]
    public void BackwardClockDoesNotInventOrReorderSamples()
    {
        var history = new ServiceObservationHistory(new ServiceHistoryStore(directory));
        history.Add(Sample(2));
        history.Add(Sample(1));
        Assert.Equal(Sample(2), Assert.Single(history.Snapshot().Samples));
    }

    public void Dispose() => Directory.Delete(directory, recursive: true);
}
