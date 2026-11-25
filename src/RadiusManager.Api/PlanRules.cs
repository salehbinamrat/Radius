namespace RadiusManager.Api;

public sealed record PlanInput(string Name, int DownloadKbps, int UploadKbps, long? QuotaMb, int? ValidityDays);

public static class PlanRules
{
    public static string? Validate(PlanInput? input)
    {
        if (input is null) return "البيانات غير صالحة";
        if (string.IsNullOrWhiteSpace(input.Name) || input.Name.Trim().Length > 80)
            return "اسم الباقة يجب أن يكون بين 1 و80 حرفا";
        // PostgreSQL text cannot contain NUL; embedded control characters also
        // corrupt display/export semantics. Validate the same trimmed value we store.
        if (input.Name.Trim().Any(char.IsControl))
            return "اسم الباقة يحتوي على محارف تحكم غير صالحة";
        if (input.DownloadKbps is < 64 or > 1000000 || input.UploadKbps is < 64 or > 1000000)
            return "السرعة يجب أن تكون بين 64 و1000000 كيلوبت/ثانية";
        if (input.QuotaMb is <= 0 or > 100000000)
            return "الحد الأقصى للبيانات غير صالح";
        if (input.ValidityDays is <= 0 or > 3650)
            return "مدة الصلاحية غير صالحة";
        return null;
    }

    public static string GroupName(Guid id) => "plan-" + id.ToString("N");

    // MikroTik RADIUS syntax: upload/download; all values are kilobits/s.
    public static string MikroTikRate(int uploadKbps, int downloadKbps) =>
        FormattableString.Invariant($"{uploadKbps}k/{downloadKbps}k");

    public static long? QuotaBytes(long? quotaMb) => checked(quotaMb * 1024L * 1024L);
}
