using System.Text;
using Npgsql;

namespace RadiusManager.Api;

/// <summary>Read one bounded local secret; never include its value or path in diagnostics.</summary>
public static class SecretInput
{
    private const int MaxBytes = 4096;

    public static string? Resolve(string label, string? inline, string? file)
    {
        if (file is null) return inline;
        if (!string.IsNullOrEmpty(inline))
            throw new InvalidOperationException($"{label}: configure only one secret source.");
        if (string.IsNullOrWhiteSpace(file) || !Path.IsPathFullyQualified(file))
            throw new InvalidOperationException($"{label}: secret file must have an absolute path.");
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length is < 1 or > MaxBytes)
                throw new InvalidDataException();
            var buffer = new byte[MaxBytes + 1];
            try
            {
                var count = stream.ReadAtLeast(buffer, buffer.Length, false);
                if (count is < 1 or > MaxBytes) throw new InvalidDataException();
                var value = new UTF8Encoding(false, true).GetString(buffer, 0, count);
                // Permit one conventional line terminator only, never trim password spaces.
                if (value.EndsWith("\r\n", StringComparison.Ordinal)) value = value[..^2];
                else if (value.EndsWith('\n')) value = value[..^1];
                if (string.IsNullOrWhiteSpace(value) || value.Any(char.IsControl) || value.Contains('\uFEFF'))
                    throw new InvalidDataException();
                return value;
            }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer); }
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException
            or ArgumentException or NotSupportedException)
        {
            throw new InvalidOperationException($"{label}: secret file is missing, unreadable or invalid.");
        }
    }

    public static string DatabaseConnection(string? configuration, string? passwordFile)
    {
        if (string.IsNullOrWhiteSpace(configuration))
            throw new InvalidOperationException("Provide a database connection string.");
        if (passwordFile is null) return configuration;
        NpgsqlConnectionStringBuilder parsed;
        try { parsed = new NpgsqlConnectionStringBuilder(configuration); }
        catch (ArgumentException) { throw new InvalidOperationException("Invalid database connection configuration."); }
        // Reject alternate password sources, including libpq environment fallback.
        if (parsed.ContainsKey("Password") && !string.IsNullOrEmpty(parsed.Password)
            || !string.IsNullOrEmpty(parsed.Passfile)
            || !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PGPASSWORD"))
            || !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PGPASSFILE")))
            throw new InvalidOperationException("Database password: configure only one secret source.");
        parsed.Password = Resolve("Database password", null, passwordFile);
        return parsed.ConnectionString;
    }
}
