using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace RadiusManager.Api;

public static class AdminBasicAuth
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static bool Matches(string? value, string expectedUser, string expectedPassword)
    {
        if (string.IsNullOrEmpty(value) || !AuthenticationHeaderValue.TryParse(value, out var header)
            || !string.Equals(header.Scheme, "Basic", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrEmpty(header.Parameter)) return false;

        byte[]? supplied = null;
        byte[]? user = null;
        byte[]? password = null;
        try
        {
            supplied = Convert.FromBase64String(header.Parameter);
            var separator = Array.IndexOf(supplied, (byte)':');
            if (separator < 1) return false;

            // Compare the wire bytes without replacement decoding. Invalid UTF-8
            // cannot equal the strict UTF-8 encoding of a configured credential.
            user = StrictUtf8.GetBytes(expectedUser);
            password = StrictUtf8.GetBytes(expectedPassword);
            // Evaluate both comparisons even when the user name does not match.
            return CryptographicOperations.FixedTimeEquals(supplied.AsSpan(0, separator), user)
                & CryptographicOperations.FixedTimeEquals(supplied.AsSpan(separator + 1), password);
        }
        catch (FormatException) { return false; }
        catch (EncoderFallbackException) { return false; }
        finally
        {
            if (supplied is not null) CryptographicOperations.ZeroMemory(supplied);
            if (user is not null) CryptographicOperations.ZeroMemory(user);
            if (password is not null) CryptographicOperations.ZeroMemory(password);
        }
    }
}
