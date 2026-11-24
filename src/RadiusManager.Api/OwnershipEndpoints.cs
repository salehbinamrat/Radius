using System.Security.Claims;
using Npgsql;

namespace RadiusManager.Api;

public sealed record AssignOwnershipInput(string? OwnerId);

public static class OwnershipRules
{
    public static string? ActorId(ClaimsPrincipal? user)
    {
        if (!AdminAuthorizationRules.CanAccessSharedLab(user) || !user!.IsInRole("super-admin"))
            return null;
        var ids = user.FindAll(ClaimTypes.NameIdentifier).Select(c => c.Value).ToArray();
        return ids.Length == 1 && ValidOwnerId(ids[0]) ? ids[0] : null;
    }

    public static bool ValidOwnerId(string? id) =>
        id is { Length: > 0 and <= 160 } && !string.IsNullOrWhiteSpace(id)
        && id == id.Trim() && !id.Any(char.IsControl);

    public static bool IsAllowed(ClaimsPrincipal user, string method, string path)
    {
        if (ActorId(user) is null) return false;
        if (path is "/api/ownership/resellers" or "/api/ownership/accounts") return method is "GET" or "HEAD";
        var parts = path.Split('/');
        return method == "POST" && parts.Length == 6 && parts[1] == "api"
            && parts[2] == "ownership" && parts[3] == "accounts"
            && LabAccountRules.IsLabUsername(parts[4]) && parts[5] == "assign";
    }
}

public static class OwnershipEndpoints
{
    // Eligible identities must have exactly one role, reseller. A mixed role is never eligible.
    private const string EligibleResellers = """
        SELECT u."Id", u."UserName" FROM "AspNetUsers" u
        JOIN "AspNetUserRoles" ur ON ur."UserId"=u."Id"
        JOIN "AspNetRoles" r ON r."Id"=ur."RoleId"
        WHERE r."Name"='reseller'
          AND (SELECT count(*) FROM "AspNetUserRoles" x WHERE x."UserId"=u."Id")=1
        """;

    public static IEndpointRouteBuilder MapOwnershipEndpoints(this IEndpointRouteBuilder app, bool sessionMode)
    {
        var api = app.MapGroup("/api/ownership").RequireRateLimiting("admin");
        api.MapGet("/resellers", async (HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!sessionMode || !ctx.Request.IsHttps || OwnershipRules.ActorId(ctx.User) is null)
                return Results.StatusCode(403);
            var rows = new List<object>();
            // Bound the response; no email, password hashes, stamps or session identifiers.
            await using var cmd = db.CreateCommand(EligibleResellers + """
                 
                ORDER BY u."UserName", u."Id" LIMIT 101
                """);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            bool hasMore = false;
            while (await reader.ReadAsync(ct))
            {
                if (rows.Count == 100) { hasMore = true; break; }
                rows.Add(new { id = reader.GetString(0), username = reader.IsDBNull(1) ? null : reader.GetString(1) });
            }
            return Results.Ok(new { resellers = rows, hasMore, limit = 100, labOnly = true });
        });

        api.MapGet("/accounts", async (HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!sessionMode || !ctx.Request.IsHttps || OwnershipRules.ActorId(ctx.User) is null)
                return Results.StatusCode(403);
            var rows = new List<object>();
            await using var cmd = db.CreateCommand("""
                SELECT a.username, p.name FROM app_lab_accounts a
                JOIN app_plans p ON p.id=a.plan_id
                WHERE a.active AND NOT EXISTS (
                    SELECT 1 FROM app_lab_account_owners o WHERE o.username=a.username)
                ORDER BY a.created_at DESC, a.username LIMIT 101
                """);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            bool hasMore = false;
            while (await reader.ReadAsync(ct))
            {
                if (rows.Count == 100) { hasMore = true; break; }
                rows.Add(new { username = reader.GetString(0), planName = reader.GetString(1) });
            }
            return Results.Ok(new { accounts = rows, hasMore, limit = 100, labOnly = true });
        });

        api.MapPost("/accounts/{username}/assign", async (string username, AssignOwnershipInput input,
            HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            var actor = sessionMode && ctx.Request.IsHttps ? OwnershipRules.ActorId(ctx.User) : null;
            if (actor is null) return Results.StatusCode(403);
            if (!LabAccountRules.IsLabUsername(username) || !OwnershipRules.ValidOwnerId(input.OwnerId))
                return Results.BadRequest(new { error = "رقم الكرت أو معرف الوكيل غير صالح" });
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            // Lock the registered account before checking assignment; disabling the account
            // also updates this row, so assignment cannot race a completed disable.
            await using (var account = new NpgsqlCommand("""
                SELECT active FROM app_lab_accounts WHERE username=@name FOR UPDATE
                """, conn, tx))
            {
                account.Parameters.AddWithValue("name", username);
                var active = await account.ExecuteScalarAsync(ct);
                if (active is null) return Results.NotFound(new { error = "الكرت التجريبي غير موجود" });
                if (active is not true) return Results.Conflict(new { error = "الكرت التجريبي معطل" });
            }
            await using (var insert = new NpgsqlCommand("""
                INSERT INTO app_lab_account_owners(username,owner_user_id)
                SELECT @name, eligible."Id" FROM (
                """ + "\n" + EligibleResellers + """
                 
                ) eligible WHERE eligible."Id"=@owner
                ON CONFLICT (username) DO NOTHING
                RETURNING username
                """, conn, tx))
            {
                insert.Parameters.AddWithValue("name", username);
                insert.Parameters.AddWithValue("owner", input.OwnerId!);
                if (await insert.ExecuteScalarAsync(ct) is null)
                    return Results.Conflict(new { error = "الكرت منسوب بالفعل أو الوكيل غير مؤهل" });
            }
            // The immutable initial assignment stores the owner; the audit identifies
            // the actor and voucher. An audit failure rolls back the assignment.
            await using (var audit = new NpgsqlCommand("""
                INSERT INTO app_admin_audit_events(actor_user_id,action,subject_kind,subject_id,outcome,correlation_id)
                VALUES (@actor,'voucher_owner_assigned','lab_account',@name,'success',@correlation)
                """, conn, tx))
            {
                audit.Parameters.AddWithValue("actor", actor);
                audit.Parameters.AddWithValue("name", username);
                audit.Parameters.AddWithValue("correlation", Guid.NewGuid());
                await audit.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
            return Results.Ok(new { username, ownerId = input.OwnerId, assigned = true, labOnly = true });
        });
        return app;
    }
}
