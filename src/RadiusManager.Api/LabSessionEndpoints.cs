using Npgsql;

namespace RadiusManager.Api;

/// <summary>
/// Lab-only, read-only inspection of cumulative radacct session snapshots.
/// An open accounting row does not prove that a client is currently online.
/// </summary>
public static class LabSessionRules
{
    public const int PageLimit = 100;
    public static string? Validate(string? state, string? username)
    {
        if (state is not ("all" or "open" or "closed" or "stale"))
            return "اختر حالة جلسة معروفة";
        if (!string.IsNullOrEmpty(username) && !LabAccountRules.IsLabUsername(username))
            return "رقم الكرت التجريبي غير صالح";
        return null;
    }

    public static string Classify(DateTime? stoppedAt, DateTime? updatedAt, bool anomalous, DateTime now)
    {
        if (anomalous) return "anomaly";
        if (stoppedAt.HasValue) return "closed";
        if (!updatedAt.HasValue || updatedAt.Value < now.AddMinutes(-10)) return "stale";
        return "open-unconfirmed";
    }
}

public static class LabSessionEndpoints
{
    public static IEndpointRouteBuilder MapLabSessionEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/lab-sessions", async (string? state, string? username, NpgsqlDataSource db, CancellationToken ct) =>
        {
            state = string.IsNullOrWhiteSpace(state) ? "all" : state;
            username ??= "";
            var error = LabSessionRules.Validate(state, username);
            if (error is not null) return Results.BadRequest(new { error });

            // Restrict to vouchers created by this lab. No production rows or shared secrets.
            // The query never uses caller input as SQL text.
            const string sql = """
                SELECT a.username, COALESCE(a.acctsessionid,''),
                       COALESCE(a.nasipaddress::text,''),
                       COALESCE(a.framedipaddress::text,''),
                       COALESCE(a.callingstationid,''),
                       a.acctstarttime, a.acctupdatetime, a.acctstoptime,
                       a.acctinputoctets, a.acctoutputoctets,
                       COALESCE(a.acctterminatecause,'')
                FROM radacct a
                JOIN app_lab_accounts l ON l.username = a.username
                WHERE (@user = '' OR a.username = @user)
                  AND (
                    @state = 'all'
                    OR (@state = 'open' AND a.acctstoptime IS NULL)
                    OR (@state = 'closed' AND a.acctstoptime IS NOT NULL)
                    OR (@state = 'stale' AND a.acctstoptime IS NULL
                        AND COALESCE(a.acctupdatetime,a.acctstarttime) < now()-interval '10 minutes')
                  )
                ORDER BY COALESCE(a.acctupdatetime,a.acctstarttime) DESC, a.radacctid DESC
                LIMIT 101
                """;
            var rows = new List<object>();
            await using var command = db.CreateCommand(sql);
            command.Parameters.AddWithValue("user", username);
            command.Parameters.AddWithValue("state", state);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var fetched = 0;
            var observedAt = DateTime.UtcNow;
            while (await reader.ReadAsync(ct))
            {
                fetched++;
                if (fetched > LabSessionRules.PageLimit) break;
                DateTime? when(int column) => reader.IsDBNull(column) ? null : reader.GetDateTime(column);
                var started = when(5);
                var lastUpdated = when(6);
                var stopped = when(7);
                long? upload = reader.IsDBNull(8) ? null : reader.GetInt64(8);
                long? download = reader.IsDBNull(9) ? null : reader.GetInt64(9);
                var anomalous = !started.HasValue || (started.HasValue && stopped.HasValue && stopped < started)
                    || (started.HasValue && lastUpdated.HasValue && lastUpdated < started)
                    || upload is null or < 0 || download is null or < 0;
                var classification = LabSessionRules.Classify(stopped, lastUpdated ?? started, anomalous, observedAt);
                rows.Add(new
                {
                    username = reader.GetString(0),
                    sessionId = reader.GetString(1),
                    nasIp = reader.GetString(2),
                    framedIp = reader.GetString(3),
                    callingStationId = reader.GetString(4),
                    startedAt = started,
                    updatedAt = lastUpdated,
                    stoppedAt = stopped,
                    uploadBytes = upload,
                    downloadBytes = download,
                    terminateCause = reader.GetString(10),
                    classification
                });
            }
            return Results.Ok(new
            {
                sessions = rows,
                hasMore = fetched > LabSessionRules.PageLimit,
                limit = LabSessionRules.PageLimit,
                observedAt,
                labOnly = true,
                connectivityVerified = false,
                billingVerified = false,
                warning = "سجلات radacct للمختبر فقط؛ الجلسة المفتوحة ليست دليلا على اتصال مباشر، والبيانات لا تستخدم للفوترة أو خصم الرصيد."
            });
        }).RequireRateLimiting("admin");
        return app;
    }
}
