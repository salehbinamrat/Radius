using System.Text.RegularExpressions;
using Npgsql;

namespace RadiusManager.Api;

/// <summary>Isolated read-only candidate; never executes or adopts migrations.</summary>
public static class MigrationVerifier
{
    internal const int LockNamespace = 725134019;
    internal const int LockId = 20261124;
    internal static readonly string[] OfficialTables =
        ["radcheck", "radreply", "radgroupcheck", "radgroupreply", "radusergroup", "radacct", "radpostauth", "nas"];

    public sealed record LedgerRow(int Version, string Filename, string Sha256);

    public static bool IsIsolatedDatabase(string? name) =>
        name is not null && Regex.IsMatch(name, @"\Aradius_mig_[a-f0-9]{8}\z", RegexOptions.CultureInvariant);

    public static void VerifyLedger(IReadOnlyList<MigrationCatalog.Entry> catalog, IReadOnlyList<LedgerRow> rows)
    {
        VerifyPrefix(catalog, rows);
        if (rows.Count != catalog.Count)
            throw new InvalidDataException("Migrations still pending; verification incomplete");
    }

    internal static void VerifyPrefix(IReadOnlyList<MigrationCatalog.Entry> catalog, IReadOnlyList<LedgerRow> rows)
    {
        if (rows.Count > catalog.Count)
            throw new InvalidDataException("Migration ledger has unrecognized future versions");
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var entry = catalog[i];
            if (row.Version != i + 1 || row.Version != entry.Version)
                throw new InvalidDataException("Migration ledger has missing versions or is out of order");
            if (row.Filename != entry.Filename || row.Sha256 != entry.Sha256)
                throw new InvalidDataException("Migration checksum/filename mismatch");
        }
    }

    public static string NormalizeIndex(string definition) =>
        Regex.Replace(definition.ToLowerInvariant().Replace("on public.radacct ", "on radacct ", StringComparison.Ordinal), @"\s+", "");

    internal static NpgsqlCommand Command(NpgsqlConnection conn, NpgsqlTransaction tx, string sql, params string[] values)
    {
        var cmd = new NpgsqlCommand(sql, conn, tx) { CommandTimeout = 75 };
        for (var i = 0; i < values.Length; i++)
            cmd.Parameters.AddWithValue("p" + i, values[i]);
        return cmd;
    }

    internal static async Task<bool> Exists(NpgsqlConnection conn, NpgsqlTransaction tx, string name, CancellationToken ct)
    {
        if (name.StartsWith("index:", StringComparison.Ordinal))
        {
            var index = name[6..];
            var expected = index switch
            {
                "public.idx_app_radacct_recent" => "CREATE INDEX idx_app_radacct_recent ON radacct USING btree (COALESCE(acctupdatetime, acctstarttime) DESC, radacctid DESC)",
                "public.idx_app_radacct_user_recent" => "CREATE INDEX idx_app_radacct_user_recent ON radacct USING btree (username, COALESCE(acctupdatetime, acctstarttime) DESC, radacctid DESC)",
                _ => throw new InvalidDataException("Unknown accounting index")
            };
            await using var cmd = Command(conn, tx, """
                SELECT c.relkind::text, i.indisvalid, i.indisready, i.indislive,
                    i.indrelid=to_regclass('public.radacct'), pg_get_indexdef(c.oid)
                FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid=c.oid
                WHERE c.oid=to_regclass(@p0)
                """, index);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (!await r.ReadAsync(ct)) return false;
            if (r.GetString(0) != "i" || Enumerable.Range(1, 4).Any(i => r.IsDBNull(i) || !r.GetBoolean(i))
                || r.IsDBNull(5) || NormalizeIndex(r.GetString(5)) != NormalizeIndex(expected))
                throw new InvalidDataException("Accounting index definition or validity mismatch");
            return true;
        }
        if (name.StartsWith("trigger:", StringComparison.Ordinal))
        {
            await using var cmd = Command(conn, tx, """
                SELECT EXISTS(SELECT 1 FROM pg_trigger t
                JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname=@p0 AND c.relname=@p1 AND t.tgname=@p2
                  AND NOT t.tgisinternal AND t.tgenabled='A' AND t.tgtype=58
                  AND t.tgfoid=to_regprocedure('public.app_reject_audit_mutation()'))
                """, name[8..].Split('.'));
            return (bool)(await cmd.ExecuteScalarAsync(ct) ?? false);
        }
        if (name.StartsWith("column:", StringComparison.Ordinal))
        {
            await using var cmd = Command(conn, tx, """
                SELECT EXISTS(SELECT 1 FROM information_schema.columns
                WHERE table_schema=@p0 AND table_name=@p1 AND column_name=@p2)
                """, name[7..].Split('.'));
            return (bool)(await cmd.ExecuteScalarAsync(ct) ?? false);
        }
        var procedure = name.StartsWith("procedure:", StringComparison.Ordinal);
        await using var relation = Command(conn, tx,
            procedure ? "SELECT to_regprocedure(@p0) IS NOT NULL" : "SELECT to_regclass(@p0) IS NOT NULL",
            procedure ? name[10..] : name);
        return (bool)(await relation.ExecuteScalarAsync(ct) ?? false);
    }

    internal static NpgsqlConnectionStringBuilder IsolatedConnection(string name, string applicationName)
    {
        if (Environment.GetEnvironmentVariable("CI") != "true"
            || Environment.GetEnvironmentVariable("LAB_MIGRATION_TEST_MODE") != "isolated-ci"
            || !IsIsolatedDatabase(name))
            throw new InvalidDataException("C# migration verification requires isolated CI database");
        var builder = new NpgsqlConnectionStringBuilder(
            Environment.GetEnvironmentVariable("ConnectionStrings__RadiusDb") ?? "");
        if (builder.Host != "db" || builder.Port != 5432 || builder.Username != "radius"
            || builder.Database != "radius" || string.IsNullOrEmpty(builder.Password))
            throw new InvalidDataException("Unexpected isolated database connection configuration");
        builder.Database = name!;
        builder.Pooling = false;
        builder.Timeout = 10;
        builder.ApplicationName = applicationName;
        return builder;
    }

    public static async Task<int> RunAsync(string directory, TextWriter output, TextWriter errors)
    {
        var name = Environment.GetEnvironmentVariable("MIGRATION_DB_NAME");
        if (Environment.GetEnvironmentVariable("CI") != "true"
            || Environment.GetEnvironmentVariable("LAB_MIGRATION_TEST_MODE") != "isolated-ci"
            || !IsIsolatedDatabase(name))
        {
            errors.WriteLine("C# migration verification requires isolated CI database");
            return 1;
        }
        try
        {
            var catalog = MigrationCatalog.Read(directory);
            var builder = IsolatedConnection(name!, "radius-csharp-migration-verifier");
            using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            var ct = deadline.Token;
            await using var conn = new NpgsqlConnection(builder.ConnectionString);
            await conn.OpenAsync(ct);
            // Share legacy session lock; physical connection disposal releases it.
            await using (var tx = await conn.BeginTransactionAsync(ct))
            {
                await using var readOnly = Command(conn, tx, "SET TRANSACTION READ ONLY");
                await readOnly.ExecuteNonQueryAsync(ct);
                await using var timeout = Command(conn, tx, "SET LOCAL lock_timeout TO '60s'");
                await timeout.ExecuteNonQueryAsync(ct);
                await using var lockCmd = Command(conn, tx, $"SELECT pg_advisory_lock({LockNamespace}, {LockId})");
                await lockCmd.ExecuteNonQueryAsync(ct);
                await tx.CommitAsync(ct);
            }
            await using var verify = await conn.BeginTransactionAsync(System.Data.IsolationLevel.RepeatableRead, ct);
            await using (var readOnly = Command(conn, verify, "SET TRANSACTION READ ONLY"))
                await readOnly.ExecuteNonQueryAsync(ct);
            foreach (var table in OfficialTables)
                if (!await Exists(conn, verify, "public." + table, ct))
                    throw new InvalidDataException("FreeRADIUS schema incomplete");
            if (!await Exists(conn, verify, "public.app_schema_migrations", ct))
                throw new InvalidDataException("Migration ledger missing; verify-only cannot create schema");
            var rows = new List<LedgerRow>();
            await using (var cmd = Command(conn, verify, """
                SELECT version, filename, sha256 FROM public.app_schema_migrations ORDER BY version
                """))
            await using (var reader = await cmd.ExecuteReaderAsync(ct))
                while (await reader.ReadAsync(ct))
                    rows.Add(new LedgerRow(reader.GetInt32(0), reader.GetString(1), reader.GetString(2)));
            VerifyLedger(catalog, rows);
            foreach (var entry in catalog)
                foreach (var obj in entry.Objects)
                    if (!await Exists(conn, verify, obj, ct))
                        throw new InvalidDataException($"Applied migration {entry.Version} has missing/partial objects");
            await verify.CommitAsync(ct);
            output.WriteLine($"C# migration verification PASS: {rows.Count} immutable versions (read-only)");
            return 0;
        }
        catch (PostgresException ex)
        {
            errors.WriteLine("C# migration verification refused: SQLSTATE " + ex.SqlState);
            return 1;
        }
        catch (InvalidDataException ex)
        {
            errors.WriteLine("C# migration verification refused: " + ex.Message);
            return 1;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException
            or NotSupportedException or RegexMatchTimeoutException or NpgsqlException or OperationCanceledException)
        {
            errors.WriteLine("C# migration verification refused: invalid input or unavailable database");
            return 1;
        }
    }
}
