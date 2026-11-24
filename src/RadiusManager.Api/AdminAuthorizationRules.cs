using System.Security.Claims;

namespace RadiusManager.Api;

/// <summary>Deny-by-default server role policy for current LAB endpoints.</summary>
public static class AdminAuthorizationRules
{
    public static bool IsAllowed(ClaimsPrincipal user, string method, string? path)
    {
        if (path == "/api/reseller/accounts")
            return (method is "GET" or "HEAD") && ResellerScope.OwnerId(user) is not null;
        if (!CanAccessSharedLab(user)) return false;
        if (user.IsInRole("super-admin")) return true;
        if (path is null || !path.StartsWith("/api/", StringComparison.Ordinal)) return false;
        var isRead = method is "GET" or "HEAD";
        bool oneOf(params string[] paths) => paths.Contains(path, StringComparer.Ordinal);
        var segments = path.Split('/');
        bool labAccountAction(string action) => segments.Length == 5
            && segments[1] == "api" && segments[2] == "lab-accounts"
            && LabAccountRules.IsLabUsername(segments[3]) && segments[4] == action;
        bool planUpdate = segments.Length == 4 && segments[1] == "api" && segments[2] == "plans"
            && Guid.TryParseExact(segments[3], "D", out _);
        bool usageRead = isRead && labAccountAction("usage");
        if (user.IsInRole("noc-operator"))
            return (isRead && oneOf("/api/summary", "/api/lab-sessions", "/api/nas-drafts", "/api/service-status/radius", "/api/service-status/history", "/api/service-status/alerts", "/api/service-status/incidents")) || usageRead;
        if (user.IsInRole("voucher-operator"))
            return (isRead && oneOf("/api/summary", "/api/plans", "/api/lab-accounts"))
                || (method == "POST" && oneOf("/api/plans", "/api/lab-accounts"))
                || (method == "PUT" && planUpdate)
                || (method == "POST" && labAccountAction("disable"));
        if (user.IsInRole("auditor"))
            return (isRead && oneOf("/api/summary", "/api/lab-sessions", "/api/service-status/radius", "/api/service-status/history", "/api/service-status/alerts", "/api/service-status/incidents")) || usageRead;
        return false;
    }

    // Reseller ownership is separate. A reseller membership must not inherit shared
    // laboratory resources from another role, including via the monitoring hub.
    public static bool CanAccessSharedLab(ClaimsPrincipal? user) =>
        user?.Identity?.IsAuthenticated == true && !user.IsInRole("reseller");
}
