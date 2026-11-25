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

    [Fact]
    public void IndexNormalizationDoesNotHideDifferentDefinitions()
    {
        Assert.Equal(MigrationVerifier.NormalizeIndex("CREATE INDEX i ON public.radacct USING btree (username)"),
                     MigrationVerifier.NormalizeIndex("create index i on radacct using btree(username)"));
        Assert.NotEqual(MigrationVerifier.NormalizeIndex("CREATE INDEX i ON radacct USING btree (username)"),
                        MigrationVerifier.NormalizeIndex("CREATE INDEX i ON radacct USING btree (acctsessionid)"));
    }
}
