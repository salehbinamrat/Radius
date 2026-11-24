using System.Text.Json;
using System.Text.Json.Serialization;

namespace RadiusManager.Api;

/// <summary>Single-writer local snapshot; independent of PostgreSQL and subscriber data.</summary>
public sealed class ServiceHistoryStore(string directory)
{
    private const int MaxBytes = 128 * 1024;
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 8
    };
    private string SnapshotPath => Path.Combine(directory, "history-v1.json");
    private bool blocked;
    private sealed record Stored(int Version, ServiceObservation[] Samples);

    public bool TryLoad(out ServiceObservation[] samples)
    {
        samples = [];
        try
        {
            if (!Directory.Exists(directory)) return false;
            using var stream = File.Open(SnapshotPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length > MaxBytes) { blocked = true; return false; }
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
            if (document is null || document.Version != 1 || !Valid(document.Samples))
            { blocked = true; return false; }
            samples = document.Samples;
            return true;
        }
        catch (FileNotFoundException) { return true; }
        catch (JsonException) { blocked = true; return false; }
        catch (IOException) { blocked = true; return false; }
        catch (UnauthorizedAccessException) { blocked = true; return false; }
    }

    public bool TrySave(ServiceObservation[] samples)
    {
        if (blocked || !Valid(samples)) return false;
        var temporary = Path.Combine(directory, "history-v1.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new Stored(1, samples), Options);
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

    private static bool Valid(ServiceObservation[]? rows)
    {
        if (rows is null || rows.Length > ServiceObservationHistory.Capacity) return false;
        DateTimeOffset previous = DateTimeOffset.MinValue;
        foreach (var row in rows)
        {
            if (row is null || row.ObservedAtUtc.Offset != TimeSpan.Zero
                || row.ObservedAtUtc < previous || row.ObservedAtUtc > DateTimeOffset.UtcNow.AddSeconds(5)
                || row.Database is not ("reachable" or "no-response" or "unknown")
                || row.Radius is not ("responsive" or "no-response" or "unknown"))
                return false;
            if (row.Database == "reachable")
            {
                if (row.DatabaseCheckMs is not double ms || !double.IsFinite(ms) || ms < 0 || ms > 10000)
                    return false;
            }
            else if (row.DatabaseCheckMs is not null) return false;
            if (row.Radius == "unknown")
            {
                if (row.RadiusCheckedAtUtc is not null) return false;
            }
            else
            {
                if (row.RadiusCheckedAtUtc is not DateTime at || at.Kind != DateTimeKind.Utc
                    || row.ObservedAtUtc.UtcDateTime - at < TimeSpan.Zero
                    || row.ObservedAtUtc.UtcDateTime - at > TimeSpan.FromSeconds(40)) return false;
            }
            previous = row.ObservedAtUtc;
        }
        return true;
    }
}
