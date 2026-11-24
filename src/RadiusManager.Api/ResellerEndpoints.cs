using System.Security.Claims;
using Npgsql;

namespace RadiusManager.Api;

public static class ResellerScope
{
    public static string? OwnerId(ClaimsPrincipal? user)
    {
        if (user?.Identity is not ClaimsIdentity identity || !identity.IsAuthenticated) return null;
        var roles = user.FindAll(identity.RoleClaimType).Select(c => c.Value).Distinct(StringComparer.Ordinal).ToArray();
        if (roles.Length != 1 || roles[0] != "reseller") return null;
        var ids = user.FindAll(ClaimTypes.NameIdentifier).Select(c => c.Value).ToArray();
        return ids.Length == 1 && !string.IsNullOrWhiteSpace(ids[0]) ? ids[0] : null;
    }
}

public static class ResellerEndpoints
{
    public static IEndpointRouteBuilder MapResellerEndpoints(this IEndpointRouteBuilder app, bool sessionMode)
    {
        app.MapGet("/api/reseller/accounts", async (HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            // Basic lab admin credentials never provide an owner identity.
            var owner = sessionMode && ctx.Request.IsHttps ? ResellerScope.OwnerId(ctx.User) : null;
            if (owner is null) return Results.StatusCode(403);
            var rows = new List<object>();
            await using var cmd = db.CreateCommand("""
                SELECT a.username, p.name, a.active, a.created_at, a.disabled_at
                FROM app_lab_account_owners o
                JOIN app_lab_accounts a ON a.username=o.username
                JOIN app_plans p ON p.id=a.plan_id
                WHERE o.owner_user_id=@owner
                ORDER BY a.created_at DESC, a.username ASC LIMIT 101
                """);
            cmd.Parameters.AddWithValue("owner", owner);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            var hasMore = false;
            while (await reader.ReadAsync(ct))
            {
                if (rows.Count == 100) { hasMore = true; break; }
                rows.Add(new {
                    username = reader.GetString(0), planName = reader.GetString(1),
                    active = reader.GetBoolean(2), createdAt = reader.GetDateTime(3),
                    disabledAt = reader.IsDBNull(4) ? (DateTime?)null : reader.GetDateTime(4)
                });
            }
            return Results.Ok(new { accounts = rows, hasMore, limit = 100, labOnly = true });
        }).RequireRateLimiting("admin");
        return app;
    }
}
