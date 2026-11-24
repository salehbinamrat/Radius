using System.Security.Claims;
using Npgsql;

namespace RadiusManager.Api;

public enum DenialReason { Role, Csrf }

/// <summary>Bounded metadata for rejected, known laboratory writes by authenticated HTTPS actors.</summary>
public static class DeniedMutationAudit
{
    public static string? Operation(string method, string? path)
    {
        if (path is null) return null;
        if (method == "POST")
        {
            if (path == "/api/plans") return "plan_created";
            if (path == "/api/lab-accounts") return "voucher_created";
            if (path == "/api/nas-drafts") return "nas_draft_created";
        }
        var p = path.Split('/');
        if (p.Length == 4 && p[0] == "" && p[1] == "api" && p[2] == "plans"
            && method == "PUT" && Guid.TryParseExact(p[3], "D", out _)) return "plan_updated";
        if (method != "POST") return null;
        if (p.Length == 5 && p[0] == "" && p[1] == "api")
        {
            if (p[2] == "lab-accounts" && LabAccountRules.IsLabUsername(p[3]) && p[4] == "disable")
                return "voucher_disabled";
            if (p[2] == "nas-drafts" && Guid.TryParseExact(p[3], "D", out _) && p[4] == "retire")
                return "nas_draft_retired";
        }
        if (p.Length == 6 && p[0] == "" && p[1] == "api" && p[2] == "ownership"
            && p[3] == "accounts" && LabAccountRules.IsLabUsername(p[4]))
            return p[5] switch { "assign" => "voucher_owner_assigned", "transfer" => "voucher_owner_transferred", _ => null };
        return null;
    }

    public static string? ActorId(ClaimsPrincipal user)
    {
        if (user.Identity?.IsAuthenticated != true) return null;
        var ids = user.FindAll(ClaimTypes.NameIdentifier).Select(c => c.Value).ToArray();
        return ids.Length == 1 && OwnershipRules.ValidOwnerId(ids[0]) ? ids[0] : null;
    }

    public static async Task RecordAsync(HttpContext ctx, DenialReason reason)
    {
        // Called only from the session-mode middleware, after authentication and
        // the rate limiter. Do not create records for anonymous or arbitrary URLs.
        var operation = Operation(ctx.Request.Method, ctx.Request.Path.Value);
        var actor = ActorId(ctx.User);
        if (!ctx.Request.IsHttps || operation is null || actor is null) return;
        var action = reason switch
        {
            DenialReason.Role => "authorization_denied",
            DenialReason.Csrf => "csrf_denied",
            _ => throw new ArgumentOutOfRangeException(nameof(reason))
        };
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
            deadline.CancelAfter(TimeSpan.FromSeconds(2));
            var db = ctx.RequestServices.GetRequiredService<NpgsqlDataSource>();
            await using var cmd = db.CreateCommand("""
                INSERT INTO app_admin_audit_events(actor_user_id,action,subject_kind,subject_id,outcome,correlation_id)
                VALUES (@actor,@action,'operation',@operation,'denied',@correlation)
                """);
            cmd.CommandTimeout = 2;
            cmd.Parameters.AddWithValue("actor", actor);
            cmd.Parameters.AddWithValue("action", action);
            cmd.Parameters.AddWithValue("operation", operation);
            cmd.Parameters.AddWithValue("correlation", Guid.NewGuid());
            await cmd.ExecuteNonQueryAsync(deadline.Token);
        }
        catch (Exception ex) when (ex is NpgsqlException or TimeoutException or OperationCanceledException)
        {
            // A recording failure must NEVER turn a denied write into an allowed one.
            // No raw URL, identifiers, exception details, headers or payload in logs.
            ctx.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("DeniedMutationAudit")
                .LogWarning("Administrative denial audit could not be recorded.");
        }
    }
}
