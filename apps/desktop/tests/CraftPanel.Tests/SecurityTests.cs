using System.Text;
using CraftPanel.Core;
using CraftPanel.Core.Network;
using CraftPanel.Core.Security;
using Xunit;

namespace CraftPanel.Tests;

public class SecurityTests
{
    static byte[] Hex(string h) => Convert.FromHexString(h);

    [Fact]
    public void Blake2bMatchesKnownVectors()
    {
        Assert.Equal("786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
            Convert.ToHexStringLower(Blake2b.Hash([], 64)));
        Assert.Equal("ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
            Convert.ToHexStringLower(Blake2b.Hash(Encoding.ASCII.GetBytes("abc"), 64)));
    }

    [Fact]
    public void Argon2idMatchesRfc9106Vector()
    {
        var tag = Argon2.Hash(Enumerable.Repeat((byte)1, 32).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray(), 32, 3, 4, 32,
            Enumerable.Repeat((byte)3, 8).ToArray(), Enumerable.Repeat((byte)4, 12).ToArray());
        Assert.Equal("0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659", Convert.ToHexStringLower(tag));
    }

    [Fact]
    public void PhcRoundTripAndRejections()
    {
        var phc = Argon2.Encode("correct horse", 1024, 2, 1);
        Assert.StartsWith("$argon2id$v=19$m=1024,t=2,p=1$", phc);
        Assert.True(Argon2.Verify("correct horse", phc));
        Assert.False(Argon2.Verify("wrong", phc));
        Assert.False(Argon2.Verify("x", "$argon2i$v=19$m=1024,t=2,p=1$AAAA$AAAA"));
        Assert.False(Argon2.Verify("x", "garbage"));
        Assert.False(Argon2.Verify("x", "$argon2id$v=19$m=99999999,t=2,p=1$AAAA$AAAA"));   // absurd memory cost refused
    }

    [Fact]
    public void AppLockSetVerifyClear()
    {
        using var t = new TempDir(); var lk = new AppLock(Path.Combine(t.Path, "lock.json"));
        Assert.False(lk.IsSet);
        Assert.Throws<ProvisionException>(() => lk.Set("12"));
        lk.Set("hunter22");
        Assert.True(lk.IsSet); Assert.True(lk.Verify("hunter22")); Assert.False(lk.Verify("hunter23"));
        Assert.DoesNotContain("hunter22", File.ReadAllText(Path.Combine(t.Path, "lock.json")));
        lk.Clear(); Assert.False(lk.IsSet);
    }

    [Fact]
    public void SecretStoreRoundTripsOffWindows()
    {
        using var t = new TempDir();
        var prevData = AppPaths.DataOverride; AppPaths.DataOverride = t.Path;
        try
        {
            SecretStore.Set("test.secret", "s3cret");
            Assert.Equal("s3cret", SecretStore.Get("test.secret"));
            SecretStore.Set("test.secret", null);
            Assert.Null(SecretStore.Get("test.secret"));
        }
        finally { AppPaths.DataOverride = prevData; }
    }
}

public class UpnpTests
{
    [Fact]
    public void ParsesSsdpAndDescription()
    {
        Assert.Equal("http://192.168.1.1:5000/rootDesc.xml", UPnP.ParseSsdpLocation("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLOCATION: http://192.168.1.1:5000/rootDesc.xml\r\nST: x\r\n\r\n"));
        Assert.Null(UPnP.ParseSsdpLocation("HTTP/1.1 200 OK\r\nLOCATION: ftp://evil\r\n\r\n"));
        const string xml = """
            <root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device><deviceList><device><serviceList>
              <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL></service>
            </serviceList></device></deviceList></device></deviceList></device></root>
            """;
        var gw = UPnP.ParseDescription(xml, new Uri("http://192.168.1.1:5000/rootDesc.xml"))!;
        Assert.Equal("http://192.168.1.1:5000/ctl/IPConn", gw.ControlUrl.ToString());
        Assert.Equal("urn:schemas-upnp-org:service:WANIPConnection:1", gw.ServiceType);
        Assert.Null(UPnP.ParseDescription("<nope", new Uri("http://x/")));
    }

    [Fact]
    public void EnvelopeEscapesValues()
    {
        var e = UPnP.Envelope("AddPortMapping", "urn:x", [("NewPortMappingDescription", "a<b>&c")]);
        Assert.Contains("<NewPortMappingDescription>a&lt;b&gt;&amp;c</NewPortMappingDescription>", e);
        Assert.Contains("<u:AddPortMapping xmlns:u=\"urn:x\">", e);
    }
}

public class ModpackTests
{
    [Theory]
    [InlineData("mods/a.jar", true)] [InlineData("config/x/y.toml", true)]
    [InlineData("../evil", false)] [InlineData("/abs", false)] [InlineData("a//b", false)] [InlineData("a\\b", false)] [InlineData("", false)]
    public void SafeRelativePaths(string p, bool ok) => Assert.Equal(ok, CraftPanel.Core.Addons.Modpacks.SafeRelativePath(p));

    [Fact]
    public void OnlyAllowlistedHostsOverHttps()
    {
        Assert.NotNull(CraftPanel.Core.Addons.Modpacks.DownloadAllowed("https://cdn.modrinth.com/data/x/y.jar"));
        Assert.Null(CraftPanel.Core.Addons.Modpacks.DownloadAllowed("http://cdn.modrinth.com/x"));
        Assert.Null(CraftPanel.Core.Addons.Modpacks.DownloadAllowed("https://evil.example.com/x"));
    }

    [Fact]
    public void OverridesMergeSafely()
    {
        using var t = new TempDir(); var zipPath = Path.Combine(t.Path, "p.zip"); var dest = t.Sub("srv/x").Replace("/x", "");
        using (var z = System.IO.Compression.ZipFile.Open(zipPath, System.IO.Compression.ZipArchiveMode.Create))
        {
            void Add(string name, string body) { using var w = new StreamWriter(z.CreateEntry(name).Open()); w.Write(body); }
            Add("overrides/config/a.toml", "A"); Add("overrides/../evil.txt", "E"); Add("server-overrides/config/a.toml", "SERVER");
            var link = z.CreateEntry("overrides/link"); link.ExternalAttributes = unchecked((int)(0xA1FF << 16));
            using (var w = new StreamWriter(link.Open())) w.Write("/etc/passwd");
        }
        using var zip = System.IO.Compression.ZipFile.OpenRead(zipPath);
        CraftPanel.Core.Addons.Modpacks.MergeOverrides(zip, "overrides", dest);
        CraftPanel.Core.Addons.Modpacks.MergeOverrides(zip, "server-overrides", dest);
        Assert.Equal("SERVER", File.ReadAllText(Path.Combine(dest, "config/a.toml")));
        Assert.False(File.Exists(Path.Combine(dest, "..", "evil.txt")));
        Assert.False(File.Exists(Path.Combine(dest, "link")));
    }
}
