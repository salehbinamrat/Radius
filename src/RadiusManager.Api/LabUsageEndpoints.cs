using Npgsql;

namespace RadiusManager.Api;

/// <summary>
/// Read-only, lab-only accounting inspection. A radacct row is a cumulative
/// per-session snapshot; its counters must not be treated as per-packet deltas.
/// This is NOT a balance ledger, and it does NOT enforce quotas.
/// </summary>
public static class LabUsageEndpoints
{
    public static IEndpointRouteBuilder MapLabUsageEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/lab-accounts").RequireRateLimiting("admin");
        api.MapGet("/{username}/usage", async (string username, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!LabAccountRules.IsLabUsername(username))
                return Results.BadRequest(new { error = "رقم الكرت التجريبي غير صالح" });

            await using var conn = await db.OpenConnectionAsync(ct);
            await using (var existence = new NpgsqlCommand("SELECT 1 FROM app_lab_accounts WHERE username=@name", conn))
            {
                existence.Parameters.AddWithValue("name", username);
                if (await existence.ExecuteScalarAsync(ct) is null)
                    return Results.NotFound(new { error = "الكرت التجريبي غير موجود" });
            }
            await using var cmd = new NpgsqlCommand("SELECT * FROM app_lab_usage_snapshot(@name)", conn);
            cmd.Parameters.AddWithValue("name", username);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct))
                return Results.Problem("Accounting snapshot unavailable", statusCode: 503);

            var report = new LabUsageReport(
                Username: username,
                UploadBytes: reader.GetDecimal(0),
                DownloadBytes: reader.GetDecimal(1),
                Sessions: reader.GetInt64(2),
                OpenSessions: reader.GetInt64(3),
                StaleSessions: reader.GetInt64(4),
                AnomalousSessions: reader.GetInt64(5),
                ObservedNas: reader.GetInt64(6),
                LatestAccountingAt: reader.IsDBNull(7) ? null : reader.GetDateTime(7));
            return Results.Ok(new
            {
                report.Username, report.UploadBytes, report.DownloadBytes,
                TotalBytes = report.TotalBytes, report.Sessions, report.OpenSessions,
                report.StaleSessions, report.AnomalousSessions, report.ObservedNas,
                report.LatestAccountingAt,
                ReportIsFinal = report.IsClosedAndUnanomalous,
                BillingVerified = false,
                QuotaEnforced = false,
                Warning = "سجل استهلاك تجريبي فقط. الرسائل المفقودة أو المتأخرة قد تغير النتيجة، ولا يجوز استخدامه لخصم رصيد كرت فعلي."
            });
        });
        return app;
    }
}

public sealed record LabUsageReport(
    string Username,
    decimal UploadBytes,
    decimal DownloadBytes,
    long Sessions,
    long OpenSessions,
    long StaleSessions,
    long AnomalousSessions,
    long ObservedNas,
    DateTime? LatestAccountingAt)
{
    public decimal TotalBytes => checked(UploadBytes + DownloadBytes);
    public bool IsClosedAndUnanomalous =>
        Sessions > 0 && OpenSessions == 0 && StaleSessions == 0 && AnomalousSessions == 0;
}
