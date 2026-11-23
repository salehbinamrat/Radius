using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class RequestOriginRulesTests
{
    [Theory]
    [InlineData("POST", "https://malicious.example", null)]
    [InlineData("POST", "null", null)]
    [InlineData("POST", "http://127.0.0.1:8081", null)]
    [InlineData("POST", "https://127.0.0.1:8080", null)]
    [InlineData("PUT", "http://127.0.0.1:8080.evil.example", null)]
    [InlineData("POST", "http://127.0.0.1:8080/path", null)]
    [InlineData("POST", "http://127.0.0.1:8080", "cross-site")]
    [InlineData("POST", "http://127.0.0.1:8080", "same-site")]
    [InlineData("POST", null, "cross-site")]
    [InlineData("DELETE", null, "same-site")]
    public void RejectsCrossOriginOrUntrustedBrowserWrite(string method, string? origin, string? fetchSite)
    {
        Assert.False(RequestOriginRules.IsAllowed(method, origin, fetchSite, "http", "127.0.0.1:8080"));
    }

    [Theory]
    [InlineData("POST", "http://127.0.0.1:8080", "same-origin")]
    [InlineData("PUT", "http://127.0.0.1:8080", null)]
    [InlineData("POST", null, null)]
    [InlineData("POST", null, "none")]
    [InlineData("GET", "https://malicious.example", "cross-site")]
    [InlineData("HEAD", "null", "cross-site")]
    [InlineData("OPTIONS", "https://malicious.example", "cross-site")]
    public void AllowsSameOriginAndExistingNonBrowserClients(string method, string? origin, string? fetchSite)
    {
        Assert.True(RequestOriginRules.IsAllowed(method, origin, fetchSite, "http", "127.0.0.1:8080"));
    }
}
