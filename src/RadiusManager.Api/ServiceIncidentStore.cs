using System.Text.Json;
using System.Text.Json.Serialization;

namespace RadiusManager.Api;

/// <summary>Bounded versioned checkpoint, separate from history-v1.json. Single API writer only.</summary>
public sealed class ServiceIncidentStore(string directory)
{
    private const int MaxBytes = 128 * 1024;
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 10
    };
    private sealed record Stored(int Version, ServiceIncidentCheckpoint Checkpoint);
    private string SnapshotPath => Path.Combine(directory, "incidents-v1.json");
    private bool blocked;

    public bool TryLoad(out ServiceIncidentCheckpoint? checkpoint)
    {
        checkpoint = null;
        try
        {
            if (!Directory.Exists(directory)) return false;
            using var stream = File.Open(SnapshotPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            var bytes = new byte[MaxBytes + 1];
            int count = 0;
            while (count < bytes.Length)
            {
                var n = stream.Read(bytes, count, bytes.Length - count);
                if (n == 0) break;
                count += n;
            }
            if (count > MaxBytes) { blocked = true; return false; }
            var document = JsonSerializer.Deserialize<Stored>(bytes.AsSpan(0, count), Options);
            if (document is null || document.Version != 1 || !Valid(document.Checkpoint))
            { blocked = true; return false; }
            checkpoint = document.Checkpoint;
            return true;
        }
        catch (FileNotFoundException) { return true; }
        catch (JsonException) { blocked = true; return false; }
        catch (IOException) { blocked = true; return false; }
        catch (UnauthorizedAccessException) { blocked = true; return false; }
    }

    public bool TrySave(ServiceIncidentCheckpoint checkpoint)
    {
        if (blocked || !Valid(checkpoint)) return false;
        var temporary = Path.Combine(directory, "incidents-v1.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new Stored(1, checkpoint), Options);
            if (bytes.Length > MaxBytes) return false;
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, SnapshotPath, overwrite: true);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static bool Valid(ServiceIncidentCheckpoint? checkpoint)
    {
        if (checkpoint is null || !ValidCursor(checkpoint.Database) || !ValidCursor(checkpoint.Radius)
            || checkpoint.Database.LastObservation != checkpoint.Radius.LastObservation
            || checkpoint.Incidents is not { Length: <= ServiceIncidentArchive.ClosedCapacity + 2 })
            return false;
        var ids = new HashSet<Guid>();
        int closed = 0, databaseOpen = 0, radiusOpen = 0;
        foreach (var row in checkpoint.Incidents)
        {
            if (row is null || row.Id == Guid.Empty || !ids.Add(row.Id)
                || row.Service is not ("postgresql" or "freeradius")
                || row.FailureConfirmedAtUtc.Offset != TimeSpan.Zero
                || checkpoint.Database.LastObservation is not DateTimeOffset last
                || row.FailureConfirmedAtUtc > last)
                return false;
            if (row.RecoveryConfirmedAtUtc is DateTimeOffset recovery)
            {
                if (recovery.Offset != TimeSpan.Zero || recovery < row.FailureConfirmedAtUtc || recovery > last)
                    return false;
                closed++;
            }
            else if (row.Service == "postgresql") databaseOpen++;
            else radiusOpen++;
        }
        return closed <= ServiceIncidentArchive.ClosedCapacity
            && databaseOpen == (checkpoint.Database.IncidentOpen ? 1 : 0)
            && radiusOpen == (checkpoint.Radius.IncidentOpen ? 1 : 0);
    }

    private static bool ValidCursor(ServiceAlertCursor? cursor)
    {
        if (cursor is null || cursor.Failures is < 0 or > 2 || cursor.Successes is < 0 or > 2
            || (cursor.Failures > 0 && cursor.Successes > 0)
            || cursor.State is not ("healthy" or "pending" or "failed" or "unknown")) return false;
        if (cursor.LastObservation is DateTimeOffset observed
            && (observed.Offset != TimeSpan.Zero || observed > DateTimeOffset.UtcNow.AddSeconds(5))) return false;
        if (cursor.LastEvidence is DateTimeOffset evidence
            && (evidence.Offset != TimeSpan.Zero || cursor.LastObservation is not DateTimeOffset last || evidence > last))
            return false;
        return cursor.State switch
        {
            "healthy" => cursor.Successes == 2 && !cursor.IncidentOpen && cursor.LastEvidence is not null,
            "failed" => cursor.Failures == 2 && cursor.IncidentOpen && cursor.LastEvidence is not null,
            "pending" => (cursor.Failures == 1 || cursor.Successes == 1) && cursor.LastEvidence is not null,
            _ => cursor.Failures == 0 && cursor.Successes == 0
        };
    }
}
