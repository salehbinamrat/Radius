using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RadiusManager.Api;

/// <summary>Read-only migration catalog; no database connection or schema changes.</summary>
public static class MigrationCatalog
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly Regex AuditTrigger = new(
        @"(?im)^BEFORE UPDATE OR DELETE OR TRUNCATE ON public\.(?:app_admin_audit_events|app_lab_owner_transfers)\s*$",
        RegexOptions.CultureInvariant, TimeSpan.FromSeconds(2));
    private static readonly Regex Destructive = new(
        @"\b(?:DROP\s+(?:TABLE|SCHEMA|DATABASE)|TRUNCATE\b)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(2));

    private static readonly (int Version, string Filename, string[] Objects)[] Definitions =
    [
        (1, "001_app.sql", ["public.app_plans"]),
        (2, "002_lab_accounts.sql", ["public.app_lab_accounts", "public.idx_app_lab_accounts_created"]),
        (3, "003_accounting.sql", ["procedure:public.app_lab_usage_snapshot(character varying)"]),
        (4, "004_nas_drafts.sql", ["public.app_nas_drafts", "public.app_nas_draft_events", "public.idx_nas_drafts_created"]),
        (5, "005_admin_identity.sql", [
            "public.\"AspNetUsers\"", "public.\"AspNetRoles\"", "public.\"AspNetUserRoles\"",
            "public.\"AspNetUserClaims\"", "public.\"AspNetRoleClaims\"", "public.\"AspNetUserLogins\"",
            "public.\"AspNetUserTokens\"", "public.app_admin_sessions", "public.app_admin_audit_events",
            "public.idx_admin_sessions_user_active", "public.idx_admin_audit_actor_time"]),
        (6, "006_reseller_ownership.sql", ["public.app_lab_account_owners", "public.idx_lab_account_owners_owner"]),
        (7, "007_ownership_transfers.sql", ["public.app_lab_owner_transfers", "public.idx_lab_owner_transfers_account",
            "column:public.app_lab_account_owners.ownership_version"]),
        (8, "008_audit_append_only.sql", ["procedure:public.app_reject_audit_mutation()",
            "trigger:public.app_admin_audit_events.audit_append_only",
            "trigger:public.app_lab_owner_transfers.ownership_history_append_only"]),
        (9, "009_accounting_read_indexes.sql", ["index:public.idx_app_radacct_recent", "index:public.idx_app_radacct_user_recent"]),
        (10, "010_accounting_quality.sql", ["procedure:public.app_accounting_row_anomalous(public.radacct)"])
    ];

    public sealed record Entry(int Version, string Filename, string Sha256, IReadOnlyList<string> Objects);

    public static IReadOnlyList<Entry> Read(string directory)
    {
        var entries = new List<Entry>(Definitions.Length);
        foreach (var definition in Definitions)
        {
            var raw = File.ReadAllBytes(Path.Combine(directory, definition.Filename));
            var sql = StrictUtf8.GetString(raw);
            ValidateSql(definition.Filename, sql);
            entries.Add(new Entry(definition.Version, definition.Filename,
                Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant(),
                Array.AsReadOnly(definition.Objects)));
        }
        return entries.AsReadOnly();
    }

    public static void ValidateSql(string filename, string sql)
    {
        // Match the existing migrator's narrow guard. This is not a SQL parser.
        var scan = filename == "008_audit_append_only.sql" ? AuditTrigger.Replace(sql, "") : sql;
        if (Destructive.IsMatch(scan))
            throw new InvalidDataException("Destructive migration SQL rejected.");
    }

    public static int WriteManifest(string directory, TextWriter output, TextWriter errors)
    {
        try
        {
            // Validate everything before emitting the first line.
            var entries = Read(directory);
            foreach (var entry in entries)
                output.WriteLine(string.Join("\t", entry.Version.ToString(CultureInfo.InvariantCulture),
                    entry.Filename, entry.Sha256, string.Join("|", entry.Objects)));
            return 0;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
            or ArgumentException or NotSupportedException or RegexMatchTimeoutException)
        {
            errors.WriteLine("Migration catalog rejected: missing, invalid or prohibited source.");
            return 1;
        }
    }
}
