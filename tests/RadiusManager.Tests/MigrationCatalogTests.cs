using System.Security.Cryptography;
using System.Text;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class MigrationCatalogTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("radius-catalog-").FullName;
    private static readonly string[] Names =
    [
        "001_app.sql", "002_lab_accounts.sql", "003_accounting.sql", "004_nas_drafts.sql",
        "005_admin_identity.sql", "006_reseller_ownership.sql", "007_ownership_transfers.sql",
        "008_audit_append_only.sql", "009_accounting_read_indexes.sql", "010_accounting_quality.sql"
    ];

    public MigrationCatalogTests()
    {
        foreach (var name in Names)
            File.WriteAllText(Path.Combine(directory, name), "SELECT 1;\n");
    }

    [Fact]
    public void CatalogIsOrderedAndUsesRawFileHashes()
    {
        var bytes = Encoding.UTF8.GetBytes("SELECT 'عربي';\r\n");
        File.WriteAllBytes(Path.Combine(directory, Names[0]), bytes);
        var entries = MigrationCatalog.Read(directory);
        Assert.Equal(Enumerable.Range(1, 10), entries.Select(x => x.Version));
        Assert.Equal(Names, entries.Select(x => x.Filename));
        Assert.Equal(Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), entries[0].Sha256);
        Assert.Equal(new[] { "public.app_plans" }, entries[0].Objects);
    }

    [Theory]
    [InlineData("DROP TABLE x;")]
    [InlineData("drop\nschema x;")]
    [InlineData("DROP DATABASE x;")]
    [InlineData("TRUNCATE x;")]
    public void DestructiveCommandsAreRejected(string sql) =>
        Assert.Throws<InvalidDataException>(() => MigrationCatalog.ValidateSql(Names[0], sql));

    [Fact]
    public void OnlyTheExistingAuditTriggerClausesAreExempt()
    {
        const string clause = "BEFORE UPDATE OR DELETE OR TRUNCATE ON public.app_admin_audit_events";
        MigrationCatalog.ValidateSql(Names[7], clause + "\nFOR EACH STATEMENT");
        Assert.Throws<InvalidDataException>(() => MigrationCatalog.ValidateSql(Names[0], clause));
        Assert.Throws<InvalidDataException>(() => MigrationCatalog.ValidateSql(Names[7], clause + "\nTRUNCATE x;"));
        Assert.Throws<InvalidDataException>(() => MigrationCatalog.ValidateSql(Names[7],
            "BEFORE UPDATE OR DELETE OR TRUNCATE ON public.other"));
    }

    [Fact]
    public void MissingFileDoesNotEmitPartialManifest()
    {
        File.Delete(Path.Combine(directory, Names[9]));
        using var output = new StringWriter();
        using var errors = new StringWriter();
        Assert.Equal(1, MigrationCatalog.WriteManifest(directory, output, errors));
        Assert.Empty(output.ToString());
        Assert.DoesNotContain(directory, errors.ToString());
    }

    [Fact]
    public void InvalidUtf8DoesNotEmitPartialManifest()
    {
        File.WriteAllBytes(Path.Combine(directory, Names[9]), [0xff]);
        using var output = new StringWriter();
        using var errors = new StringWriter();
        Assert.Equal(1, MigrationCatalog.WriteManifest(directory, output, errors));
        Assert.Empty(output.ToString());
        Assert.DoesNotContain(directory, errors.ToString());
    }

    public void Dispose() => Directory.Delete(directory, recursive: true);
}
