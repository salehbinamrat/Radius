using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace RadiusManager.Api;

public static class AdminBasicAuth
{
    public static bool Matches(string? value, string expectedUser, string expectedPassword)
    {
        if (string.IsNullOrEmpty(value) || !AuthenticationHeaderValue.TryParse(value, out var header)
            || !string.Equals(header.Scheme, "Basic", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrEmpty(header.Parameter)) return false;
        string decoded;
        try { decoded = Encoding.UTF8.GetString(Convert.FromBase64String(header.Parameter)); }
        catch (FormatException) { return false; }
        var separator = decoded.IndexOf(':');
        if (separator < 1) return false;
        var user = decoded[..separator];
        var password = decoded[(separator + 1)..];
        var first = Encoding.UTF8.GetBytes(user);
        var second = Encoding.UTF8.GetBytes(expectedUser);
        var third = Encoding.UTF8.GetBytes(password);
        var fourth = Encoding.UTF8.GetBytes(expectedPassword);
        return CryptographicOperations.FixedTimeEquals(first, second)
            && CryptographicOperations.FixedTimeEquals(third, fourth);
    }
}
