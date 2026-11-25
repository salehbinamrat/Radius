using System.Security.Cryptography;
using System.Text;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class MigrationBundleTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("radius-bundle-").FullName;
    private readonly IReadOnlyList<MigrationCatalog.Entry> catalog;
    private readonly byte[] official = Encoding.UTF8.GetBytes("SELECT 1;\n");
    private readonly string manifest;
    private static readonly string[] Names =
    [
        "001_app.sql", "002_lab_accounts.sql", "003_accounting.sql", "004_nas_drafts.sql",
        "005_admin_identity.sql", "006_reseller_ownership.sql", "007_ownership_transfers.sql",
        "008_audit_append_only.sql", "009_accounting_read_indexes.sql", "010_accounting_quality.sql"
    ];

    public MigrationBundleTests()
    {
        var migrations = Directory.CreateDirectory(Path.Combine(directory, "migrations")).FullName;
        foreach (var name in Names)
            File.WriteAllText(Path.Combine(migrations, name), "SELECT 1;\n");
        catalog = MigrationCatalog.Read(migrations);
        File.WriteAllBytes(Path.Combine(directory, "official.sql"), official);
        File.WriteAllText(Path.Combine(directory, "image-id.txt"), "sha256:" + new string('a', 64) + "\n");
        File.WriteAllText(Path.Combine(directory, "source-revision.txt"), new string('b', 40) + "\n");
        var names = new[] { "official.sql", "image-id.txt", "source-revision.txt" }
            .Concat(Names.Select(x => "migrations/" + x));
        manifest = string.Concat(names.Select(name =>
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(directory, name)))).ToLowerInvariant()
            + "  " + name + "\n"));
        WriteManifest(manifest);
    }

    private void WriteManifest(string value) => File.WriteAllText(Path.Combine(directory, "SHA256SUMS"), value);

    [Fact]
    public void ExactBundleIsAccepted() => MigrationBundle.Verify(directory, catalog, official);

    [Fact]
    public void AlteredOfficialBytesAreRejected() =>
        Assert.Throws<InvalidDataException>(() => MigrationBundle.Verify(directory, catalog, Encoding.UTF8.GetBytes("SELECT 2;")));

    [Fact]
    public void AlteredMigrationSnapshotIsRejected()
    {
        var entries = catalog.ToArray();
        entries[0] = entries[0] with { Sha256 = new string('0', 64) };
        Assert.Throws<InvalidDataException>(() => MigrationBundle.Verify(directory, entries, official));
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("missing")]
    [InlineData("unexpected")]
    [InlineData("traversal")]
    [InlineData("bad-hash")]
    public void InvalidManifestFailsClosed(string kind)
    {
        var lines = manifest.Split('\n');
        var altered = kind switch
        {
            "duplicate" => manifest.Replace(lines[1], lines[0], StringComparison.Ordinal),
            "missing" => manifest.Replace(lines[0] + "\n", "", StringComparison.Ordinal),
            "unexpected" => manifest.Replace("  official.sql", "  unexpected.sql", StringComparison.Ordinal),
            "traversal" => manifest.Replace("  official.sql", "  ../official.sql", StringComparison.Ordinal),
            _ => "!" + manifest[1..]
        };
        WriteManifest(altered);
        var ex = Assert.Throws<InvalidDataException>(() => MigrationBundle.Verify(directory, catalog, official));
        Assert.Equal("Migration bundle integrity verification failed", ex.Message);
        Assert.Null(ex.InnerException);
    }

    [Fact]
    public void MissingManifestIsRejected()
    {
        File.Delete(Path.Combine(directory, "SHA256SUMS"));
        Assert.Throws<InvalidDataException>(() => MigrationBundle.Verify(directory, catalog, official));
    }

    [Fact]
    public void AlteredSourceIdentityIsRejected()
    {
        File.WriteAllText(Path.Combine(directory, "source-revision.txt"), new string('c', 40) + "\n");
        Assert.Throws<InvalidDataException>(() => MigrationBundle.Verify(directory, catalog, official));
    }

    public void Dispose() => Directory.Delete(directory, recursive: true);
}
