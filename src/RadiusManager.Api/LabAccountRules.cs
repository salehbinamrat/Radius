using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace RadiusManager.Api;

public sealed record CreateLabAccountInput(Guid PlanId);

public static partial class LabAccountRules
{
    [GeneratedRegex("^lab_[a-f0-9]{12}$", RegexOptions.CultureInvariant)]
    private static partial Regex LabUsernamePattern();

    public static string GenerateUsername() =>
        "lab_" + Convert.ToHexString(RandomNumberGenerator.GetBytes(6)).ToLowerInvariant();

    // A random secret is returned once; the SQL RADIUS module requires a
    // retrievable password for PAP and CHAP. It must never enter application logs.
    public static string GeneratePassword() =>
        Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();

    public static bool IsLabUsername(string? value) =>
        value is { Length: 16 } && LabUsernamePattern().IsMatch(value);

    // Prevent test accounts attached to unenforced quota or expiry metadata.
    public static bool PlanIsSafeForLab(long? quotaBytes, int? validityDays) =>
        quotaBytes is null && validityDays is null;
}
