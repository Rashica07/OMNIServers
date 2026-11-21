using System.Formats.Tar;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace CraftPanel.Core.Updates;

/// <summary>The newest OMNI Launcher build for this computer, as published on GitHub.</summary>
public sealed record LauncherRelease(string Tag, string Url, long Size, string AssetName);

/// <summary>
/// Downloads OMNI Launcher (the Minecraft launcher that goes with OMNIServers) from its GitHub releases, installs it for the current user
/// (no admin rights) and records which build it put there, so a later newer build can be offered.
/// Launcher builds are published as <c>omni-launcher-v*</c> releases, currently pre-releases, so pre-releases count here.
/// </summary>
public static class LauncherInstaller
{
    public const string Repo = "Rashica07/omni-launcher";
    const long MinBytes = 5_000_000;

    /// <summary>Asset name part for this computer: <c>windows-x64</c>, <c>linux-x64</c>, <c>macos-arm64</c>. Null when no build is published for it.</summary>
    public static string? Platform(Architecture? arch = null)
    {
        var a = arch ?? RuntimeInformation.OSArchitecture;
        if (OperatingSystem.IsWindows()) return a == Architecture.X64 ? "windows-x64" : null;
        if (OperatingSystem.IsLinux()) return a == Architecture.X64 ? "linux-x64" : null;
        if (OperatingSystem.IsMacOS()) return a == Architecture.Arm64 ? "macos-arm64" : null;
        return null;
    }

    /// <summary>The newest non-draft <c>omni-launcher-v*</c> release that has a build for <paramref name="platform"/>. GitHub lists newest first.</summary>
    public static LauncherRelease? Pick(JsonArray releases, string platform)
    {
        foreach (var r in releases)
        {
            var tag = r?["tag_name"]?.GetValue<string>() ?? "";
            if (!tag.StartsWith("omni-launcher-v", StringComparison.OrdinalIgnoreCase) || r!["draft"]?.GetValue<bool>() == true) continue;
            foreach (var a in r["assets"]?.AsArray() ?? [])
            {
                var n = a?["name"]?.GetValue<string>() ?? "";
                if (!n.Contains(platform, StringComparison.OrdinalIgnoreCase)) continue;
                if (!(n.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase))) continue;
                var url = a?["browser_download_url"]?.GetValue<string>();
                if (url is null) continue;
                return new(tag, url, long.TryParse(a?["size"]?.ToString(), out var sz) ? sz : 0, n);
            }
        }
        return null;
    }

    public static async Task<LauncherRelease> LatestAsync(CancellationToken ct = default)
    {
        var platform = Platform() ?? throw new ProvisionException("There's no OMNI Launcher build for this computer yet.");
        JsonNode json;
        try { json = await Http.GetJsonAsync($"https://api.github.com/repos/{Repo}/releases?per_page=20", ct); }
        catch (ProvisionException) { throw new ProvisionException("Couldn't reach GitHub. Check your internet connection and try again."); }
        return Pick(json.AsArray(), platform) ?? throw new ProvisionException("No OMNI Launcher download is published for this computer yet.");
    }

    /// <summary>Where the launcher is installed to, inside the user's own folders.</summary>
    public static string InstallDir(string? home = null, string? localAppData = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (OperatingSystem.IsWindows())
            return Path.Combine(localAppData ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "OMNI Launcher");
        return Path.Combine(home, ".local", "opt", "omni-launcher");
    }

    public static string ExeName => OperatingSystem.IsWindows() ? "omni-launcher.exe" : "omni-launcher";

    static string RecordPath => Path.Combine(AppPaths.LocalDir, "launcher-installed.txt");

    /// <summary>The release tag this app installed last, or null if the launcher came from somewhere else.</summary>
    public static string? InstalledTag() { try { return File.Exists(RecordPath) ? File.ReadAllText(RecordPath).Trim() : null; } catch { return null; } }

    /// <summary>True when this app installed the launcher earlier and a different (newer) build is published now.</summary>
    public static bool IsUpdateAvailable(string? installedTag, string latestTag) =>
        !string.IsNullOrEmpty(installedTag) && !installedTag.Equals(latestTag, StringComparison.OrdinalIgnoreCase);

    /// <summary>Puts the launcher from a downloaded archive into <paramref name="installDir"/>. Returns the program's path.</summary>
    public static string Extract(string archive, string installDir)
    {
        Directory.CreateDirectory(installDir);
        var work = Path.Combine(installDir + ".unpack-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            Directory.CreateDirectory(work);
            if (archive.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) ZipFile.ExtractToDirectory(archive, work);
            else
            {
                using var gz = new GZipStream(File.OpenRead(archive), CompressionMode.Decompress);
                TarFile.ExtractToDirectory(gz, work, overwriteFiles: true);
            }
            var exe = Directory.EnumerateFiles(work, ExeName, SearchOption.AllDirectories).FirstOrDefault()
                      ?? throw new ProvisionException("The download didn't contain the launcher program.");
            if (new FileInfo(exe).Length < MinBytes) throw new ProvisionException("The downloaded launcher looks incomplete, so it wasn't installed.");
            using (var f = File.OpenRead(exe))
            {
                var b = new byte[4]; _ = f.Read(b, 0, 4);
                var ok = OperatingSystem.IsWindows() ? b[0] == 'M' && b[1] == 'Z' : b[0] == 0x7F && b[1] == 'E' && b[2] == 'L' && b[3] == 'F';
                if (!ok) throw new ProvisionException("The downloaded launcher isn't a program for this computer, so it wasn't installed.");
            }
            var src = Path.GetDirectoryName(exe)!;
            foreach (var file in Directory.EnumerateFiles(src))
            {
                var dest = Path.Combine(installDir, Path.GetFileName(file));
                if (File.Exists(dest))
                {   // a running program can be renamed but not overwritten
                    var old = dest + ".old";
                    try { File.Delete(old); } catch { }
                    File.Move(dest, old, overwrite: true);
                }
                File.Move(file, dest);
            }
            var installed = Path.Combine(installDir, ExeName);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(installed, (UnixFileMode)0b111_101_101);
            return installed;
        }
        finally { try { Directory.Delete(work, true); } catch { } }
    }

    /// <summary>Downloads the release and installs it. Returns the installed program's path.</summary>
    public static async Task<string> InstallAsync(LauncherRelease rel, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "omni-launcher-" + Guid.NewGuid().ToString("N")[..8] + (rel.AssetName.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ? ".zip" : ".tar.gz"));
        try
        {
            await Http.DownloadAsync(rel.Url, tmp, "OMNI Launcher", progress, ct);
            if (rel.Size > 0 && new FileInfo(tmp).Length != rel.Size) throw new ProvisionException("The launcher download was incomplete. Try again.");
            progress?.Report(new("unpack", "Installing…", 0));
            var path = await Task.Run(() => Extract(tmp, InstallDir()), ct);
            try { File.WriteAllText(RecordPath, rel.Tag); } catch { }
            return path;
        }
        finally { try { File.Delete(tmp); } catch { } }
    }
}
