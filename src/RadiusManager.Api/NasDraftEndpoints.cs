using Npgsql;

namespace RadiusManager.Api;

/// <summary>Inventory only: never changes FreeRADIUS client configuration or a MikroTik device.</summary>
public sealed record NasDraftInput(string? Name, string? Site, string? VpnIp);

public static class NasDraftRules
{
    public static string? Validate(NasDraftInput? input)
    {
        if (input is null) return "بيانات الراوتر مطلوبة";
        if (!SafeLabel(input.Name, 64)) return "اسم الراوتر غير صالح (3 إلى 64 حرفا)";
        if (!SafeLabel(input.Site, 80)) return "اسم الموقع غير صالح (3 إلى 80 حرفا)";
        if (!TryPrivateIpv4(input.VpnIp, out _))
            return "استخدم عنوان IPv4 خاصا داخل VPN فقط، دون عنوان عام أو اسم نطاق";
        return null;
    }

    private static bool SafeLabel(string? value, int max)
    {
        if (value is null) return false;
        var text = value.Trim();
        return text.Length is >= 3 && text.Length <= max &&
            text.All(c => char.IsLetterOrDigit(c) || c is ' ' or '-' or '_' or '.');
    }

    public static bool TryPrivateIpv4(string? value, out string normalized)
    {
        normalized = "";
        if (string.IsNullOrWhiteSpace(value) || value != value.Trim()) return false;
        var parts = value.Split('.');
        if (parts.Length != 4) return false;
        var bytes = new int[4];
        for (var i = 0; i < 4; i++)
        {
            var p = parts[i];
            if (p.Length is < 1 or > 3 || (p.Length > 1 && p[0] == '0') ||
                !p.All(c => c is >= '0' and <= '9') ||
                !int.TryParse(p, out bytes[i]) || bytes[i] > 255) return false;
        }
        // Conservative initial restriction; network/broadcast addresses require topology awareness.
        if (bytes[3] is 0 or 255) return false;
        if (!(bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168))) return false;
        normalized = string.Join('.', bytes);
        return true;
    }
}

public static class NasDraftEndpoints
{
    public static IEndpointRouteBuilder MapNasDraftEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/nas-drafts").RequireRateLimiting("admin");
        api.MapGet("", async (NpgsqlDataSource db, CancellationToken ct) =>
        {
            var rows = new List<object>();
            await using var cmd = db.CreateCommand("""
                SELECT id,label,site,host(vpn_ip),created_at,retired_at
                FROM app_nas_drafts ORDER BY created_at DESC LIMIT 100
                """);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                rows.Add(new {
                    id = reader.GetGuid(0), name = reader.GetString(1), site = reader.GetString(2),
                    vpnIp = reader.GetString(3), createdAt = reader.GetDateTime(4),
                    retired = !reader.IsDBNull(5),
                    retiredAt = reader.IsDBNull(5) ? (DateTime?)null : reader.GetDateTime(5),
                    radiusClientEnabled = false, connectivityVerified = false
                });
            return Results.Ok(new {
                drafts = rows, limit = 100, labOnly = true, radiusRegistrationEnabled = false,
                warning = "سجل تخطيط فقط؛ لا يضيف أجهزة إلى FreeRADIUS ولا يتصل براوترات MikroTik ولا يحفظ أسرار RADIUS."
            });
        });

        api.MapPost("", async (NasDraftInput input, NpgsqlDataSource db, CancellationToken ct) =>
        {
            var error = NasDraftRules.Validate(input);
            if (error is not null) return Results.BadRequest(new { error });
            var id = Guid.NewGuid();
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            try
            {
                await using (var cmd = new NpgsqlCommand("""
                    INSERT INTO app_nas_drafts(id,label,site,vpn_ip)
                    VALUES (@id,@name,@site,CAST(@ip AS inet))
                    """, conn, tx))
                {
                    cmd.Parameters.AddWithValue("id", id);
                    cmd.Parameters.AddWithValue("name", input.Name!.Trim());
                    cmd.Parameters.AddWithValue("site", input.Site!.Trim());
                    cmd.Parameters.AddWithValue("ip", input.VpnIp!);
                    await cmd.ExecuteNonQueryAsync(ct);
                }
                await using (var audit = new NpgsqlCommand("""
                    INSERT INTO app_nas_draft_events(draft_id,operation) VALUES (@id,'created')
                    """,conn,tx))
                {
                    audit.Parameters.AddWithValue("id", id);
                    await audit.ExecuteNonQueryAsync(ct);
                }
                await tx.CommitAsync(ct);
                return Results.Created($"/api/nas-drafts/{id}", new {
                    id, name = input.Name!.Trim(), site = input.Site!.Trim(), vpnIp = input.VpnIp,
                    retired = false, radiusClientEnabled = false, connectivityVerified = false, labOnly = true
                });
            }
            catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
            {
                await tx.RollbackAsync(ct);
                return Results.Conflict(new { error = "اسم الراوتر أو عنوان VPN مستخدم بالفعل" });
            }
        });

        api.MapPost("/{id:guid}/retire", async (Guid id, NpgsqlDataSource db, CancellationToken ct) =>
        {
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            await using (var cmd = new NpgsqlCommand("""
                UPDATE app_nas_drafts SET retired_at = now()
                WHERE id = @id AND retired_at IS NULL RETURNING id
                """,conn,tx))
            {
                cmd.Parameters.AddWithValue("id",id);
                if (await cmd.ExecuteScalarAsync(ct) is null)
                {
                    await tx.RollbackAsync(ct);
                    return Results.NotFound(new { error = "المسودة غير موجودة أو أُغلقت مسبقا" });
                }
            }
            await using (var audit = new NpgsqlCommand("""
                INSERT INTO app_nas_draft_events(draft_id,operation) VALUES (@id,'retired')
                """,conn,tx))
            {
                audit.Parameters.AddWithValue("id",id);
                await audit.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
            return Results.Ok(new { id, retired = true, radiusClientEnabled = false });
        });
        return app;
    }
}
