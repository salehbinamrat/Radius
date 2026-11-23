namespace RadiusManager.Api;

/// <summary>
/// Narrow browser-origin guard for state-changing laboratory API requests.
/// Basic authentication alone does not prevent cross-site form POSTs when
/// a browser has cached the credentials. Non-browser clients without Origin
/// or Sec-Fetch-Site continue to work as before.
/// </summary>
public static class RequestOriginRules
{
    public static bool IsAllowed(
        string method, string? origin, string? fetchSite, string requestScheme, string requestHost)
    {
        if (string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase)
            || string.Equals(method, "HEAD", StringComparison.OrdinalIgnoreCase)
            || string.Equals(method, "OPTIONS", StringComparison.OrdinalIgnoreCase))
            return true;

        if (!string.IsNullOrEmpty(fetchSite)
            && !string.Equals(fetchSite, "same-origin", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(fetchSite, "none", StringComparison.OrdinalIgnoreCase))
            return false;

        // CLI and integration clients do not necessarily send browser headers.
        if (string.IsNullOrEmpty(origin)) return true;
        if (origin != origin.Trim()
            || !Uri.TryCreate(origin, UriKind.Absolute, out var supplied)
            || (supplied.Scheme != Uri.UriSchemeHttp && supplied.Scheme != Uri.UriSchemeHttps)
            || supplied.AbsolutePath != "/"
            || supplied.Query.Length != 0 || supplied.Fragment.Length != 0
            || supplied.UserInfo.Length != 0
            || !Uri.TryCreate($"{requestScheme}://{requestHost}", UriKind.Absolute, out var expected))
            return false;

        return string.Equals(
            supplied.GetLeftPart(UriPartial.Authority),
            expected.GetLeftPart(UriPartial.Authority),
            StringComparison.OrdinalIgnoreCase);
    }
}
