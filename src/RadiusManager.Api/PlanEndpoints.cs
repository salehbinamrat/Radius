using System.Data;
using Npgsql;

namespace RadiusManager.Api;

/// <summary>Laboratory plan routes, preserving existing transactions and public API paths.</summary>
public static class PlanEndpoints
{
    public static IEndpointRouteBuilder MapPlanEndpoints(this IEndpointRouteBuilder api)
    {
        api.MapGet("/plans", async (NpgsqlDataSource dataSource, CancellationToken ct) =>
        {
            var plans = new List<object>();
            await using var cmd = dataSource.CreateCommand("SELECT id,name,download_kbps,upload_kbps,quota_bytes,validity_days,active FROM app_plans ORDER BY created_at DESC LIMIT 100");
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                plans.Add(new { id = reader.GetGuid(0), name = reader.GetString(1), downloadKbps = reader.GetInt32(2), uploadKbps = reader.GetInt32(3), quotaBytes = reader.IsDBNull(4) ? (long?)null : reader.GetInt64(4), validityDays = reader.IsDBNull(5) ? (int?)null : reader.GetInt32(5), active = reader.GetBoolean(6) });
            return Results.Ok(plans);
        });

        api.MapPost("/plans", async (PlanInput input, NpgsqlDataSource dataSource, CancellationToken ct) =>
        {
            var validation = PlanRules.Validate(input);
            if (validation is not null) return Results.BadRequest(new { error = validation });
            var id = Guid.NewGuid();
            await using var conn = await dataSource.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            try
            {
                await using (var cmd = new NpgsqlCommand("INSERT INTO app_plans (id,name,upload_kbps,download_kbps,quota_bytes,validity_days) VALUES (@id,@name,@up,@down,@quota,@days)", conn, tx))
                {
                    cmd.Parameters.AddWithValue("id", id);
                    cmd.Parameters.AddWithValue("name", input.Name.Trim());
                    cmd.Parameters.AddWithValue("up", input.UploadKbps);
                    cmd.Parameters.AddWithValue("down", input.DownloadKbps);
                    cmd.Parameters.AddWithValue("quota", (object?)PlanRules.QuotaBytes(input.QuotaMb) ?? DBNull.Value);
                    cmd.Parameters.AddWithValue("days", (object?)input.ValidityDays ?? DBNull.Value);
                    await cmd.ExecuteNonQueryAsync(ct);
                }
                await using (var cmd = new NpgsqlCommand("INSERT INTO radgroupreply (groupname,attribute,op,value) VALUES (@group,'Mikrotik-Rate-Limit',':=',@rate)", conn, tx))
                {
                    cmd.Parameters.AddWithValue("group", PlanRules.GroupName(id));
                    cmd.Parameters.AddWithValue("rate", PlanRules.MikroTikRate(input.UploadKbps,input.DownloadKbps));
                    await cmd.ExecuteNonQueryAsync(ct);
                }
                await tx.CommitAsync(ct);
                return Results.Created($"/api/plans/{id}", new { id, rate = PlanRules.MikroTikRate(input.UploadKbps,input.DownloadKbps), accountingEnforced = false });
            }
            catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
            {
                await tx.RollbackAsync(ct);
                return Results.Conflict(new { error = "اسم الباقة موجود مسبقا" });
            }
        });

        api.MapPut("/plans/{id:guid}", async (Guid id, PlanInput input, NpgsqlDataSource dataSource, CancellationToken ct) =>
        {
            var validation = PlanRules.Validate(input);
            if (validation is not null) return Results.BadRequest(new { error = validation });
            await using var conn = await dataSource.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            try
            {
                await using (var cmd = new NpgsqlCommand("UPDATE app_plans SET name=@name, upload_kbps=@up,download_kbps=@down,quota_bytes=@quota,validity_days=@days,updated_at=now() WHERE id=@id", conn, tx))
                {
                    cmd.Parameters.AddWithValue("id", id);
                    cmd.Parameters.AddWithValue("name", input.Name.Trim());
                    cmd.Parameters.AddWithValue("up", input.UploadKbps);
                    cmd.Parameters.AddWithValue("down", input.DownloadKbps);
                    cmd.Parameters.AddWithValue("quota", (object?)PlanRules.QuotaBytes(input.QuotaMb) ?? DBNull.Value);
                    cmd.Parameters.AddWithValue("days", (object?)input.ValidityDays ?? DBNull.Value);
                    if (await cmd.ExecuteNonQueryAsync(ct) == 0)
                    {
                        await tx.RollbackAsync(ct);
                        return Results.NotFound(new { error = "الباقة غير موجودة" });
                    }
                }
                await using (var cmd = new NpgsqlCommand("UPDATE radgroupreply SET value=@rate WHERE groupname=@group AND attribute='Mikrotik-Rate-Limit'",conn,tx))
                {
                    cmd.Parameters.AddWithValue("rate",PlanRules.MikroTikRate(input.UploadKbps,input.DownloadKbps));
                    cmd.Parameters.AddWithValue("group", PlanRules.GroupName(id));
                    if (await cmd.ExecuteNonQueryAsync(ct) != 1)
                        throw new DataException("RADIUS reply row missing; update rolled back.");
                }
                await tx.CommitAsync(ct);
                return Results.Ok(new { id, updated = true, accountingEnforced = false });
            }
            catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
            {
                await tx.RollbackAsync(ct);
                return Results.Conflict(new { error = "اسم الباقة موجود مسبقا" });
            }
        });


        return api;
    }
}
