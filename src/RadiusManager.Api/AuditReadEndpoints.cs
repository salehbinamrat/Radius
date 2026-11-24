using System.Globalization;
using Npgsql;
using NpgsqlTypes;

namespace RadiusManager.Api;

public static class AuditReadRules
{
    public static readonly string[] Actions = [
        "bootstrap_admin", "login_success", "login_failure", "logout", "password_changed",
        "password_change_rejected", "plan_created", "plan_updated", "voucher_created",
        "voucher_disabled", "nas_draft_created", "nas_draft_retired",
        "voucher_owner_assigned", "voucher_owner_transferred"
    ];
    public static bool ValidAction(string? action) => action is null || Actions.Contains(action, StringComparer.Ordinal);
    public static bool ValidOutcome(string? outcome) => outcome is null || outcome is "success" or "denied" or "error";
    public static bool TryDate(string? value, out DateTime? result)
    {
        result = null;
        if (value is null) return true;
        if (!DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            || date.Year < 2000 || date.Year > 9998) return false;
        result = date.ToDateTime(TimeOnly.MinValue, DateTimeKind.Utc);
        return true;
    }
}

public static class AuditReadEndpoints
{
    public static IEndpointRouteBuilder MapAuditReadEndpoints(this IEndpointRouteBuilder app, bool sessionMode)
    {
        app.MapGet("/api/admin-audit", async (HttpContext ctx, NpgsqlDataSource db, CancellationToken ct,
            string? action, string? outcome, string? actor, string? from, string? to, string? before) =>
        {
            if (!sessionMode || !ctx.Request.IsHttps || OwnershipRules.ActorId(ctx.User) is null)
                return Results.StatusCode(403);
            if (!AuditReadRules.ValidAction(action) || !AuditReadRules.ValidOutcome(outcome)
                || (actor is not null && !OwnershipRules.ValidOwnerId(actor))
                || !AuditReadRules.TryDate(from, out var start) || !AuditReadRules.TryDate(to, out var end)
                || (start.HasValue && end.HasValue && start > end))
                return Results.BadRequest(new { error = "مرشحات السجل غير صالحة" });
            long cursor = long.MaxValue;
            if (before is not null && (!long.TryParse(before, NumberStyles.None, CultureInfo.InvariantCulture, out cursor) || cursor <= 0))
                return Results.BadRequest(new { error = "مؤشر الصفحة غير صالح" });
            await using var cmd = db.CreateCommand("""
                SELECT id, actor_user_id, action, subject_kind, subject_id, outcome, occurred_at, correlation_id
                FROM app_admin_audit_events
                WHERE action=ANY(@actions) AND id < @cursor
                  AND (@action IS NULL OR action=@action)
                  AND (@outcome IS NULL OR outcome=@outcome)
                  AND (@actor IS NULL OR actor_user_id=@actor)
                  AND (@start IS NULL OR occurred_at>=@start)
                  AND (@end IS NULL OR occurred_at<@end)
                ORDER BY id DESC LIMIT 51
                """);
            cmd.Parameters.AddWithValue("actions", AuditReadRules.Actions);
            cmd.Parameters.AddWithValue("cursor", cursor);
            cmd.Parameters.AddWithValue("action", NpgsqlDbType.Text, (object?)action ?? DBNull.Value);
            cmd.Parameters.AddWithValue("outcome", NpgsqlDbType.Text, (object?)outcome ?? DBNull.Value);
            cmd.Parameters.AddWithValue("actor", NpgsqlDbType.Text, (object?)actor ?? DBNull.Value);
            cmd.Parameters.AddWithValue("start", NpgsqlDbType.TimestampTz, (object?)start ?? DBNull.Value);
            cmd.Parameters.AddWithValue("end", NpgsqlDbType.TimestampTz, (object?)end?.AddDays(1) ?? DBNull.Value);
            var rows = new List<object>();
            string? last = null, next = null;
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                if (rows.Count == 50) { next = last; break; }
                last = reader.GetInt64(0).ToString(CultureInfo.InvariantCulture);
                rows.Add(new { id = last, actorId = reader.IsDBNull(1) ? null : reader.GetString(1),
                    action = reader.GetString(2), subjectKind = reader.IsDBNull(3) ? null : reader.GetString(3),
                    subjectId = reader.IsDBNull(4) ? null : reader.GetString(4), outcome = reader.GetString(5),
                    occurredAt = reader.GetDateTime(6), correlationId = reader.GetGuid(7) });
            }
            return Results.Ok(new { events = rows, nextBefore = next, limit = 50, labOnly = true });
        }).RequireRateLimiting("admin");
        return app;
    }
}
