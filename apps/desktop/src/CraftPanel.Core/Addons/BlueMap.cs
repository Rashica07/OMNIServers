using CraftPanel.Core.Addons;

namespace CraftPanel.Core.Addons;

/// <summary>
/// Live map via BlueMap (MIT, Modrinth <c>bluemap</c>): a 3D/flat web map of every dimension with live player markers,
/// served by the server itself. OMNIServers installs it, writes its config (the Mojang texture-download consent and a
/// port that doesn't clash with other servers' maps) and shows the link.
/// </summary>
public static class BlueMap
{
    public const string ProjectId = "bluemap";
    public const int DefaultPort = 8100;

    public static bool Supported(ServerType t) => t.CanRunAddons();

    public static string ConfigDir(string dir, ServerType t) => t.UsesPlugins() ? Path.Combine(dir, "plugins", "BlueMap") : Path.Combine(dir, "config", "bluemap");

    public static bool IsInstalled(string dir, ServerType t)
    {
        var folder = ModrinthClient.ContentDir(dir, t, "mod");
        return Directory.Exists(folder) && Directory.EnumerateFiles(folder, "*.jar").Any(f => Path.GetFileName(f).StartsWith("bluemap", StringComparison.OrdinalIgnoreCase));
    }

    public static int Port(string dir, ServerType t)
    {
        var f = Path.Combine(ConfigDir(dir, t), "webserver.conf");
        return File.Exists(f) ? ParsePort(File.ReadAllText(f)) ?? DefaultPort : DefaultPort;
    }

    public static int? ParsePort(string conf)
    {
        foreach (var line in conf.Split('\n'))
        {
            var t = line.Trim();
            if (t.StartsWith("port:") && int.TryParse(t[5..].Trim(), out var p)) return p;
        }
        return null;
    }

    public static bool ConsentGiven(string dir, ServerType t)
    {
        var f = Path.Combine(ConfigDir(dir, t), "core.conf");
        return File.Exists(f) && File.ReadAllLines(f).Any(l => l.Trim().Replace(" ", "") == "accept-download:true");
    }

    /// <summary>First free port from 8100 that no other installed map uses.</summary>
    public static int PickPort(IEnumerable<(string Dir, ServerType Type)> others)
    {
        var taken = others.Where(o => IsInstalled(o.Dir, o.Type)).Select(o => Port(o.Dir, o.Type)).ToHashSet();
        var p = DefaultPort;
        while (taken.Contains(p) || !Net.PortFree(p)) p++;
        return p;
    }

    /// <summary>Sets accept-download and the web port, editing BlueMap's own files in place (keeps comments and other settings).</summary>
    public static void Configure(string dir, ServerType t, int port)
    {
        var cfg = ConfigDir(dir, t);
        Directory.CreateDirectory(cfg);
        Upsert(Path.Combine(cfg, "core.conf"), "accept-download", "true");
        Upsert(Path.Combine(cfg, "webserver.conf"), "port", port.ToString());
    }

    public static void Upsert(string file, string key, string value)
    {
        var lines = (File.Exists(file) ? File.ReadAllText(file) : "").Split('\n').ToList();
        var i = lines.FindIndex(l => l.StartsWith(key + ":"));
        if (i >= 0) lines[i] = $"{key}: {value}";
        else { if (lines.Count > 0 && lines[^1] == "") lines.RemoveAt(lines.Count - 1); lines.Add($"{key}: {value}"); lines.Add(""); }
        AppPaths.WriteAtomic(file, string.Join("\n", lines));
    }

    public static async Task InstallAsync(string dir, ServerType t, string? mcVersion, int port, CancellationToken ct = default)
    {
        await ModrinthClient.InstallAsync(dir, t, ProjectId, "mod", mcVersion, ct);
        Configure(dir, t, port);
    }

    public static string LocalUrl(int port) => $"http://127.0.0.1:{port}/";

    /// <summary>Is the map page actually served? A bare 404 means the web server is up but the web app isn't unpacked yet.</summary>
    public static async Task<bool> IsUpAsync(int port)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1.5));
            using var r = await Http.Client.GetAsync(LocalUrl(port), cts.Token);
            return r.StatusCode == System.Net.HttpStatusCode.OK;
        }
        catch { return false; }
    }
}
