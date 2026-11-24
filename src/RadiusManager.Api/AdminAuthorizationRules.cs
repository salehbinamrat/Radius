using System.Security.Claims;

namespace RadiusManager.Api;

/// <summary>Deny-by-default server role policy for current LAB endpoints.</summary>
public static class AdminAuthorizationRules
{
    public static bool IsAllowed(ClaimsPrincipal user, string method, string? path)
    {
        if (user.Identity?.IsAuthenticated != true) return false;
        if (user.IsInRole("super-admin")) return true;
        if (path is null || !path.StartsWith("/api/", StringComparison.Ordinal)) return false;
        var isRead = method is "GET" or "HEAD";
        bool oneOf(params string[] paths) => paths.Contains(path, StringComparer.Ordinal);
        bool usageRead = path.StartsWith("/api/lab-accounts/", StringComparison.Ordinal)
            && path.EndsWith("/usage", StringComparison.Ordinal) && isRead;
        if (user.IsInRole("noc-operator"))
            return (isRead && oneOf("/api/summary", "/api/lab-sessions", "/api/nas-drafts", "/api/service-status/radius", "/api/service-status/history")) || usageRead;
        if (user.IsInRole("voucher-operator"))
            return (isRead && oneOf("/api/summary", "/api/plans", "/api/lab-accounts"))
                || (method == "POST" && oneOf("/api/plans", "/api/lab-accounts"))
                || (method == "PUT" && path.StartsWith("/api/plans/", StringComparison.Ordinal))
                || (method == "POST" && path.StartsWith("/api/lab-accounts/", StringComparison.Ordinal)
                    && path.EndsWith("/disable", StringComparison.Ordinal));
        if (user.IsInRole("auditor"))
            return (isRead && oneOf("/api/summary", "/api/lab-sessions", "/api/service-status/radius", "/api/service-status/history")) || usageRead;
        // Reseller cannot see other reseller rows before an ownership model is implemented.
        if (user.IsInRole("reseller")) return false;
        return false;
    }
}
