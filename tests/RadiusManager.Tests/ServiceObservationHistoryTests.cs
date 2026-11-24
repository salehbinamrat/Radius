using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class ServiceObservationHistoryTests
{
    private static ServiceObservation Sample(int second, string state = "reachable") =>
        new(DateTimeOffset.UnixEpoch.AddSeconds(second), state,
            state == "reachable" ? 1.25 : null, "unknown", null);

    [Fact]
    public void EmptyHistoryDoesNotInventObservations()
    {
        var result = new ServiceObservationHistory().Snapshot();
        Assert.Empty(result.Samples);
        Assert.Equal("process-memory", result.Retention);
        Assert.Equal("lab", result.Scope);
    }

    [Fact]
    public void RetainsOnlyBoundedNewestSamplesInObservationOrder()
    {
        var history = new ServiceObservationHistory();
        for (var i = 0; i < ServiceObservationHistory.Capacity + 10; i++)
            history.Add(Sample(i));
        var result = history.Snapshot();
        Assert.Equal(ServiceObservationHistory.Capacity, result.Samples.Length);
        Assert.Equal(Sample(10), result.Samples[0]);
        Assert.Equal(Sample(ServiceObservationHistory.Capacity + 9), result.Samples[^1]);
    }

    [Fact]
    public void PreservesFailureAndRecoveryWithoutInventingLatency()
    {
        var history = new ServiceObservationHistory();
        history.Add(Sample(1));
        history.Add(Sample(16, "no-response"));
        history.Add(Sample(31));
        var rows = history.Snapshot().Samples;
        Assert.Equal("no-response", rows[1].Database);
        Assert.Null(rows[1].DatabaseCheckMs);
        Assert.Equal("reachable", rows[2].Database);
        rows[0] = Sample(999);
        Assert.Equal(Sample(1), history.Snapshot().Samples[0]);
    }

    [Fact]
    public void ConcurrentWritersCannotExceedCapacity()
    {
        var history = new ServiceObservationHistory();
        Parallel.For(0, 1000, _ => history.Add(Sample(1)));
        Assert.Equal(ServiceObservationHistory.Capacity, history.Snapshot().Samples.Length);
    }
}
