using Npgsql;

namespace RadiusManager.Api;

/// <summary>Experimental executor for disposable CI databases only; not the installer.</summary>
public static class MigrationExecutor
{
    private const string EngineVersion = "3.0.0-csharp-lab";

    private static async Task Execute(NpgsqlConnection conn, NpgsqlTransaction tx, string sql, CancellationToken ct)
    {
        await using var cmd = MigrationVerifier.Command(conn, tx, sql);
        cmd.CommandTimeout = 150;
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<int> ObjectCount(NpgsqlConnection conn, NpgsqlTransaction tx,
        MigrationCatalog.Entry entry, CancellationToken ct)
    {
        var count = 0;
        foreach (var obj in entry.Objects)
            if (await MigrationVerifier.Exists(conn, tx, obj, ct)) count++;
        return count;
    }

    private static async Task CheckOfficial(NpgsqlConnection conn, NpgsqlTransaction tx, CancellationToken ct)
    {
        foreach (var table in MigrationVerifier.OfficialTables)
            if (!await MigrationVerifier.Exists(conn, tx, "public." + table, ct))
                throw new InvalidDataException("FreeRADIUS schema incomplete");
    }

    private static async Task InsertLedger(NpgsqlConnection conn, NpgsqlTransaction tx,
        MigrationCatalog.Entry entry, Guid batch, CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand("""
            INSERT INTO public.app_schema_migrations
                (version, filename, sha256, execution_id, engine_version)
            VALUES (@version, @filename, @sha, @batch, @engine)
            """, conn, tx);
        cmd.Parameters.AddWithValue("version", entry.Version);
        cmd.Parameters.AddWithValue("filename", entry.Filename);
        cmd.Parameters.AddWithValue("sha", entry.Sha256);
        cmd.Parameters.AddWithValue("batch", batch);
        cmd.Parameters.AddWithValue("engine", EngineVersion);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task AdoptIfMissing(NpgsqlConnection conn, IReadOnlyList<MigrationCatalog.Entry> catalog,
        CancellationToken ct)
    {
        await using var tx = await conn.BeginTransactionAsync(ct);
        await CheckOfficial(conn, tx, ct);
        if (!await MigrationVerifier.Exists(conn, tx, "public.app_schema_migrations", ct))
        {
            var complete = new List<MigrationCatalog.Entry>();
            var absentSeen = false;
            foreach (var entry in catalog)
            {
                var count = await ObjectCount(conn, tx, entry, ct);
                if (entry.Version == 1 && count != entry.Objects.Count)
                    throw new InvalidDataException("app_plans missing/partial; refusing a synthetic baseline");
                if (count == 0) absentSeen = true;
                else if (count != entry.Objects.Count)
                    throw new InvalidDataException("Existing application schema is partial; manual repair needed");
                else if (absentSeen)
                    throw new InvalidDataException("Legacy migration objects are out of order");
                else complete.Add(entry);
            }
            await Execute(conn, tx, """
                CREATE TABLE IF NOT EXISTS public.app_schema_migrations (
                    version integer PRIMARY KEY CHECK (version >= 1),
                    filename varchar(160) NOT NULL UNIQUE,
                    sha256 char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
                    applied_at timestamptz NOT NULL DEFAULT now(),
                    execution_id uuid NOT NULL,
                    engine_version varchar(40) NOT NULL
                )
                """, ct);
            var batch = Guid.NewGuid();
            foreach (var entry in complete)
                await InsertLedger(conn, tx, entry, batch, ct);
        }
        await tx.CommitAsync(ct);
    }

    private static async Task<int> VerifiedPrefix(NpgsqlConnection conn, IReadOnlyList<MigrationCatalog.Entry> catalog,
        CancellationToken ct)
    {
        await using var tx = await conn.BeginTransactionAsync(System.Data.IsolationLevel.RepeatableRead, ct);
        await Execute(conn, tx, "SET TRANSACTION READ ONLY", ct);
        await CheckOfficial(conn, tx, ct);
        var rows = new List<MigrationVerifier.LedgerRow>();
        await using (var cmd = MigrationVerifier.Command(conn, tx,
            "SELECT version, filename, sha256 FROM public.app_schema_migrations ORDER BY version"))
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct))
                rows.Add(new(reader.GetInt32(0), reader.GetString(1), reader.GetString(2)));
        MigrationVerifier.VerifyPrefix(catalog, rows);
        for (var i = 0; i < catalog.Count; i++)
        {
            var count = await ObjectCount(conn, tx, catalog[i], ct);
            if (i < rows.Count && count != catalog[i].Objects.Count)
                throw new InvalidDataException($"Applied migration {catalog[i].Version} has missing/partial objects");
            if (i >= rows.Count && count != 0)
                throw new InvalidDataException($"Unrecorded migration {catalog[i].Version} has existing objects; refusing replay");
        }
        await tx.CommitAsync(ct);
        return rows.Count;
    }

    // The official schema comes from the exact tested FreeRADIUS image.
    // This optional path is restricted to the same disposable CI databases.
    private static async Task BootstrapOfficial(NpgsqlConnection conn, string sql, CancellationToken ct)
    {
        await using var tx = await conn.BeginTransactionAsync(ct);
        if (!await MigrationVerifier.Exists(conn, tx, "public.app_plans", ct))
            throw new InvalidDataException("Missing app_plans baseline; refusing automatic repair");
        await using var count = MigrationVerifier.Command(conn, tx, """
            SELECT count(*) FROM pg_catalog.pg_tables
            WHERE schemaname='public' AND tablename IN
                ('radcheck','radreply','radgroupcheck','radgroupreply',
                 'radusergroup','radacct','radpostauth','nas')
            """);
        var existing = (long)(await count.ExecuteScalarAsync(ct) ?? throw new InvalidDataException("Official schema count unavailable"));
        if (existing == 0)
            await Execute(conn, tx, sql, ct);
        else if (existing != MigrationVerifier.OfficialTables.Length)
            throw new InvalidDataException("Official FreeRADIUS schema is partial; refusing automatic repair");
        await CheckOfficial(conn, tx, ct);
        await tx.CommitAsync(ct);
    }

    public static async Task<int> RunAsync(string directory, TextWriter output, TextWriter errors,
        string? officialSchemaFile = null)
    {
        var name = Environment.GetEnvironmentVariable("MIGRATION_DB_NAME");
        var mode = Environment.GetEnvironmentVariable("LAB_MIGRATION_TEST_MODE");
        var stack = Environment.GetEnvironmentVariable("MIGRATION_STACK_ID");
        var stackMode = mode == "isolated-stack-ci" && name == "radius" && officialSchemaFile is not null
            && stack is not null && System.Text.RegularExpressions.Regex.IsMatch(stack, @"\Aradius(?:csharp|https)[a-f0-9]{8}\z");
        if (Environment.GetEnvironmentVariable("CI") != "true"
            || (!stackMode && (mode != "isolated-ci" || !MigrationVerifier.IsIsolatedDatabase(name))))
        {
            errors.WriteLine("C# migration execution requires isolated CI database");
            return 1;
        }
        try
        {
            var inject = Environment.GetEnvironmentVariable("MIGRATION_FAIL_AFTER_SQL_VERSION");
            if (!string.IsNullOrEmpty(inject) && (stackMode || inject is not ("2" or "3" or "4" or "6" or "7" or "8" or "9" or "10")))
                throw new InvalidDataException("Invalid isolated failure injection");
            var catalog = MigrationCatalog.Read(directory);
            var officialSql = officialSchemaFile is null ? null :
                new System.Text.UTF8Encoding(false, true).GetString(File.ReadAllBytes(officialSchemaFile));
            if (officialSql is not null && string.IsNullOrWhiteSpace(officialSql))
                throw new InvalidDataException("Official schema input is empty");
            var builder = stackMode
                ? MigrationVerifier.LabConnection(name!, "radius-csharp-migration-executor")
                : MigrationVerifier.IsolatedConnection(name!, "radius-csharp-migration-executor");
            using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            var ct = deadline.Token;
            await using var conn = new NpgsqlConnection(builder.ConnectionString);
            await conn.OpenAsync(ct);
            if (stackMode)
            {
                // Check the disposable database's explicit marker before any lock or write.
                await using var marker = new NpgsqlCommand("""
                    SELECT shobj_description(oid, 'pg_database') FROM pg_database
                    WHERE datname=current_database()
                    """, conn);
                var actual = await marker.ExecuteScalarAsync(ct) as string;
                if (actual != "radius-csharp-ci:" + stack)
                    throw new InvalidDataException("Isolated stack database marker mismatch");
            }
            await using (var tx = await conn.BeginTransactionAsync(ct))
            {
                await Execute(conn, tx, "SET LOCAL lock_timeout TO '60s'", ct);
                await Execute(conn, tx, $"SELECT pg_advisory_lock({MigrationVerifier.LockNamespace}, {MigrationVerifier.LockId})", ct);
                await tx.CommitAsync(ct);
            }
            // The same physical session holds the shared lock across all version transactions.
            if (officialSql is not null)
                await BootstrapOfficial(conn, officialSql, ct);
            await AdoptIfMissing(conn, catalog, ct);
            var applied = await VerifiedPrefix(conn, catalog, ct);
            foreach (var entry in catalog.Skip(applied))
            {
                await using var tx = await conn.BeginTransactionAsync(ct);
                await Execute(conn, tx, entry.Sql, ct);
                if (await ObjectCount(conn, tx, entry, ct) != entry.Objects.Count)
                    throw new InvalidDataException($"Migration {entry.Version} failed object verification before commit");
                if (inject == entry.Version.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    throw new InvalidDataException($"CI failure injection after version {entry.Version} SQL; transaction rolled back");
                await InsertLedger(conn, tx, entry, Guid.NewGuid(), ct);
                await tx.CommitAsync(ct);
                output.WriteLine($"C# migration applied immutable version {entry.Version}");
            }
            if (await VerifiedPrefix(conn, catalog, ct) != catalog.Count)
                throw new InvalidDataException("Migrations still pending");
            output.WriteLine($"C# migration execution PASS: {catalog.Count} immutable versions (isolated CI)");
            return 0;
        }
        catch (PostgresException ex)
        {
            errors.WriteLine("C# migration execution refused: SQLSTATE " + ex.SqlState);
            return 1;
        }
        catch (InvalidDataException ex)
        {
            errors.WriteLine("C# migration execution refused: " + ex.Message);
            return 1;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException
            or NotSupportedException or System.Text.RegularExpressions.RegexMatchTimeoutException
            or NpgsqlException or OperationCanceledException)
        {
            errors.WriteLine("C# migration execution refused: invalid input or unavailable database");
            return 1;
        }
    }
}
