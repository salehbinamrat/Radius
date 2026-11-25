using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class MigrationVerifierTests
{
    private static readonly MigrationCatalog.Entry[] Catalog =
    [
        new(1, "001.sql", new string('a', 64), ["public.a"]),
        new(2, "002.sql", new string('b', 64), ["public.b"])
    ];
    private static readonly MigrationVerifier.LedgerRow[] Valid =
        Catalog.Select(x => new MigrationVerifier.LedgerRow(x.Version, x.Filename, x.Sha256)).ToArray();

    [Fact]
    public void ExactLedgerIsAccepted() => MigrationVerifier.VerifyLedger(Catalog, Valid);

    [Fact]
    public void PendingAndMissingVersionsAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.VerifyLedger(Catalog, Valid[..1]));
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.VerifyLedger(Catalog, Valid[1..]));
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.VerifyLedger(Catalog, Valid.Reverse().ToArray()));
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.VerifyLedger(Catalog, [.. Valid, new(3, "003.sql", new string('c', 64))]));
    }

    [Fact]
    public void FilenameAndChecksumDriftAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.VerifyLedger(Catalog, [Valid[0] with { Filename = "wrong.sql" }, Valid[1]]));
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.VerifyLedger(Catalog, [Valid[0], Valid[1] with { Sha256 = new string('0', 64) }]));
    }

    [Theory]
    [InlineData("radius_mig_0123abcd", true)]
    [InlineData("radius", false)]
    [InlineData("radius_mig_0123ABCD", false)]
    [InlineData("radius_mig_0123abcd\n", false)]
    [InlineData(null, false)]
    public void OnlyDisposableDatabaseNamesAreAllowed(string? name, bool expected) =>
        Assert.Equal(expected, MigrationVerifier.IsIsolatedDatabase(name));

    private const string LabConfig = "Host=db;Port=5432;Database=radius;Username=radius";

    [Fact]
    public void MigrationConnectionSupportsExistingInlinePassword()
    {
        var password = new string('a', 48);
        var builder = MigrationVerifier.BuildLabConnection(
            LabConfig + ";Password=" + password, null, "radius_mig_0123abcd", "test");
        Assert.Equal(password, builder.Password);
        Assert.Equal("radius_mig_0123abcd", builder.Database);
        Assert.False(builder.Pooling);
        Assert.Equal(10, builder.Timeout);
    }

    [Theory]
    [InlineData("")]
    [InlineData("\n")]
    [InlineData("\r\n")]
    public void MigrationConnectionReadsOneHexSecretLine(string terminator)
    {
        var path = Path.GetTempFileName();
        try
        {
            var password = new string('a', 48);
            File.WriteAllText(path, password + terminator);
            var builder = MigrationVerifier.BuildLabConnection(
                LabConfig, path, "radius_mig_0123abcd", "test");
            Assert.Equal(password, builder.Password);
            var ex = Assert.Throws<InvalidDataException>(() => MigrationVerifier.BuildLabConnection(
                LabConfig + ";Password=" + password, path, "radius_mig_0123abcd", "test"));
            Assert.Equal("Invalid or conflicting migration database secret source", ex.Message);
            Assert.Null(ex.InnerException);
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData(47, 'a')]
    [InlineData(49, 'a')]
    [InlineData(48, 'A')]
    [InlineData(48, 'g')]
    [InlineData(48, ' ')]
    public void MigrationConnectionRejectsNoncanonicalFileSecrets(int size, char value)
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, new string(value, size));
            var ex = Assert.Throws<InvalidDataException>(() => MigrationVerifier.BuildLabConnection(
                LabConfig, path, "radius_mig_0123abcd", "test"));
            Assert.Equal("Invalid or conflicting migration database secret source", ex.Message);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void MigrationConnectionRejectsMissingAndRelativeFiles()
    {
        var path = Path.GetTempFileName();
        File.Delete(path);
        foreach (var file in new[] { path, "relative-secret" })
        {
            var ex = Assert.Throws<InvalidDataException>(() => MigrationVerifier.BuildLabConnection(
                LabConfig, file, "radius_mig_0123abcd", "test"));
            Assert.Equal("Invalid or conflicting migration database secret source", ex.Message);
        }
    }

    [Fact]
    public void MigrationConnectionRejectsAlternateDatabaseAndPassfile()
    {
        var password = new string('a', 48);
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.BuildLabConnection(
            "Host=other;Database=radius;Username=radius;Password=" + password,
            null, "radius_mig_0123abcd", "test"));
        Assert.Throws<InvalidDataException>(() => MigrationVerifier.BuildLabConnection(
            LabConfig + ";Password=" + password + ";Passfile=/tmp/example",
            null, "radius_mig_0123abcd", "test"));
    }

    [Fact]
    public void IndexNormalizationDoesNotHideDifferentDefinitions()
    {
        Assert.Equal(MigrationVerifier.NormalizeIndex("CREATE INDEX i ON public.radacct USING btree (username)"),
                     MigrationVerifier.NormalizeIndex("create index i on radacct using btree(username)"));
        Assert.NotEqual(MigrationVerifier.NormalizeIndex("CREATE INDEX i ON radacct USING btree (username)"),
                        MigrationVerifier.NormalizeIndex("CREATE INDEX i ON radacct USING btree (acctsessionid)"));
    }
}
