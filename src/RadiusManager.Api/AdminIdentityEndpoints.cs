using System.Security.Claims;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace RadiusManager.Api;

public sealed record AdminLoginRequest(string Username, string Password);
public sealed record AdminPasswordChangeRequest(string CurrentPassword, string NewPassword);

/// <summary>
/// Opt-in HTTPS-only administrative login, with server-side revocable sessions.
/// Existing laboratory Basic auth remains the DEFAULT until an HTTPS cutover is approved.
/// </summary>
public static class AdminIdentityEndpoints
{
    public static IEndpointRouteBuilder MapAdminIdentityEndpoints(this IEndpointRouteBuilder app, bool identityEnabled)
    {
        // Only a harmless mode label is public: no account, role or session data.
        // Never suggest Basic fallback over HTTP when server requires HTTPS.
        app.MapGet("/api/admin/auth/mode", (HttpContext ctx) =>
        {
            if (identityEnabled && !ctx.Request.IsHttps) return Results.StatusCode(403);
            return Results.Ok(new { mode = identityEnabled ? "session" : "basic" });
        });

        app.MapGet("/api/admin/auth/csrf", (HttpContext ctx, IAntiforgery csrf) =>
        {
            if (!identityEnabled) return Results.NotFound();
            if (!ctx.Request.IsHttps) return Results.StatusCode(403);
            var tokens = csrf.GetAndStoreTokens(ctx);
            return Results.Ok(new { requestToken = tokens.RequestToken });
        });

        app.MapPost("/api/admin/auth/login", async (
            HttpContext ctx, IAntiforgery csrf, AdminLoginRequest input,
            UserManager<IdentityUser> users, SignInManager<IdentityUser> signIn,
            AdminIdentityDbContext db) =>
        {
            if (!identityEnabled) return Results.NotFound();
            if (!ctx.Request.IsHttps || !await csrf.IsRequestValidAsync(ctx))
                return Results.StatusCode(403);
            if (string.IsNullOrWhiteSpace(input.Username) || input.Username.Length > 80
                || string.IsNullOrEmpty(input.Password))
                return Results.BadRequest(new { error = "بيانات الدخول غير صالحة" });

            var user = await users.FindByNameAsync(input.Username);
            var result = user is null
                ? SignInResult.Failed
                : await signIn.CheckPasswordSignInAsync(user, input.Password, lockoutOnFailure: true);
            if (!result.Succeeded || user is null)
            {
                db.AdminAuditEvents.Add(Audit("login_failure", null, "denied"));
                await db.SaveChangesAsync();
                return Results.Unauthorized();
            }

            string token = AdminSessionSecurity.NewToken();
            DateTime now = DateTime.UtcNow;
            db.AdminSessions.Add(new AdminSession
            {
                Id = Guid.NewGuid(),
                UserId = user.Id,
                SessionTokenHash = AdminSessionSecurity.HashToken(token),
                SecurityStamp = user.SecurityStamp ?? "",
                CreatedAt = now,
                LastSeenAt = now,
                IdleExpiresAt = now.AddMinutes(20),
                AbsoluteExpiresAt = now.AddHours(8),
            });
            db.AdminAuditEvents.Add(Audit("login_success", user.Id, "success"));
            await db.SaveChangesAsync();
            await signIn.SignInWithClaimsAsync(user, isPersistent: false,
                new[] { new Claim("radius-session", token) });
            return Results.Ok(new { authenticated = true, expiresAfterIdleMinutes = 20 });
        }).RequireRateLimiting("admin");

        app.MapGet("/api/admin/auth/me", async (
            HttpContext ctx, UserManager<IdentityUser> users) =>
        {
            if (!identityEnabled) return Results.NotFound();
            if (!ctx.Request.IsHttps) return Results.StatusCode(403);
            if (ctx.User.Identity?.IsAuthenticated != true) return Results.Unauthorized();
            var user = await users.GetUserAsync(ctx.User);
            if (user is null) return Results.Unauthorized();
            var roles = await users.GetRolesAsync(user);
            return Results.Ok(new { authenticated = true, username = user.UserName, roles });
        });

        app.MapPost("/api/admin/auth/logout", async (
            HttpContext ctx, IAntiforgery csrf,
            SignInManager<IdentityUser> signIn, AdminIdentityDbContext db) =>
        {
            if (!identityEnabled) return Results.NotFound();
            if (!ctx.Request.IsHttps || !await csrf.IsRequestValidAsync(ctx))
                return Results.StatusCode(403);
            if (ctx.User.Identity?.IsAuthenticated != true) return Results.Unauthorized();
            string? token = ctx.User.FindFirst("radius-session")?.Value;
            string? uid = ctx.User.FindFirst(ClaimTypes.NameIdentifier)?.Value;
            if (!string.IsNullOrEmpty(token))
            {
                var hash = AdminSessionSecurity.HashToken(token);
                var session = await db.AdminSessions.SingleOrDefaultAsync(s => s.SessionTokenHash == hash);
                if (session is not null)
                    session.RevokedAt = DateTime.UtcNow;
            }
            db.AdminAuditEvents.Add(Audit("logout", uid, "success"));
            await db.SaveChangesAsync();
            await signIn.SignOutAsync();
            return Results.Ok(new { authenticated = false });
        });

        app.MapPost("/api/admin/auth/change-password", async (
            HttpContext ctx, IAntiforgery csrf, AdminPasswordChangeRequest input,
            UserManager<IdentityUser> users, SignInManager<IdentityUser> signIn,
            AdminIdentityDbContext db) =>
        {
            if (!identityEnabled) return Results.NotFound();
            if (!ctx.Request.IsHttps || !await csrf.IsRequestValidAsync(ctx))
                return Results.StatusCode(403);
            if (ctx.User.Identity?.IsAuthenticated != true) return Results.Unauthorized();
            var user = await users.GetUserAsync(ctx.User);
            if (user is null) return Results.Unauthorized();
            if (string.IsNullOrEmpty(input.CurrentPassword) || string.IsNullOrEmpty(input.NewPassword))
                return Results.BadRequest(new { error = "أدخل كلمة المرور الحالية والجديدة" });
            var changed = await users.ChangePasswordAsync(user, input.CurrentPassword, input.NewPassword);
            if (!changed.Succeeded)
            {
                db.AdminAuditEvents.Add(Audit("password_change_rejected", user.Id, "denied"));
                await db.SaveChangesAsync();
                return Results.BadRequest(new { error = "تعذر تغيير كلمة المرور وفقا للسياسة" });
            }
            // Reject every outstanding cookie by revoking sessions and rotating Identity stamp.
            await db.AdminSessions.Where(s => s.UserId == user.Id && s.RevokedAt == null)
                .ExecuteUpdateAsync(s => s.SetProperty(x => x.RevokedAt, DateTime.UtcNow));
            db.AdminAuditEvents.Add(Audit("password_changed", user.Id, "success"));
            await db.SaveChangesAsync();
            await signIn.SignOutAsync();
            return Results.Ok(new { authenticated = false, sessionsRevoked = true });
        }).RequireRateLimiting("admin");

        return app;
    }

    private static AdminAuditEvent Audit(string action, string? actor, string outcome) => new()
    {
        ActorUserId = actor,
        Action = action,
        SubjectKind = "admin",
        SubjectId = actor,
        Outcome = outcome,
        OccurredAt = DateTime.UtcNow,
        CorrelationId = Guid.NewGuid()
    };
}
