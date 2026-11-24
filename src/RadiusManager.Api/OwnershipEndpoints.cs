using System.Security.Claims;
using Npgsql;

namespace RadiusManager.Api;

public sealed record AssignOwnershipInput(string? OwnerId);
public sealed record TransferOwnershipInput(string? ExpectedOwnerId, Guid ExpectedVersion, string? NewOwnerId);

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
        if (parts.Length != 6 || parts[1] != "api" || parts[2] != "ownership"
            || parts[3] != "accounts" || !LabAccountRules.IsLabUsername(parts[4])) return false;
        return (method is "GET" or "HEAD") && (parts[5] is "owner" or "history")
            || method == "POST" && (parts[5] is "assign" or "transfer");
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
        api.MapGet("/accounts/{username}/owner", async (string username, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!sessionMode || !ctx.Request.IsHttps || OwnershipRules.ActorId(ctx.User) is null)
                return Results.StatusCode(403);
            if (!LabAccountRules.IsLabUsername(username)) return Results.BadRequest();
            await using var cmd = db.CreateCommand("""
                SELECT a.active, o.owner_user_id, o.ownership_version
                FROM app_lab_accounts a
                LEFT JOIN app_lab_account_owners o ON o.username=a.username
                WHERE a.username=@name
                """);
            cmd.Parameters.AddWithValue("name", username);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return Results.NotFound();
            return Results.Ok(new { username, active = reader.GetBoolean(0),
                ownerId = reader.IsDBNull(1) ? null : reader.GetString(1),
                version = reader.IsDBNull(2) ? (Guid?)null : reader.GetGuid(2), labOnly = true });
        });

        api.MapGet("/accounts/{username}/history", async (string username, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!sessionMode || !ctx.Request.IsHttps || OwnershipRules.ActorId(ctx.User) is null)
                return Results.StatusCode(403);
            if (!LabAccountRules.IsLabUsername(username)) return Results.BadRequest();
            // Current owner and bounded history are read in the same SQL statement/snapshot.
            await using var cmd = db.CreateCommand("""
                SELECT a.active,o.owner_user_id,o.ownership_version,
                    t.id,t.previous_owner_id,t.new_owner_id,t.actor_user_id,t.occurred_at
                FROM app_lab_accounts a
                LEFT JOIN app_lab_account_owners o ON o.username=a.username
                LEFT JOIN LATERAL (
                    SELECT id,previous_owner_id,new_owner_id,actor_user_id,occurred_at
                    FROM app_lab_owner_transfers WHERE username=a.username
                    ORDER BY occurred_at DESC,id DESC LIMIT 51
                ) t ON true
                WHERE a.username=@name
                ORDER BY t.occurred_at DESC,t.id DESC
                """);
            cmd.Parameters.AddWithValue("name", username);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return Results.NotFound();
            var active = reader.GetBoolean(0);
            var ownerId = reader.IsDBNull(1) ? null : reader.GetString(1);
            var version = reader.IsDBNull(2) ? (Guid?)null : reader.GetGuid(2);
            var rows = new List<object>();
            var hasMore = false;
            do
            {
                if (reader.IsDBNull(3)) continue;
                if (rows.Count == 50) { hasMore = true; break; }
                rows.Add(new { id = reader.GetGuid(3), previousOwnerId = reader.GetString(4),
                    newOwnerId = reader.GetString(5), actorId = reader.GetString(6),
                    occurredAt = reader.GetDateTime(7) });
            } while (await reader.ReadAsync(ct));
            return Results.Ok(new { username, active, ownerId, version, transfers = rows,
                hasMore, limit = 50, labOnly = true });
        });

        api.MapPost("/accounts/{username}/transfer", async (string username, TransferOwnershipInput input,
            HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            var actor = sessionMode && ctx.Request.IsHttps ? OwnershipRules.ActorId(ctx.User) : null;
            if (actor is null) return Results.StatusCode(403);
            if (!LabAccountRules.IsLabUsername(username) || !OwnershipRules.ValidOwnerId(input.ExpectedOwnerId)
                || !OwnershipRules.ValidOwnerId(input.NewOwnerId) || input.ExpectedVersion == Guid.Empty
                || input.ExpectedOwnerId == input.NewOwnerId)
                return Results.BadRequest(new { error = "بيانات نقل الملكية غير صالحة" });
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            await using (var account = new NpgsqlCommand("""
                SELECT active FROM app_lab_accounts WHERE username=@name FOR UPDATE
                """, conn, tx))
            {
                account.Parameters.AddWithValue("name", username);
                var active = await account.ExecuteScalarAsync(ct);
                if (active is null) return Results.NotFound();
                if (active is not true) return Results.Conflict(new { error = "الكرت التجريبي معطل" });
            }
            var next = Guid.NewGuid();
            var correlation = Guid.NewGuid();
            await using (var update = new NpgsqlCommand("""
                UPDATE app_lab_account_owners o
                SET owner_user_id=@newOwner, ownership_version=@next, assigned_at=now()
                WHERE o.username=@name AND o.owner_user_id=@oldOwner AND o.ownership_version=@expected
                AND EXISTS (SELECT 1 FROM (
                """ + "\n" + EligibleResellers + """
                ) eligible WHERE eligible."Id"=@newOwner)
                RETURNING o.username
                """, conn, tx))
            {
                update.Parameters.AddWithValue("name", username);
                update.Parameters.AddWithValue("oldOwner", input.ExpectedOwnerId!);
                update.Parameters.AddWithValue("newOwner", input.NewOwnerId!);
                update.Parameters.AddWithValue("expected", input.ExpectedVersion);
                update.Parameters.AddWithValue("next", next);
                if (await update.ExecuteScalarAsync(ct) is null)
                    return Results.Conflict(new { error = "تغيرت الملكية أو الوكيل غير مؤهل. أعد قراءة الحالة." });
            }
            await using (var history = new NpgsqlCommand("""
                INSERT INTO app_lab_owner_transfers(id,username,previous_owner_id,new_owner_id,actor_user_id,previous_version,new_version)
                VALUES (@correlation,@name,@oldOwner,@newOwner,@actor,@expected,@next)
                """, conn, tx))
            {
                history.Parameters.AddWithValue("correlation", correlation);
                history.Parameters.AddWithValue("name", username);
                history.Parameters.AddWithValue("oldOwner", input.ExpectedOwnerId!);
                history.Parameters.AddWithValue("newOwner", input.NewOwnerId!);
                history.Parameters.AddWithValue("actor", actor);
                history.Parameters.AddWithValue("expected", input.ExpectedVersion);
                history.Parameters.AddWithValue("next", next);
                await history.ExecuteNonQueryAsync(ct);
            }
            await using (var audit = new NpgsqlCommand("""
                INSERT INTO app_admin_audit_events(actor_user_id,action,subject_kind,subject_id,outcome,correlation_id)
                VALUES (@actor,'voucher_owner_transferred','lab_account',@name,'success',@correlation)
                """, conn, tx))
            {
                audit.Parameters.AddWithValue("actor", actor);
                audit.Parameters.AddWithValue("name", username);
                audit.Parameters.AddWithValue("correlation", correlation);
                await audit.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
            return Results.Ok(new { username, ownerId = input.NewOwnerId, version = next, transferred = true, labOnly = true });
        });
        return app;
    }
}
