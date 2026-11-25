using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RadiusManager.Api;

/// <summary>Verify packaged input bytes before database access. Integrity, not a signature.</summary>
public static class MigrationBundle
{
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly Regex ManifestLine = new(
        @"\A([a-f0-9]{64})  ([a-z0-9_./-]+)\z", RegexOptions.CultureInvariant);
    private static readonly Regex ImageId = new(
        @"\Asha256:[a-f0-9]{64}\n\z", RegexOptions.CultureInvariant);
    private static readonly Regex SourceRevision = new(
        @"\A[a-f0-9]{40}\n\z", RegexOptions.CultureInvariant);

    private static string Hash(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    public static void Verify(string directory, IReadOnlyList<MigrationCatalog.Entry> catalog, byte[] officialSql)
    {
        // Never use manifest-provided paths to open files. The set of expected
        // filenames is derived solely from the compiled catalog and fixed metadata.
        try
        {
            var image = File.ReadAllBytes(Path.Combine(directory, "image-id.txt"));
            var revision = File.ReadAllBytes(Path.Combine(directory, "source-revision.txt"));
            if (!ImageId.IsMatch(Utf8.GetString(image)) || !SourceRevision.IsMatch(Utf8.GetString(revision)))
                throw new InvalidDataException();
            var expected = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["official.sql"] = Hash(officialSql),
                ["image-id.txt"] = Hash(image),
                ["source-revision.txt"] = Hash(revision)
            };
            foreach (var entry in catalog)
                expected.Add("migrations/" + entry.Filename, entry.Sha256);
            if (catalog.Count != 10 || expected.Count != 13)
                throw new InvalidDataException();

            var manifest = File.ReadAllBytes(Path.Combine(directory, "SHA256SUMS"));
            if (manifest.Length is < 1 or > 4096)
                throw new InvalidDataException();
            var lines = Utf8.GetString(manifest).Split('\n');
            if (lines.Length != expected.Count + 1 || lines[^1] != "")
                throw new InvalidDataException();
            foreach (var line in lines[..^1])
            {
                var match = ManifestLine.Match(line);
                if (!match.Success || !expected.Remove(match.Groups[2].Value, out var hash)
                    || hash != match.Groups[1].Value)
                    throw new InvalidDataException();
            }
            if (expected.Count != 0)
                throw new InvalidDataException();
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException
            or ArgumentException or NotSupportedException)
        {
            // No paths, file content or manifest values in diagnostics.
            throw new InvalidDataException("Migration bundle integrity verification failed");
        }
    }
}
