using System.Formats.Tar;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace CraftPanel.Core.Updates;

/// <summary>What the update check found.</summary>
public sealed record UpdateInfo(string Current, string? Latest, bool Newer, string? ReleaseUrl, string? ZipUrl, long ZipSize, string? Notes, string? Unavailable);

/// <summary>
/// Looks for a newer Windows or Linux release on GitHub and swaps the running exe for it. Releases of both apps share one repo (<c>windows-v*</c> is this one),
/// so "latest" is never used. A running exe can be renamed but not overwritten, so the swap is: rename the old one to <c>.old</c>, move the new one in,
/// start it, quit. No scripts, no PowerShell, no admin rights: it works anywhere the exe's own folder is writable.
/// </summary>
public static class AppUpdater
{
    public const string Repo = "Rashica07/OMNIServers";
    public const string WaitArg = "--after-update";
    const long MinExeBytes = 5_000_000;

    public static (int, int, int) ParseVersion(string s)
    {
        s = s.Trim();
        foreach (var p in new[] { "windows-", "linux-", "swift-" }) if (s.StartsWith(p, StringComparison.OrdinalIgnoreCase)) s = s[p.Length..];
        s = s.TrimStart('v', 'V');
        var parts = s.Split('.', '-', '+').Select(x => int.TryParse(x, out var n) ? n : (int?)null).TakeWhile(x => x is not null).Select(x => x!.Value).ToArray();
        return (parts.Length > 0 ? parts[0] : 0, parts.Length > 1 ? parts[1] : 0, parts.Length > 2 ? parts[2] : 0);
    }

    static int Cmp((int, int, int) a, (int, int, int) b) => a.CompareTo(b);

    public static string CurrentArch =>
        (OperatingSystem.IsLinux() ? "linux-" : "win-") + (RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64");

    static bool IsLinux(string arch) => arch.StartsWith("linux", StringComparison.OrdinalIgnoreCase);

    /// <summary>Chooses the newest published <c>windows-v*</c> (or <c>linux-v*</c>) release and the archive built for this PC's chip.</summary>
    public static UpdateInfo Pick(JsonArray releases, string current, string arch)
    {
        var prefix = IsLinux(arch) ? "linux-v" : "windows-v";
        var ext = IsLinux(arch) ? ".tar.gz" : ".zip";
        JsonNode? best = null;
        foreach (var r in releases)
        {
            var tag = r?["tag_name"]?.GetValue<string>() ?? "";
            if (!tag.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            if (r!["draft"]?.GetValue<bool>() == true || r["prerelease"]?.GetValue<bool>() == true) continue;
            if (best is null || Cmp(ParseVersion(tag), ParseVersion(best["tag_name"]!.GetValue<string>())) > 0) best = r;
        }
        if (best is null) return new(current, null, false, null, null, 0, null, IsLinux(arch) ? "No Linux release is published yet." : "No Windows release is published yet.");
        var latest = best["tag_name"]!.GetValue<string>()[(prefix.Length - 1)..];
        JsonNode? zip = null;
        foreach (var a in best["assets"]?.AsArray() ?? [])
        {
            var n = a?["name"]?.GetValue<string>() ?? "";
            if (n.EndsWith(ext, StringComparison.OrdinalIgnoreCase) && n.Contains(arch, StringComparison.OrdinalIgnoreCase)) { zip = a; break; }
        }
        var body = best["body"]?.GetValue<string>();
        var notes = body is null ? null : string.Join("\n", body.Replace("\r", "").Split('\n').Take(8));
        return new(current, latest, Cmp(ParseVersion(latest), ParseVersion(current)) > 0, best["html_url"]?.GetValue<string>(),
                   zip?["browser_download_url"]?.GetValue<string>(), long.TryParse(zip?["size"]?.ToString(), out var sz) ? sz : 0, notes, null);
    }

    public static async Task<UpdateInfo> CheckAsync(string current, CancellationToken ct = default)
    {
        try
        {
            var json = await Http.GetJsonAsync($"https://api.github.com/repos/{Repo}/releases?per_page=30", ct);
            return Pick(json.AsArray(), current, CurrentArch);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return new(current, null, false, null, null, 0, null, "Couldn't reach GitHub. Check your internet connection (some school networks block it) and try again.");
        }
    }

    /// <summary>Whether the exe can be replaced where it sits (not in Program Files, not read-only).</summary>
    public static bool CanReplace(string exePath)
    {
        try
        {
            var dir = Path.GetDirectoryName(exePath)!;
            var probe = Path.Combine(dir, ".craftpanel-write-test-" + Guid.NewGuid().ToString("N")[..8]);
            File.WriteAllText(probe, "x"); File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    public static string StagedPath(string exePath) => exePath + ".new";
    public static string OldPath(string exePath) => exePath + ".old";

    /// <summary>Pulls <c>CraftPanel.exe</c> out of the release zip into <paramref name="destExe"/> and checks it looks like a program.</summary>
    public static void ExtractExe(string zipPath, string destExe)
    {
        using var zip = ZipFile.OpenRead(zipPath);
        var entry = zip.Entries.FirstOrDefault(e => e.FullName.Equals("CraftPanel.exe", StringComparison.OrdinalIgnoreCase))
                    ?? throw new ProvisionException("The update didn't contain CraftPanel.exe.");
        if (entry.Length < MinExeBytes) throw new ProvisionException("The downloaded update looks incomplete, so it wasn't installed.");
        entry.ExtractToFile(destExe, overwrite: true);
        using var f = File.OpenRead(destExe);
        if (f.ReadByte() != 'M' || f.ReadByte() != 'Z') { f.Dispose(); File.Delete(destExe); throw new ProvisionException("The downloaded update isn't a Windows program, so it wasn't installed."); }
    }

    /// <summary>Pulls <c>omniservers</c> out of the Linux release archive into <paramref name="destBin"/> and checks it is an ELF program.</summary>
    public static void ExtractLinuxBinary(string tgzPath, string destBin)
    {
        using var gz = new GZipStream(File.OpenRead(tgzPath), CompressionMode.Decompress);
        using var tar = new TarReader(gz);
        while (tar.GetNextEntry() is { } e)
        {
            if (e.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile) || e.DataStream is null) continue;
            if (!Path.GetFileName(e.Name).Equals("omniservers", StringComparison.Ordinal)) continue;
            if (e.Length < MinExeBytes) throw new ProvisionException("The downloaded update looks incomplete, so it wasn't installed.");
            using (var o = File.Create(destBin)) e.DataStream.CopyTo(o);
            using (var f = File.OpenRead(destBin))
                if (f.ReadByte() != 0x7F || f.ReadByte() != 'E' || f.ReadByte() != 'L' || f.ReadByte() != 'F') { f.Dispose(); File.Delete(destBin); throw new ProvisionException("The downloaded update isn't a Linux program, so it wasn't installed."); }
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(destBin, (UnixFileMode)0b111_101_101);
            return;
        }
        throw new ProvisionException("The update didn't contain the omniservers program.");
    }

    /// <summary>Downloads the zip and stages the new exe next to the running one. Nothing is replaced yet.</summary>
    public static async Task<string> StageAsync(UpdateInfo info, string exePath, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        if (info.ZipUrl is null) throw new ProvisionException("This release has no download for this PC.");
        var isTgz = info.ZipUrl.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase);
        var tmpZip = Path.Combine(Path.GetTempPath(), "CraftPanel-update-" + Guid.NewGuid().ToString("N")[..8] + (isTgz ? ".tar.gz" : ".zip"));
        var staged = StagedPath(exePath);
        try
        {
            await Http.DownloadAsync(info.ZipUrl, tmpZip, "the update", progress, ct);
            progress?.Report(new("unpack", "Unpacking…", 0));
            await Task.Run(() => { if (isTgz) ExtractLinuxBinary(tmpZip, staged); else ExtractExe(tmpZip, staged); }, ct);
            return staged;
        }
        catch { try { File.Delete(staged); } catch { } throw; }
        finally { try { File.Delete(tmpZip); } catch { } }
    }

    /// <summary>Renames the running exe aside and moves the staged one into its place. Undoes itself if the second step fails.</summary>
    public static void Swap(string exePath, string stagedPath)
    {
        var old = OldPath(exePath);
        if (File.Exists(old)) File.Delete(old);
        File.Move(exePath, old);
        try { File.Move(stagedPath, exePath); }
        catch { File.Move(old, exePath, overwrite: true); throw; }
    }

    /// <summary>Called at startup: removes the previous version left behind by an update.</summary>
    public static void CleanUp(string exePath)
    {
        foreach (var p in new[] { OldPath(exePath), StagedPath(exePath) }) try { File.Delete(p); } catch { /* still in use; next launch */ }
    }
}
