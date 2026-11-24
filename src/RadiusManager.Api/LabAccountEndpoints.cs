using Npgsql;

namespace RadiusManager.Api;

public static class LabAccountEndpoints
{
    public static IEndpointRouteBuilder MapLabAccountEndpoints(this IEndpointRouteBuilder app, bool sessionMode)
    {
        // All routes are under the existing /api Basic-auth middleware.
        var api = app.MapGroup("/api/lab-accounts").RequireRateLimiting("admin");

        api.MapGet("", async (NpgsqlDataSource db, CancellationToken ct) =>
        {
            var rows = new List<object>();
            await using var cmd = db.CreateCommand("""
                SELECT l.username, p.name, l.active, l.created_at, l.disabled_at
                  FROM app_lab_accounts l JOIN app_plans p ON p.id=l.plan_id
                 ORDER BY l.created_at DESC LIMIT 100
                """);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                rows.Add(new {
                    username = reader.GetString(0), planName = reader.GetString(1),
                    active = reader.GetBoolean(2), createdAt = reader.GetDateTime(3),
                    disabledAt = reader.IsDBNull(4) ? (DateTime?)null : reader.GetDateTime(4)
                });
            return Results.Ok(rows);
        });

        api.MapPost("", async (CreateLabAccountInput input, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (input.PlanId == Guid.Empty)
                return Results.BadRequest(new { error = "اختر باقة تجريبية" });

            string username = LabAccountRules.GenerateUsername();
            string password = LabAccountRules.GeneratePassword();
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            try
            {
                // A lab voucher is allowed only when the selected active plan
                // has NO unenforced quota / validity settings.
                await using (var cmd = new NpgsqlCommand("""
                    INSERT INTO app_lab_accounts(username, plan_id)
                    SELECT @username, id FROM app_plans
                    WHERE id=@plan AND active=true AND quota_bytes IS NULL AND validity_days IS NULL
                    RETURNING username
                    """, conn, tx))
                {
                    cmd.Parameters.AddWithValue("username", username);
                    cmd.Parameters.AddWithValue("plan", input.PlanId);
                    if (await cmd.ExecuteScalarAsync(ct) is null)
                    {
                        await tx.RollbackAsync(ct);
                        return Results.BadRequest(new { error = "الباقة غير موجودة أو تتضمن رصيدا أو صلاحية لم نفعلهما بعد" });
                    }
                }
                await using (var cmd = new NpgsqlCommand("""
                    INSERT INTO radcheck(username,attribute,op,value)
                    VALUES (@username, 'Cleartext-Password', ':=', @secret)
                    """,conn,tx))
                {
                    cmd.Parameters.AddWithValue("username", username);
                    cmd.Parameters.AddWithValue("secret", password);
                    await cmd.ExecuteNonQueryAsync(ct);
                }
                await using (var cmd = new NpgsqlCommand("""
                    INSERT INTO radusergroup(username,groupname,priority)
                    VALUES (@username,@group,0)
                    """,conn,tx))
                {
                    cmd.Parameters.AddWithValue("username", username);
                    cmd.Parameters.AddWithValue("group", PlanRules.GroupName(input.PlanId));
                    await cmd.ExecuteNonQueryAsync(ct);
                }
                await LabMutationAudit.AppendAsync(conn, tx, ctx.User, sessionMode, LabMutation.VoucherCreated, username, ct);
                await tx.CommitAsync(ct);
                return Results.Created("/api/lab-accounts", new {
                    username, password, labOnly = true, passwordDisplayedOnce = true,
                    accountingEnforced = false
                });
            }
            catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
            {
                await tx.RollbackAsync(ct);
                return Results.Conflict(new { error = "تعارض نادر في رقم الاختبار. أعد المحاولة" });
            }
        });

        api.MapPost("/{username}/disable", async (string username, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!LabAccountRules.IsLabUsername(username))
                return Results.BadRequest(new { error = "رقم الكرت التجريبي غير صالح" });
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            await using (var cmd = new NpgsqlCommand("""
                UPDATE app_lab_accounts SET active=false, disabled_at=now()
                WHERE username=@username AND active=true RETURNING username
                """,conn,tx))
            {
                cmd.Parameters.AddWithValue("username", username);
                if (await cmd.ExecuteScalarAsync(ct) is null)
                {
                    await tx.RollbackAsync(ct);
                    return Results.NotFound(new { error = "الكرت غير موجود أو موقوف بالفعل" });
                }
            }
            await using (var cmd = new NpgsqlCommand("""
                DELETE FROM radcheck WHERE username=@username AND attribute='Cleartext-Password'
                """,conn,tx))
            {
                cmd.Parameters.AddWithValue("username", username);
                await cmd.ExecuteNonQueryAsync(ct);
            }
            await using (var cmd = new NpgsqlCommand("""
                DELETE FROM radusergroup WHERE username=@username
                """,conn,tx))
            {
                cmd.Parameters.AddWithValue("username", username);
                await cmd.ExecuteNonQueryAsync(ct);
            }
            await LabMutationAudit.AppendAsync(conn, tx, ctx.User, sessionMode, LabMutation.VoucherDisabled, username, ct);
            await tx.CommitAsync(ct);
            return Results.Ok(new {
                username, disabled = true, newLoginsBlocked = true,
                existingSessionsMayContinue = true
            });
        });
        return app;
    }
}
