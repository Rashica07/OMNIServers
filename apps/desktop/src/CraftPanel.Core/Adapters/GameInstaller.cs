using System.IO.Compression;
using System.Text.Json.Nodes;

namespace CraftPanel.Core.Adapters;

/// <summary>"Make a new one" for FiveM and Terraria: downloads the official server files into an empty folder, then repairs the setup.</summary>
public static class GameInstaller
{
    public const string FiveMVersions = "https://changelogs-live.fivem.net/api/changelog/versions/{0}/server";
    public const string FiveMData = "https://github.com/citizenfx/cfx-server-data/archive/refs/heads/master.zip";
    public const string TerrariaNames = "https://terraria.org/api/get/dedicated-servers-names";
    public const string TerrariaDownload = "https://terraria.org/api/download/pc-dedicated-server/";

    public static string FiveMPlatform => OperatingSystem.IsWindows() ? "win32" : "linux";

    /// <summary>The newest recommended-or-latest FiveM build link out of the changelog JSON.</summary>
    public static string? ParseFiveMUrl(JsonNode json) =>
        (json["latest_download"] ?? json["recommended_download"])?.GetValue<string>();

    public static string? ParseTerrariaFile(JsonNode json) =>
        json is JsonArray a ? a.Select(x => x?.GetValue<string>()).FirstOrDefault(n => n is not null && n.StartsWith("terraria-server-") && n.EndsWith(".zip")) : null;

    /// <summary>The folder inside Terraria's zip that holds this OS's server (zip is "1458/Windows/…").</summary>
    public static string TerrariaOsFolder => OperatingSystem.IsWindows() ? "Windows" : OperatingSystem.IsMacOS() ? "Mac" : "Linux";

    public static async Task<Created> CreateAsync(ServerType type, string dir, string name, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        if (!type.IsGame()) throw new ArgumentException("Not a game server: " + type);
        if (!GameServers.IsPlatformSupported(type)) throw new ProvisionException($"{type.Label()} has no server for this operating system. Use a Windows or Linux PC.");
        Directory.CreateDirectory(dir);
        if (Directory.EnumerateFileSystemEntries(dir).Any()) throw new ProvisionException("That folder isn't empty — pick a fresh folder for a new server.");
        if (type == ServerType.FiveM) await InstallFiveMAsync(dir, progress, ct); else await InstallTerrariaAsync(dir, progress, ct);
        progress?.Report(new("fix", "Setting it up", null));
        GameServers.Fix(type, dir, name);
        var found = GameServers.Inspect(dir) ?? throw new ProvisionException("The download didn't contain the server program.");
        return new(type, found.LaunchTarget, "", dir, "");
    }

    static async Task InstallFiveMAsync(string dir, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        var json = await Http.GetJsonAsync(string.Format(FiveMVersions, FiveMPlatform), ct);
        var url = ParseFiveMUrl(json) ?? throw new ProvisionException("Couldn't find the latest FiveM server build. Try again in a minute.");
        var tmp = Path.Combine(dir, ".download");
        if (OperatingSystem.IsWindows())
        {
            await Http.DownloadAsync(url, tmp + ".zip", "FiveM server", progress, ct);
            progress?.Report(new("unpack", "Unpacking the server", null));
            ZipFile.ExtractToDirectory(tmp + ".zip", dir, overwriteFiles: true);
            File.Delete(tmp + ".zip");
        }
        else
        {
            await Http.DownloadAsync(url, tmp + ".tar.xz", "FiveM server", progress, ct);
            progress?.Report(new("unpack", "Unpacking the server", null));
            var r = await Proc.RunAsync("tar", ["-xJf", tmp + ".tar.xz", "-C", dir], dir, TimeSpan.FromMinutes(5), ct);
            File.Delete(tmp + ".tar.xz");
            if (r is null || !r.Success) throw new ProvisionException("Couldn't unpack the FiveM download (is `tar` with xz installed?).");
        }
        // The game's own scripts (chat, spawning…) live in a separate public repo.
        var data = Path.Combine(dir, "data.zip");
        await Http.DownloadAsync(FiveMData, data, "FiveM default resources", progress, ct);
        var stage = Path.Combine(dir, ".data");
        ZipFile.ExtractToDirectory(data, stage, overwriteFiles: true);
        File.Delete(data);
        var root = Directory.EnumerateDirectories(stage).FirstOrDefault();
        if (root is not null) CopyDir(root, dir);
        Directory.Delete(stage, true);
    }

    static async Task InstallTerrariaAsync(string dir, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        var names = await Http.GetJsonAsync(TerrariaNames, ct);
        var file = ParseTerrariaFile(names) ?? throw new ProvisionException("Couldn't find the latest Terraria server. Try again in a minute.");
        var zip = Path.Combine(dir, ".terraria.zip");
        await Http.DownloadAsync(TerrariaDownload + file, zip, "Terraria server", progress, ct);
        progress?.Report(new("unpack", "Unpacking the server", null));
        var stage = Path.Combine(dir, ".stage");
        ZipFile.ExtractToDirectory(zip, stage, overwriteFiles: true);
        File.Delete(zip);
        var os = Directory.EnumerateDirectories(stage, TerrariaOsFolder, SearchOption.AllDirectories).FirstOrDefault()
            ?? throw new ProvisionException("The Terraria download had no server for this computer.");
        CopyDir(os, dir);
        Directory.Delete(stage, true);
        if (!OperatingSystem.IsWindows())
            foreach (var f in Directory.EnumerateFiles(dir, "TerrariaServer*").Where(f => !f.EndsWith(".exe")))
                File.SetUnixFileMode(f, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
    }

    static void CopyDir(string from, string to)
    {
        foreach (var d in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, d)));
        foreach (var f in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories)) File.Copy(f, Path.Combine(to, Path.GetRelativePath(from, f)), true);
    }
}
