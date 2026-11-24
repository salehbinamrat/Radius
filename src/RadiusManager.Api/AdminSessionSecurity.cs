using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace RadiusManager.Api;

/// <summary>Server-side validation on every request and stream sample, without refreshing stale cookie roles.</summary>
public static class AdminSessionSecurity
{
    public static string NewToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    public static string HashToken(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    public static bool RolesMatch(ClaimsPrincipal principal, IEnumerable<string> currentRoles)
    {
        if (principal.Identity is not ClaimsIdentity identity || !identity.IsAuthenticated) return false;
        var current = currentRoles.ToHashSet(StringComparer.Ordinal);
        var issued = principal.FindAll(identity.RoleClaimType).Select(c => c.Value).ToHashSet(StringComparer.Ordinal);
        return current.Count > 0 && current.SetEquals(issued);
    }

    public static async Task<AdminSession?> GetCurrentAsync(AdminIdentityDbContext db,
        ClaimsPrincipal? principal, DateTime now, CancellationToken ct)
    {
        var token = principal?.FindFirst("radius-session")?.Value;
        var uid = principal?.FindFirst(ClaimTypes.NameIdentifier)?.Value;
        if (principal?.Identity?.IsAuthenticated != true || string.IsNullOrEmpty(uid)
            || token is null || token.Length != 64 || token.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
            return null;
        var hash = HashToken(token);
        // One database read binds the session to the current user stamp and current role membership.
        var rows = await (from s in db.AdminSessions.AsNoTracking()
                          join u in db.Users.AsNoTracking() on s.UserId equals u.Id
                          join ur in db.UserRoles.AsNoTracking() on u.Id equals ur.UserId
                          join role in db.Roles.AsNoTracking() on ur.RoleId equals role.Id
                          where s.UserId == uid && s.SessionTokenHash == hash
                              && s.RevokedAt == null && s.IdleExpiresAt > now
                              && s.AbsoluteExpiresAt > now && u.SecurityStamp != null
                              && s.SecurityStamp == u.SecurityStamp
                          select new { Session = s, Role = role.Name }).ToListAsync(ct);
        if (rows.Count == 0 || !RolesMatch(principal, rows.Select(r => r.Role ?? "")))
        {
            // Persist invalidation so restoring a previous role does not revive this observed stale cookie.
            await db.AdminSessions.Where(s => s.UserId == uid && s.SessionTokenHash == hash && s.RevokedAt == null)
                .ExecuteUpdateAsync(s => s.SetProperty(x => x.RevokedAt, now), ct);
            return null;
        }
        return rows[0].Session;
    }

    public static async Task ValidateAsync(CookieValidatePrincipalContext context)
    {
        // The server registry validates the Identity security stamp and roles on every request.
        // Do not call periodic SecurityStampValidator principal regeneration: it can discard
        // the opaque radius-session claim or replace the role snapshot before comparison.
        var db = context.HttpContext.RequestServices.GetRequiredService<AdminIdentityDbContext>();
        var now = DateTime.UtcNow;
        var ct = context.HttpContext.RequestAborted;
        var session = await GetCurrentAsync(db, context.Principal, now, ct);
        if (session is null)
        {
            await RejectAsync(context);
            return;
        }
        if (now - session.LastSeenAt > TimeSpan.FromSeconds(30))
        {
            var idle = session.AbsoluteExpiresAt < now.AddMinutes(20) ? session.AbsoluteExpiresAt : now.AddMinutes(20);
            var changed = await db.AdminSessions.Where(s => s.Id == session.Id && s.RevokedAt == null
                && s.IdleExpiresAt > now && s.AbsoluteExpiresAt > now && s.LastSeenAt == session.LastSeenAt)
                .ExecuteUpdateAsync(s => s.SetProperty(x => x.LastSeenAt, now)
                    .SetProperty(x => x.IdleExpiresAt, idle), ct);
            if (changed == 0 && await GetCurrentAsync(db, context.Principal, DateTime.UtcNow, ct) is null)
                await RejectAsync(context);
        }
    }

    private static async Task RejectAsync(CookieValidatePrincipalContext context)
    {
        context.RejectPrincipal();
        await context.HttpContext.SignOutAsync(IdentityConstants.ApplicationScheme);
    }
}
