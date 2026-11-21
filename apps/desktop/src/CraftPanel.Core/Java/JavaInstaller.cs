using System.Formats.Tar;
using System.IO.Compression;
using System.Text.Json.Nodes;

namespace CraftPanel.Core.Java;

/// <summary>
/// Managed Java runtimes: downloads an Eclipse Temurin JRE from Adoptium, verifies the SHA-256
/// Adoptium publishes, and extracts it under <c>%LOCALAPPDATA%\CraftPanel\jre\&lt;feature&gt;\&lt;os&gt;-&lt;arch&gt;</c>.
/// The checksum is not optional — this is the one feature that runs a downloaded binary.
/// </summary>
public static class JavaInstaller
{
    public static readonly uint[] Features = [17, 21, 25];

    /// <summary>Which bundled feature satisfies a requirement (Adoptium has no current build of 8/16).</summary>
    public static uint? OfferableFeature(uint required) => Features.Where(f => f >= required).Cast<uint?>().OrderBy(f => f).FirstOrDefault();

    public static string InstallDir(uint feature) =>
        Path.Combine(AppPaths.JreRoot, feature.ToString(), $"{Platform.AdoptiumOs}-{Platform.AdoptiumArch}");

    /// <summary>The <c>java</c> executable inside an installed runtime, if present.</summary>
    public static string? InstalledPath(uint feature)
    {
        var dir = InstallDir(feature);
        if (!Directory.Exists(dir)) return null;
        foreach (var top in Directory.EnumerateDirectories(dir).OrderBy(d => d, StringComparer.Ordinal))
            foreach (var cand in new[] { Path.Combine(top, "bin", "java" + Platform.ExeSuffix), Path.Combine(top, "Contents", "Home", "bin", "java") })
                if (File.Exists(cand)) return cand;
        return null;
    }

    public static async Task<JavaInfo> InstallAsync(uint feature, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        if (InstalledPath(feature) is { } existing && await JavaProbe.ProbeAsync(existing, ct) is { } have)
        {
            progress?.Report(new("done", "Already installed.", 100));
            return have;
        }
        progress?.Report(new("fetch", $"Finding a Java {feature} build for this PC…", null));
        var url = $"https://api.adoptium.net/v3/assets/latest/{feature}/hotspot?architecture={Platform.AdoptiumArch}&image_type=jre&os={Platform.AdoptiumOs}&vendor=eclipse";
        var json = await Http.GetJsonAsync(url, ct);
        var pkg = json is JsonArray { Count: > 0 } arr ? arr[0]?["binary"]?["package"] : null;
        var link = pkg?["link"]?.GetValue<string>();
        var checksum = pkg?["checksum"]?.GetValue<string>();
        var name = pkg?["name"]?.GetValue<string>() ?? $"java-{feature}";
        if (link is null || checksum is null || !link.StartsWith("https://", StringComparison.Ordinal))
            throw new ProvisionException($"No Java {feature} build is published for this PC ({Platform.AdoptiumOs} {Platform.AdoptiumArch}).");

        var tmp = Path.Combine(Path.GetTempPath(), "cp-" + name);
        try
        {
            await Http.DownloadAsync(link, tmp, name, progress, ct);
            progress?.Report(new("verify", "Verifying checksum", null));
            var got = await Task.Run(() => Http.Sha256Hex(tmp), ct);
            if (!got.Equals(checksum, StringComparison.OrdinalIgnoreCase))
                throw new ProvisionException("The download didn't match the checksum Adoptium published, so OMNIServers deleted it rather than run it. Try again.");

            var dest = InstallDir(feature);
            if (Directory.Exists(dest)) Directory.Delete(dest, recursive: true);   // a partial earlier install
            Directory.CreateDirectory(dest);
            progress?.Report(new("extract", "Extracting…", null));
            await Task.Run(() => Extract(tmp, dest), ct);
        }
        finally { try { File.Delete(tmp); } catch { } }

        var bin = InstalledPath(feature) ?? throw new ProvisionException("Extracted the download but couldn't find java inside it.");
        progress?.Report(new("done", "Java installed.", 100));
        return await JavaProbe.ProbeAsync(bin, ct) ?? throw new ProvisionException("Installed Java, but couldn't get it to report a version.");
    }

    static void Extract(string archive, string dest)
    {
        if (archive.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            ZipFile.ExtractToDirectory(archive, dest, overwriteFiles: true);   // rejects paths that escape dest
        else
        {
            using var fs = File.OpenRead(archive);
            using var gz = new GZipStream(fs, CompressionMode.Decompress);
            TarFile.ExtractToDirectory(gz, dest, overwriteFiles: true);
        }
    }

    /// <summary>Removes one managed runtime.</summary>
    public static void Uninstall(uint feature)
    {
        var d = InstallDir(feature);
        if (Directory.Exists(d)) Directory.Delete(d, recursive: true);
    }
}
