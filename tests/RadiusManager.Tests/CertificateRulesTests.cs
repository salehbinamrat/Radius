using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class CertificateRulesTests
{
    private static X509Certificate2 Make(RSA key, DateTimeOffset now, X509KeyUsageFlags usage,
        int startDays=-1, int endDays=1)
    {
        var request=new CertificateRequest("CN=fixture",key,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(usage,true));
        return request.CreateSelfSigned(now.AddDays(startDays),now.AddDays(endDays));
    }
    [Fact]
    public void SeparateKeysAcceptedAndSharedKeyRejected()
    {
        var now=DateTimeOffset.UtcNow;
        using var first=RSA.Create(2048);
        using var second=RSA.Create(2048);
        using var tls=Make(first,now,X509KeyUsageFlags.DigitalSignature);
        using var dp=Make(second,now,X509KeyUsageFlags.KeyEncipherment);
        CertificateRules.ValidatePair(tls,dp,now);
        using var reused=Make(first,now,X509KeyUsageFlags.KeyEncipherment);
        Assert.Throws<InvalidOperationException>(()=>CertificateRules.ValidatePair(tls,reused,now));
    }
    [Fact]
    public void InvalidDatesUsageAndMissingPrivateKeyRejected()
    {
        var now=DateTimeOffset.UtcNow;
        using var first=RSA.Create(2048);
        using var second=RSA.Create(2048);
        using var tls=Make(first,now,X509KeyUsageFlags.DigitalSignature);
        using var expired=Make(second,now,X509KeyUsageFlags.KeyEncipherment,-3,-2);
        using var future=Make(second,now,X509KeyUsageFlags.KeyEncipherment,2,3);
        using var wrong=Make(second,now,X509KeyUsageFlags.DigitalSignature);
        using var valid=Make(second,now,X509KeyUsageFlags.KeyEncipherment);
        using var publicOnly=X509CertificateLoader.LoadCertificate(valid.Export(X509ContentType.Cert));
        foreach(var cert in new[]{expired,future,wrong,publicOnly})
            Assert.Throws<InvalidOperationException>(()=>CertificateRules.ValidatePair(tls,cert,now));
    }
}
