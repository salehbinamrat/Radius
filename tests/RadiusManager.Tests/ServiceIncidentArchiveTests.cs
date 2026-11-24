using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class ServiceIncidentArchiveTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "radius-incidents-" + Guid.NewGuid().ToString("N"));
    private static readonly DateTimeOffset Start = DateTimeOffset.UnixEpoch.AddDays(100);
    public ServiceIncidentArchiveTests() => Directory.CreateDirectory(directory);

    private static ServiceObservation Sample(int seconds, string db = "reachable", string radius = "unknown", int? at = null) =>
        new(Start.AddSeconds(seconds), db, db == "reachable" ? 1 : null, radius,
            at is int t ? Start.AddSeconds(t).UtcDateTime : null);

    [Fact]
    public void IncidentIdentitySurvivesRestartAndMoreThanHistoryCapacity()
    {
        var archive = new ServiceIncidentArchive(new ServiceIncidentStore(directory));
        archive.Observe(Sample(0, "no-response"));
        archive.Observe(Sample(15, "no-response"));
        var original = Assert.Single(archive.Snapshot(Start.AddSeconds(15)).Incidents);
        for (int i = 2; i <= 245; i++) archive.Observe(Sample(i * 15, "no-response"));
        archive = new ServiceIncidentArchive(new ServiceIncidentStore(directory));
        var restored = archive.Snapshot(Start.AddSeconds(245 * 15));
        Assert.Equal("volume-snapshot", restored.Retention);
        Assert.Equal(original, Assert.Single(restored.Incidents));
        archive.Observe(Sample(4000)); // first evidence after a gap, no recovery yet
        Assert.Null(Assert.Single(archive.Snapshot(Start.AddSeconds(4000)).Incidents).RecoveryConfirmedAtUtc);
        archive.Observe(Sample(4015));
        var recovered = Assert.Single(archive.Snapshot(Start.AddSeconds(4015)).Incidents);
        Assert.Equal(original.Id, recovered.Id);
        Assert.Equal(Start.AddSeconds(4015), recovered.RecoveryConfirmedAtUtc);
        Assert.Equal(recovered, Assert.Single(new ServiceIncidentArchive(new ServiceIncidentStore(directory))
            .Snapshot(Start.AddSeconds(4015)).Incidents));
    }

    [Fact]
    public void UnknownAndDuplicateEvidenceDoNotConfirmOrCloseIncidents()
    {
        var archive = new ServiceIncidentArchive();
        archive.Observe(Sample(15, radius: "no-response", at: 15));
        archive.Observe(Sample(30, radius: "no-response", at: 15));
        Assert.Empty(archive.Snapshot(Start.AddSeconds(30)).Incidents);
        archive.Observe(Sample(45, radius: "no-response", at: 40));
        var open = Assert.Single(archive.Snapshot(Start.AddSeconds(45)).Incidents);
        archive.Observe(Sample(60));
        Assert.Equal("unknown", archive.Snapshot(Start.AddSeconds(60)).Services[1].State);
        Assert.Equal(open, Assert.Single(archive.Snapshot(Start.AddSeconds(60)).Incidents));
        archive.Observe(Sample(75, radius: "responsive", at: 75));
        archive.Observe(Sample(90, radius: "responsive", at: 75));
        Assert.Null(Assert.Single(archive.Snapshot(Start.AddSeconds(90)).Incidents).RecoveryConfirmedAtUtc);
        archive.Observe(Sample(105, radius: "responsive", at: 100));
        Assert.Equal(Start.AddSeconds(105), Assert.Single(archive.Snapshot(Start.AddSeconds(105)).Incidents).RecoveryConfirmedAtUtc);
    }

    [Fact]
    public void BoundedClosedIncidentsNeverEvictOpenIncident()
    {
        var archive = new ServiceIncidentArchive();
        archive.Observe(Sample(0, radius: "no-response", at: 0));
        archive.Observe(Sample(15, radius: "no-response", at: 15));
        var open = Assert.Single(archive.Snapshot(Start.AddSeconds(15)).Incidents);
        for (int i = 0; i < ServiceIncidentArchive.ClosedCapacity + 4; i++)
        {
            int s = 30 + i * 60;
            archive.Observe(Sample(s, "no-response"));
            archive.Observe(Sample(s + 15, "no-response"));
            archive.Observe(Sample(s + 30));
            archive.Observe(Sample(s + 45));
        }
        var rows = archive.Snapshot(Start.AddDays(1)).Incidents;
        Assert.Equal(ServiceIncidentArchive.ClosedCapacity + 1, rows.Length);
        Assert.Equal(open, Assert.Single(rows.Where(x => x.RecoveryConfirmedAtUtc is null)));
    }

    [Fact]
    public void CorruptCheckpointIsPreservedAndStorageDegradationReported()
    {
        var path = Path.Combine(directory, "incidents-v1.json");
        File.WriteAllText(path, "{bad");
        var archive = new ServiceIncidentArchive(new ServiceIncidentStore(directory));
        archive.Observe(Sample(0, "no-response"));
        archive.Observe(Sample(15, "no-response"));
        var snapshot = archive.Snapshot(Start.AddSeconds(15));
        Assert.Equal("storage-degraded", snapshot.Retention);
        Assert.Single(snapshot.Incidents);
        Assert.Equal("{bad", File.ReadAllText(path));
    }

    public void Dispose() => Directory.Delete(directory, recursive: true);
}
