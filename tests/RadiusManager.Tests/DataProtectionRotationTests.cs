using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.DataProtection.KeyManagement;
using Microsoft.Extensions.DependencyInjection;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class DataProtectionRotationTests
{
    private static X509Certificate2 Make(RSA key, DateTimeOffset now, int start=-1, int end=30)
    {
        var req=new CertificateRequest("CN=fixture",key,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment,true));
        return req.CreateSelfSigned(now.AddDays(start),now.AddDays(end));
    }
    private static ServiceProvider Provider(string dir,X509Certificate2 current,X509Certificate2? previous=null)
    {
        var services=new ServiceCollection();
        services.AddLogging();
        var dp=services.AddDataProtection().SetApplicationName("RadiusNocAdminSessions")
            .PersistKeysToFileSystem(new DirectoryInfo(dir)).ProtectKeysWithCertificate(current)
            .DisableAutomaticKeyGeneration();
        if(previous is not null) dp.UnprotectKeysWithAnyCertificate(current,previous);
        return services.BuildServiceProvider();
    }

    [Fact]
    public void RotationDecryptsHistoricalKeysAndEncryptsNewKeysWithCurrentCertificate()
    {
        var dir=Directory.CreateTempSubdirectory().FullName;
        var now=DateTimeOffset.UtcNow;
        using var oldRsa=RSA.Create(2048);
        using var newRsa=RSA.Create(2048);
        using var tlsRsa=RSA.Create(2048);
        using var oldCert=Make(oldRsa,now);
        using var newCert=Make(newRsa,now);
        using var tls=Make(tlsRsa,now);
        CertificateRules.ValidatePrevious(tls,newCert,oldCert,now);
        try
        {
            string historical;
            Guid oldId;
            using(var old=Provider(dir,oldCert))
            {
                oldId=old.GetRequiredService<IKeyManager>().CreateNewKey(now.AddMinutes(-10),now.AddDays(10)).KeyId;
                historical=old.GetRequiredService<IDataProtectionProvider>().CreateProtector("rotation-test").Protect("historical");
            }
            string latest;
            Guid newId;
            using(var rotated=Provider(dir,newCert,oldCert))
            {
                newId=rotated.GetRequiredService<IKeyManager>().CreateNewKey(now.AddMinutes(-1),now.AddDays(20)).KeyId;
                var protector=rotated.GetRequiredService<IDataProtectionProvider>().CreateProtector("rotation-test");
                Assert.Equal("historical",protector.Unprotect(historical));
                latest=protector.Protect("current");
            }
            Assert.NotEqual(oldId,newId);
            using(var onlyNew=Provider(dir,newCert))
            {
                var protector=onlyNew.GetRequiredService<IDataProtectionProvider>().CreateProtector("rotation-test");
                Assert.Equal("current",protector.Unprotect(latest));
                Assert.ThrowsAny<CryptographicException>(()=>protector.Unprotect(historical));
            }
            using(var both=Provider(dir,newCert,oldCert))
                Assert.Equal("historical",both.GetRequiredService<IDataProtectionProvider>().CreateProtector("rotation-test").Unprotect(historical));
        }
        finally { Directory.Delete(dir,true); }
    }

    [Fact]
    public void HistoricalCertificateMayBeExpiredButMustUseIndependentPrivateKey()
    {
        var now=DateTimeOffset.UtcNow;
        using var a=RSA.Create(2048);
        using var b=RSA.Create(2048);
        using var c=RSA.Create(2048);
        using var tls=Make(a,now);
        using var current=Make(b,now);
        using var expired=Make(c,now,-10,-1);
        using var future=Make(c,now,1,2);
        using var publicOnly=X509CertificateLoader.LoadCertificate(expired.Export(X509ContentType.Cert));
        CertificateRules.ValidatePrevious(tls,current,expired,now);
        foreach(var invalid in new[]{tls,current,future,publicOnly})
            Assert.Throws<InvalidOperationException>(()=>CertificateRules.ValidatePrevious(tls,current,invalid,now));
    }
}
