using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace RadiusManager.Api;

/// <summary>Cryptographically random opaque session handle; only its digest is stored in PostgreSQL.</summary>
public static class AdminSessionSecurity
{
    public static string NewToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    public static string HashToken(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    public static async Task ValidateAsync(CookieValidatePrincipalContext context)
    {
        // Preserve ASP.NET Core Identity's own security-stamp validation.
        await SecurityStampValidator.ValidatePrincipalAsync(context);
        if (context.Principal?.Identity?.IsAuthenticated != true) return;
        var claim = context.Principal.FindFirst("radius-session");
        var uid = context.Principal.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value;
        if (string.IsNullOrEmpty(claim?.Value) || string.IsNullOrEmpty(uid))
        {
            await RejectAsync(context);
            return;
        }
        var db = context.HttpContext.RequestServices.GetRequiredService<AdminIdentityDbContext>();
        var hash = HashToken(claim.Value);
        var session = await db.AdminSessions.SingleOrDefaultAsync(s => s.SessionTokenHash == hash);
        var now = DateTime.UtcNow;
        var stamp = await db.Users.Where(u => u.Id == uid).Select(u => u.SecurityStamp).SingleOrDefaultAsync();
        if (session == null || session.UserId != uid || session.RevokedAt != null
            || session.IdleExpiresAt <= now || session.AbsoluteExpiresAt <= now
            || string.IsNullOrEmpty(stamp) || session.SecurityStamp != stamp)
        {
            await RejectAsync(context);
            return;
        }
        // Keep writes bounded for routine dashboards; timeout remains 20 min idle / 8h absolute.
        if ((now - session.LastSeenAt) > TimeSpan.FromSeconds(30))
        {
            session.LastSeenAt = now;
            session.IdleExpiresAt = session.AbsoluteExpiresAt < now.AddMinutes(20)
                ? session.AbsoluteExpiresAt : now.AddMinutes(20);
            await db.SaveChangesAsync();
        }
    }

    private static async Task RejectAsync(CookieValidatePrincipalContext context)
    {
        context.RejectPrincipal();
        await context.HttpContext.SignOutAsync(IdentityConstants.ApplicationScheme);
    }
}
