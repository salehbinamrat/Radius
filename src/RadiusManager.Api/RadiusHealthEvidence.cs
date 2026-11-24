using System.Globalization;
using System.Text;

namespace RadiusManager.Api;

public sealed record RadiusHealthSnapshot(string State, DateTime? CheckedAtUtc);

/// <summary>Only local publisher evidence; not proof of subscriber authentication.</summary>
public static class RadiusHealthEvidence
{
    private const string Path = "/var/lib/radius-health/status";
    private static readonly RadiusHealthSnapshot Unknown = new("unknown", null);

    public static RadiusHealthSnapshot Read()
    {
        try
        {
            using var stream = File.Open(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return Read(stream, DateTimeOffset.UtcNow);
        }
        catch (IOException) { return Unknown; }
        catch (UnauthorizedAccessException) { return Unknown; }
    }

    // A bounded read accepts short regular files and never reads beyond 81 bytes.
    // Use Stream.Read(Span<byte>) rather than a version-specific named overload.
    public static RadiusHealthSnapshot Read(Stream stream, DateTimeOffset now)
    {
        Span<byte> buffer = stackalloc byte[81];
        var count = 0;
        while (count < buffer.Length)
        {
            var read = stream.Read(buffer[count..]);
            if (read == 0) break;
            count += read;
        }
        if (count >= buffer.Length) return Unknown;
        return Parse(Encoding.ASCII.GetString(buffer[..count]), now);
    }

    public static RadiusHealthSnapshot Parse(string raw, DateTimeOffset now)
    {
        if (raw.Length > 80 || !raw.EndsWith('\n')) return Unknown;
        var parts = raw[..^1].Split(' ');
        if (parts.Length != 2 || parts[1] is not ("responsive" or "no-response")
            || !long.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var epoch))
            return Unknown;
        DateTimeOffset checkedAt;
        try { checkedAt = DateTimeOffset.FromUnixTimeSeconds(epoch); }
        catch (ArgumentOutOfRangeException) { return Unknown; }
        var age = now - checkedAt;
        if (age < TimeSpan.Zero || age > TimeSpan.FromSeconds(35)) return Unknown;
        return new(parts[1], checkedAt.UtcDateTime);
    }
}
