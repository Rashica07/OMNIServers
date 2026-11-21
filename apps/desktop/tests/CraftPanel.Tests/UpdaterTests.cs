using Xunit;
using System.IO.Compression;
using System.Text.Json.Nodes;
using CraftPanel.Core;
using CraftPanel.Core.Updates;

namespace CraftPanel.Tests;

public class UpdaterTests
{
    static JsonNode Rel(string tag, bool draft = false, params string[] assets) => new JsonObject
    {
        ["tag_name"] = tag, ["draft"] = draft, ["prerelease"] = false, ["html_url"] = "https://github.com/x/y/releases/tag/" + tag, ["body"] = "line1\nline2",
        ["assets"] = new JsonArray(assets.Select(a => (JsonNode)new JsonObject { ["name"] = a, ["browser_download_url"] = "https://dl/" + a, ["size"] = 40_000_000 }).ToArray()),
    };

    [Fact]
    public void Versions_compare_across_tag_styles()
    {
        Assert.True(AppUpdater.ParseVersion("windows-v2.10.0").CompareTo(AppUpdater.ParseVersion("windows-v2.9.9")) > 0);
        Assert.Equal((2, 8, 2), AppUpdater.ParseVersion("v2.8.2-beta"));
        Assert.Equal((2, 8, 0), AppUpdater.ParseVersion("2.8"));
    }

    [Fact]
    public void Picks_the_newest_windows_release_and_the_zip_for_this_chip()
    {
        var rels = new JsonArray(
            Rel("swift-v9.0.0", false, "CraftPanel-9.0.0-AppleSilicon.dmg"),
            Rel("windows-v2.8.1", false, "CraftPanel-2.8.1-win-x64.zip"),
            Rel("windows-v2.8.3", false, "CraftPanel-2.8.3-win-x64.zip", "CraftPanel-2.8.3-win-arm64.zip"),
            Rel("windows-v2.9.0", true, "CraftPanel-2.9.0-win-x64.zip"));
        var x64 = AppUpdater.Pick(rels, "2.8.2", "win-x64");
        Assert.Equal("v2.8.3", x64.Latest);
        Assert.True(x64.Newer);
        Assert.EndsWith("CraftPanel-2.8.3-win-x64.zip", x64.ZipUrl);
        Assert.EndsWith("win-arm64.zip", AppUpdater.Pick(rels, "2.8.2", "win-arm64").ZipUrl);
        Assert.False(AppUpdater.Pick(rels, "2.8.3", "win-x64").Newer);
        Assert.NotNull(AppUpdater.Pick(new JsonArray(Rel("swift-v1.0.0")), "2.8.2", "win-x64").Unavailable);
    }

    static string MakeZip(string dir, byte[] exe, string entry = "CraftPanel.exe")
    {
        var zip = Path.Combine(dir, "u.zip");
        using var z = ZipFile.Open(zip, ZipArchiveMode.Create);
        using var s = z.CreateEntry(entry).Open(); s.Write(exe);
        return zip;
    }

    [Fact]
    public void Extract_accepts_a_real_looking_exe_and_rejects_junk()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var good = new byte[6_000_000]; good[0] = (byte)'M'; good[1] = (byte)'Z';
            var dest = Path.Combine(dir, "new.exe");
            AppUpdater.ExtractExe(MakeZip(dir, good), dest);
            Assert.Equal(6_000_000, new FileInfo(dest).Length);

            File.Delete(Path.Combine(dir, "u.zip"));
            var html = new byte[6_000_000];   // an error page saved as a zip entry is not a program
            Assert.Throws<ProvisionException>(() => AppUpdater.ExtractExe(MakeZip(dir, html), Path.Combine(dir, "bad.exe")));
            Assert.False(File.Exists(Path.Combine(dir, "bad.exe")));

            File.Delete(Path.Combine(dir, "u.zip"));
            Assert.Throws<ProvisionException>(() => AppUpdater.ExtractExe(MakeZip(dir, good, "other.exe"), Path.Combine(dir, "x.exe")));
            File.Delete(Path.Combine(dir, "u.zip"));
            Assert.Throws<ProvisionException>(() => AppUpdater.ExtractExe(MakeZip(dir, [(byte)'M', (byte)'Z']), Path.Combine(dir, "y.exe")));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Swap_keeps_the_old_copy_aside_and_undoes_itself_on_failure()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var exe = Path.Combine(dir, "CraftPanel.exe");
            File.WriteAllText(exe, "old");
            File.WriteAllText(AppUpdater.StagedPath(exe), "new");
            AppUpdater.Swap(exe, AppUpdater.StagedPath(exe));
            Assert.Equal("new", File.ReadAllText(exe));
            Assert.Equal("old", File.ReadAllText(AppUpdater.OldPath(exe)));
            AppUpdater.CleanUp(exe);
            Assert.False(File.Exists(AppUpdater.OldPath(exe)));

            // the staged file is missing: the running exe must be put back
            Assert.ThrowsAny<Exception>(() => AppUpdater.Swap(exe, AppUpdater.StagedPath(exe)));
            Assert.Equal("new", File.ReadAllText(exe));
            Assert.True(AppUpdater.CanReplace(exe));
            Assert.False(AppUpdater.CanReplace(Path.Combine(dir, "no", "such", "CraftPanel.exe")));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task Live_check_finds_a_windows_zip_on_github()
    {
        var info = await AppUpdater.CheckAsync("0.0.1");
        if (info.Unavailable is { } why && why.StartsWith("Couldn't reach")) return;   // offline: nothing to prove
        Assert.Null(info.Unavailable);
        Assert.True(info.Newer);
        Assert.NotNull(info.ZipUrl);
        Assert.StartsWith("https://github.com/Rashica07/OMNIServers/releases/download/windows-v", info.ZipUrl);
    }

    [Fact]
    public async Task Stage_downloads_the_zip_and_leaves_the_running_exe_untouched()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        var exe = Path.Combine(dir, "CraftPanel.exe");
        File.WriteAllText(exe, "running");
        var payload = new byte[6_000_000]; payload[0] = (byte)'M'; payload[1] = (byte)'Z';
        var zipBytes = File.ReadAllBytes(MakeZip(dir, payload));
        var port = System.Net.Sockets.TcpListener.Create(0); port.Start(); var p = ((System.Net.IPEndPoint)port.LocalEndpoint).Port; port.Stop();
        using var server = new System.Net.HttpListener(); server.Prefixes.Add($"http://127.0.0.1:{p}/"); server.Start();
        var serving = Task.Run(async () => { var c = await server.GetContextAsync(); c.Response.ContentLength64 = zipBytes.Length; await c.Response.OutputStream.WriteAsync(zipBytes); c.Response.Close(); });
        try
        {
            var info = new UpdateInfo("2.8.2", "v2.8.3", true, null, $"http://127.0.0.1:{p}/CraftPanel-2.8.3-win-x64.zip", zipBytes.Length, null, null);
            var staged = await AppUpdater.StageAsync(info, exe);
            await serving;
            Assert.Equal(AppUpdater.StagedPath(exe), staged);
            Assert.Equal(6_000_000, new FileInfo(staged).Length);
            Assert.Equal("running", File.ReadAllText(exe));
            AppUpdater.Swap(exe, staged);
            Assert.Equal(6_000_000, new FileInfo(exe).Length);
        }
        finally { server.Stop(); Directory.Delete(dir, true); }
    }
}
