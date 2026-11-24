using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace RadiusManager.Api;

public static class CertificateRules
{
    public static void ValidatePrevious(X509Certificate2 tls, X509Certificate2 current,
        X509Certificate2 previous, DateTimeOffset now)
    {
        using var oldKey = previous.GetRSAPublicKey();
        using var tlsKey = tls.GetRSAPublicKey();
        using var currentKey = current.GetRSAPublicKey();
        if (!previous.HasPrivateKey || oldKey is null || oldKey.KeySize < 2048
            || tlsKey is null || currentKey is null)
            throw new InvalidOperationException("Previous Data Protection certificate requires a suitable RSA private key");
        var oldPublicKey = oldKey.ExportSubjectPublicKeyInfo();
        if (oldPublicKey.AsSpan().SequenceEqual(tlsKey.ExportSubjectPublicKeyInfo())
            || oldPublicKey.AsSpan().SequenceEqual(currentKey.ExportSubjectPublicKeyInfo()))
            throw new InvalidOperationException("Previous Data Protection key must differ from current TLS and protection keys");
        // Expired historical certificates are permitted for decryption only.
        // Legacy TLS-protected rings may have no encipherment extension.
        if (now < new DateTimeOffset(previous.NotBefore.ToUniversalTime()))
            throw new InvalidOperationException("Previous Data Protection certificate is not yet valid");
    }

    // Local key suitability only; clients must verify TLS trust and hostname.
    public static void ValidatePair(X509Certificate2 tls, X509Certificate2 protection, DateTimeOffset now)
    {
        using var tlsKey = tls.GetRSAPublicKey();
        using var protectionKey = protection.GetRSAPublicKey();
        if (!tls.HasPrivateKey || !protection.HasPrivateKey
            || tlsKey is null || protectionKey is null
            || tlsKey.KeySize < 2048 || protectionKey.KeySize < 2048)
            throw new InvalidOperationException("TLS and Data Protection require RSA private keys of at least 2048 bits");
        if (tlsKey.ExportSubjectPublicKeyInfo().AsSpan().SequenceEqual(protectionKey.ExportSubjectPublicKeyInfo()))
            throw new InvalidOperationException("TLS and Data Protection must use distinct keys");
        foreach (var certificate in new[] { tls, protection })
            if (now < new DateTimeOffset(certificate.NotBefore.ToUniversalTime()) || now >= new DateTimeOffset(certificate.NotAfter.ToUniversalTime()))
                throw new InvalidOperationException("Configured certificate is outside its validity period");
        var usage = protection.Extensions.OfType<X509KeyUsageExtension>().SingleOrDefault();
        if (usage is null || !usage.KeyUsages.HasFlag(X509KeyUsageFlags.KeyEncipherment))
            throw new InvalidOperationException("Data Protection certificate must permit key encipherment");
    }
}
