using System.Text;
using Npgsql;
using RadiusManager.Api;
using Xunit;

namespace RadiusManager.Tests;

public sealed class SecretInputTests
{
    [Theory]
    [InlineData("  password with spaces  ", "  password with spaces  ")]
    [InlineData("example-secret\n", "example-secret")]
    [InlineData("example-secret\r\n", "example-secret")]
    public void ReadsOneLineWithoutTrimming(string content, string expected)
    {
        var path=Path.GetTempFileName();
        try {
            File.WriteAllText(path,content,new UTF8Encoding(false));
            Assert.Equal(expected,SecretInput.Resolve("test",null,path));
            Assert.Throws<InvalidOperationException>(()=>SecretInput.Resolve("test","other",path));
        } finally { File.Delete(path); }
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("first\nsecond")]
    [InlineData("first\n\n")]
    [InlineData("secret\0")]
    [InlineData("\uFEFFsecret")]
    public void InvalidContentsFailClosed(string content)
    {
        var path=Path.GetTempFileName();
        try {
            File.WriteAllText(path,content,new UTF8Encoding(false));
            Assert.Throws<InvalidOperationException>(()=>SecretInput.Resolve("test",null,path));
        } finally { File.Delete(path); }
    }

    [Fact]
    public void RejectsMissingRelativeOversizedAndInvalidUtf8Files()
    {
        Assert.Throws<InvalidOperationException>(()=>SecretInput.Resolve("test",null,"relative"));
        var path=Path.GetTempFileName();
        try {
            File.WriteAllBytes(path,new byte[4097]);
            Assert.Throws<InvalidOperationException>(()=>SecretInput.Resolve("test",null,path));
            File.WriteAllBytes(path,[0xff,0xfe]);
            Assert.Throws<InvalidOperationException>(()=>SecretInput.Resolve("test",null,path));
        } finally { File.Delete(path); }
        Assert.Throws<InvalidOperationException>(()=>SecretInput.Resolve("test",null,path));
    }

    [Fact]
    public void DatabaseSecretIsEscapedAndConflictingConfigurationRejected()
    {
        var path=Path.GetTempFileName();
        try {
            File.WriteAllText(path,"test;password=\"quoted\"");
            const string config="Host=db;Database=radius;Username=radius";
            var result=new NpgsqlConnectionStringBuilder(SecretInput.DatabaseConnection(config,path));
            Assert.Equal("test;password=\"quoted\"",result.Password);
            Assert.Equal("db",result.Host);
            Assert.Throws<InvalidOperationException>(()=>SecretInput.DatabaseConnection(config+";Password=other",path));
            Assert.Throws<InvalidOperationException>(()=>SecretInput.DatabaseConnection(config+";Passfile=/tmp/other",path));
        } finally { File.Delete(path); }
    }
}
