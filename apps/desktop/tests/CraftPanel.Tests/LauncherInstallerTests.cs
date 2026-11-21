using System.Formats.Tar;
using System.IO.Compression;
using System.Text.Json.Nodes;
using CraftPanel.Core;
using CraftPanel.Core.Updates;
using Xunit;

namespace CraftPanel.Tests;

public class LauncherInstallerTests
{
    static JsonNode Rel(string tag, bool draft, params string[] assets) => new JsonObject
    {
        ["tag_name"] = tag, ["draft"] = draft,
        ["assets"] = new JsonArray(assets.Select(a => (JsonNode)new JsonObject { ["name"] = a, ["browser_download_url"] = "https://dl/" + tag + "/" + a, ["size"] = 30_000_000 }).ToArray()),
    };

    [Fact]
    public void Picks_the_newest_launcher_release_with_a_build_for_this_computer()
    {
        var rels = new JsonArray(
            Rel("swift-v9.0.0", false, "x-windows-x64.zip"),
            Rel("omni-launcher-v0.3.0", true, "OMNI-Launcher-windows-x64.zip"),
            Rel("omni-launcher-v0.2.0-dev.2", false, "OMNI-Launcher-macos-arm64.zip"),
            Rel("omni-launcher-v0.2.0-dev.1", false, "OMNI-Launcher-windows-x64.zip", "OMNI-Launcher-linux-x64.tar.gz"));
        var win = LauncherInstaller.Pick(rels, "windows-x64")!;
        Assert.Equal("omni-launcher-v0.2.0-dev.1", win.Tag);   // the draft is skipped, and dev.2 has no Windows build
        Assert.EndsWith("OMNI-Launcher-windows-x64.zip", win.Url);
        Assert.EndsWith(".tar.gz", LauncherInstaller.Pick(rels, "linux-x64")!.AssetName);
        Assert.Equal("omni-launcher-v0.2.0-dev.2", LauncherInstaller.Pick(rels, "macos-arm64")!.Tag);
        Assert.Null(LauncherInstaller.Pick(rels, "linux-arm64"));
    }

    [Fact]
    public void Offers_an_update_only_when_this_app_installed_an_older_build()
    {
        Assert.False(LauncherInstaller.IsUpdateAvailable(null, "omni-launcher-v1"));
        Assert.False(LauncherInstaller.IsUpdateAvailable("omni-launcher-v1", "omni-launcher-v1"));
        Assert.True(LauncherInstaller.IsUpdateAvailable("omni-launcher-v1", "omni-launcher-v2"));
    }

    static byte[] Program(bool windows) { var b = new byte[6_000_000]; if (windows) { b[0] = (byte)'M'; b[1] = (byte)'Z'; } else { b[0] = 0x7F; b[1] = (byte)'E'; b[2] = (byte)'L'; b[3] = (byte)'F'; } return b; }

    [Fact]
    public void Extracts_a_zip_or_tarball_into_the_install_folder_and_replaces_an_older_copy()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var win = OperatingSystem.IsWindows();
            var exe = LauncherInstaller.ExeName;
            // zip with the program at the top, like the Windows build
            var zip = Path.Combine(dir, "l.zip");
            using (var z = ZipFile.Open(zip, ZipArchiveMode.Create)) { using var s = z.CreateEntry(exe).Open(); s.Write(Program(win)); }
            var target = Path.Combine(dir, "install");
            Directory.CreateDirectory(target);
            File.WriteAllText(Path.Combine(target, exe), "old build");
            var path = LauncherInstaller.Extract(zip, target);
            Assert.Equal(Path.Combine(target, exe), path);
            Assert.Equal(6_000_000, new FileInfo(path).Length);
            Assert.True(File.Exists(path + ".old"));

            // tarball with a top folder, like the Linux build
            var src = Path.Combine(dir, "src", "omni-launcher"); Directory.CreateDirectory(src);
            File.WriteAllBytes(Path.Combine(src, exe), Program(win));
            File.WriteAllText(Path.Combine(src, "omni-launcher.desktop"), "[Desktop Entry]");
            var tgz = Path.Combine(dir, "l.tar.gz");
            using (var o = File.Create(tgz)) using (var gz = new GZipStream(o, CompressionLevel.Fastest)) TarFile.CreateFromDirectory(Path.Combine(dir, "src"), gz, false);
            var target2 = Path.Combine(dir, "install2");
            var p2 = LauncherInstaller.Extract(tgz, target2);
            Assert.True(File.Exists(p2));
            Assert.True(File.Exists(Path.Combine(target2, "omni-launcher.desktop")));
            if (!win) Assert.True((File.GetUnixFileMode(p2) & UnixFileMode.UserExecute) != 0);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Rejects_a_download_that_is_not_a_program()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var zip = Path.Combine(dir, "l.zip");
            using (var z = ZipFile.Open(zip, ZipArchiveMode.Create)) { using var s = z.CreateEntry(LauncherInstaller.ExeName).Open(); s.Write(new byte[6_000_000]); }
            Assert.Throws<ProvisionException>(() => LauncherInstaller.Extract(zip, Path.Combine(dir, "i")));
            var small = Path.Combine(dir, "s.zip");
            using (var z = ZipFile.Open(small, ZipArchiveMode.Create)) { using var s = z.CreateEntry(LauncherInstaller.ExeName).Open(); s.Write(new byte[100]); }
            Assert.Throws<ProvisionException>(() => LauncherInstaller.Extract(small, Path.Combine(dir, "i2")));
            var none = Path.Combine(dir, "n.zip");
            using (var z = ZipFile.Open(none, ZipArchiveMode.Create)) { using var s = z.CreateEntry("readme.txt").Open(); s.Write(new byte[10]); }
            Assert.Throws<ProvisionException>(() => LauncherInstaller.Extract(none, Path.Combine(dir, "i3")));
        }
        finally { Directory.Delete(dir, true); }
    }
}

public class LinuxUpdaterTests
{
    static JsonNode Rel(string tag, params string[] assets) => new JsonObject
    {
        ["tag_name"] = tag, ["draft"] = false, ["prerelease"] = false, ["html_url"] = "u", ["body"] = "n",
        ["assets"] = new JsonArray(assets.Select(a => (JsonNode)new JsonObject { ["name"] = a, ["browser_download_url"] = "https://dl/" + a, ["size"] = 1 }).ToArray()),
    };

    [Fact]
    public void Linux_picks_linux_releases_and_the_tarball_for_its_chip()
    {
        var rels = new JsonArray(Rel("windows-v9.0.0", "OMNIServers-9.0.0-win-x64.zip"),
            Rel("linux-v3.1.1", "OMNIServers-3.1.1-linux-x64.tar.gz", "OMNIServers-3.1.1-linux-arm64.tar.gz", "SHA256SUMS-linux.txt"),
            Rel("linux-v3.1.0", "OMNIServers-3.1.0-linux-x64.tar.gz"));
        var x = AppUpdater.Pick(rels, "3.1.0", "linux-x64");
        Assert.Equal("v3.1.1", x.Latest);
        Assert.True(x.Newer);
        Assert.EndsWith("linux-x64.tar.gz", x.ZipUrl);
        Assert.EndsWith("linux-arm64.tar.gz", AppUpdater.Pick(rels, "3.1.0", "linux-arm64").ZipUrl);
        Assert.False(AppUpdater.Pick(rels, "3.1.1", "linux-x64").Newer);
        Assert.Equal((3, 1, 1), AppUpdater.ParseVersion("linux-v3.1.1"));
    }

    [Fact]
    public void Linux_extract_takes_omniservers_and_checks_it_is_an_elf()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        try
        {
            string Pack(byte[] bin, string name)
            {
                var src = Path.Combine(dir, "s" + Guid.NewGuid().ToString("N")[..4]); Directory.CreateDirectory(src);
                File.WriteAllBytes(Path.Combine(src, name), bin);
                File.WriteAllText(Path.Combine(src, "README.txt"), "hi");
                var tgz = src + ".tar.gz";
                using var o = File.Create(tgz); using var gz = new GZipStream(o, CompressionLevel.Fastest); TarFile.CreateFromDirectory(src, gz, false);
                return tgz;
            }
            var elf = new byte[6_000_000]; elf[0] = 0x7F; elf[1] = (byte)'E'; elf[2] = (byte)'L'; elf[3] = (byte)'F';
            var dest = Path.Combine(dir, "new");
            AppUpdater.ExtractLinuxBinary(Pack(elf, "omniservers"), dest);
            Assert.Equal(6_000_000, new FileInfo(dest).Length);
            Assert.Throws<ProvisionException>(() => AppUpdater.ExtractLinuxBinary(Pack(new byte[6_000_000], "omniservers"), Path.Combine(dir, "bad")));
            Assert.Throws<ProvisionException>(() => AppUpdater.ExtractLinuxBinary(Pack(elf, "other"), Path.Combine(dir, "none")));
        }
        finally { Directory.Delete(dir, true); }
    }
}
