using System.Text.Json.Nodes;
using CraftPanel.Core.Addons;

namespace CraftPanel.Core.Network;

/// <param name="GeyserBuild">Geyser build OMNIServers installed (from the sidecar file), null when unknown (installed by an older OMNIServers or by hand).</param>
/// <param name="Transport">Geyser's own <c>bedrock.transport</c> (raknet / nethernet / both) when its config.yml exists.</param>
/// <param name="CloneRemotePort">Geyser shares the Java port, which cannot work with built-in NetherNet signaling.</param>
public sealed record CrossplayStatus(bool Compatible, bool Geyser, bool Floodgate, int BedrockPort, string Folder,
    int? GeyserBuild = null, string? Transport = null, bool CloneRemotePort = false)
{
    /// <summary>Geyser is there but too old (or of unknown age) for Bedrock 26.60.</summary>
    public bool NeedsUpdate => BedrockNetwork.GeyserNeedsUpdate(Geyser, GeyserBuild);
}

/// <summary>
/// Bedrock cross-play: one-click Geyser + Floodgate so people on phones, consoles and the Windows store edition can join a
/// Java server without a Java account. Geyser (and Floodgate for Paper/Spigot) come from GeyserMC's own build API, checked
/// against the SHA-256 it publishes; Floodgate for Fabric/NeoForge comes from Modrinth, which is the only place it's published.
/// </summary>
public static class CrossplayManager
{
    public static string ApiBase { get; set; } = "https://download.geysermc.org/v2/projects";
    public const int DefaultBedrockPort = 19132;

    /// <summary>GeyserMC's artifact name for this loader; null where Geyser can't run (Vanilla has no loader, Forge has no build, Bedrock servers speak Bedrock already).</summary>
    public static string? Platform(ServerType t) => t switch
    {
        ServerType.Paper or ServerType.Spigot => "spigot",
        ServerType.Fabric => "fabric",
        ServerType.NeoForge => "neoforge",
        _ => null,
    };

    public static string Folder(ServerType t) => t.UsesPlugins() ? "plugins" : "mods";

    static IEnumerable<string> JarNames(string dir, ServerType t)
    {
        foreach (var sub in new[] { Folder(t), "mods", "plugins", "mods-disabled" }.Distinct())
        {
            var d = Path.Combine(dir, sub);
            if (!Directory.Exists(d)) continue;
            foreach (var f in Directory.EnumerateFiles(d, "*.jar")) yield return Path.GetFileName(f).ToLowerInvariant();
        }
    }

    static readonly string[] ConfigDirs = ["plugins/Geyser-Spigot", "config/Geyser-Fabric", "config/geyser-neoforge", "config/Geyser-NeoForge"];

    /// <summary>
    /// Reads <c>port</c>, <c>transport</c> and <c>clone-remote-port</c> from the <c>bedrock:</c> section of Geyser's config.yml.
    /// Only the section's own keys count (same indent as its first line), so nested blocks like <c>signaling:</c> can't leak in.
    /// </summary>
    public static (int? Port, string? Transport, bool Clone) ReadBedrockSection(IEnumerable<string> lines)
    {
        int? port = null; string? transport = null; var clone = false;
        var inBedrock = false; int? childIndent = null;
        foreach (var line in lines)
        {
            var t = line.TrimStart(' ', '\t');
            if (t.Length == 0 || t[0] == '#') continue;
            var indent = line.Length - t.Length;
            if (!inBedrock) { if (indent == 0 && t.StartsWith("bedrock:")) inBedrock = true; continue; }
            if (indent == 0) break;                       // next top-level section
            childIndent ??= indent;
            if (indent != childIndent) continue;          // nested block
            var cut = t.IndexOf(" #", StringComparison.Ordinal);
            var kv = (cut >= 0 ? t[..cut] : t).Trim();
            if (kv.StartsWith("port:") && int.TryParse(kv[5..].Trim(), out var n)) port = n;
            else if (kv.StartsWith("transport:")) transport = kv[10..].Trim().Trim('"', '\'').ToLowerInvariant();
            else if (kv.StartsWith("clone-remote-port:")) clone = kv[18..].Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
        }
        return (port, transport, clone);
    }

    static (int? Port, string? Transport, bool Clone) ReadConfig(string dir)
    {
        foreach (var rel in ConfigDirs)
        {
            var cfg = Path.Combine(dir, rel, "config.yml");
            if (File.Exists(cfg)) try { return ReadBedrockSection(File.ReadLines(cfg)); } catch { }
        }
        return (null, null, false);
    }

    /// <summary>Geyser's Bedrock port: the <c>port:</c> in config.yml, else 19132.</summary>
    public static int BedrockPort(string dir) => ReadConfig(dir).Port ?? DefaultBedrockPort;

    /// <summary>Geyser's own <c>bedrock.transport</c>, lower-case, or null when there is no config yet.</summary>
    public static string? ConfigTransport(string dir) => ReadConfig(dir).Transport;

    // ---- which Geyser build is installed (OMNIServers records it; Geyser's jar name doesn't say) ----

    public const string BuildFile = ".craftpanel-geyser.json";

    public static int? InstalledBuild(string dir)
    {
        try { return JsonNode.Parse(File.ReadAllText(Path.Combine(dir, BuildFile)))?["build"]?.GetValue<int>(); } catch { return null; }
    }

    static void RecordBuild(string dir, int build, string version) =>
        File.WriteAllText(Path.Combine(dir, BuildFile), new JsonObject { ["build"] = build, ["version"] = version }.ToJsonString());

    /// <summary>JVM args to launch this server with: the user's own plus Geyser's NetherNet flag when it applies.</summary>
    public static string? LaunchJvmArgs(string dir, ServerType t, string? userArgs)
    {
        if (Platform(t) is null) return userArgs;
        var cfg = ReadConfig(dir);
        return BedrockNetwork.WithGeyserFlags(userArgs, JarNames(dir, t).Any(j => j.Contains("geyser")), cfg.Transport);
    }

    public static CrossplayStatus Status(string dir, ServerType t)
    {
        var jars = JarNames(dir, t).ToList();
        var cfg = ReadConfig(dir);
        var geyser = jars.Any(j => j.Contains("geyser"));
        return new(Platform(t) is not null, geyser, jars.Any(j => j.Contains("floodgate")), cfg.Port ?? DefaultBedrockPort, Folder(t),
            geyser ? InstalledBuild(dir) : null, cfg.Transport, cfg.Clone);
    }

    /// <summary>Downloads the newest build of a GeyserMC project's artifact, verified, into <paramref name="dest"/>.</summary>
    static async Task<(int Build, string Version)> DownloadGeyserMcAsync(string project, string artifact, string dest, CancellationToken ct)
    {
        JsonNode build;
        try { build = await Http.GetJsonAsync($"{ApiBase}/{project}/versions/latest/builds/latest", ct); }
        catch (ProvisionException e) { throw new ProvisionException($"{project} download failed: {e.Message}", e); }
        var info = build["downloads"]?[artifact];
        var name = info?["name"]?.GetValue<string>();
        var sha = info?["sha256"]?.GetValue<string>();
        var version = build["version"]?.GetValue<string>();
        var number = build["build"]?.ToString();
        if (name is null || version is null || number is null) throw new ProvisionException($"{project} has no {artifact} build right now.");
        var file = Path.Combine(dest, FileOps.SafeFileName(name));
        Directory.CreateDirectory(dest);
        await Http.DownloadAsync($"{ApiBase}/{project}/versions/{Uri.EscapeDataString(version)}/builds/{Uri.EscapeDataString(number)}/downloads/{artifact}", file, name, null, ct);
        var len = new FileInfo(file).Length;
        if (len < 100_000) { File.Delete(file); throw new ProvisionException($"{project} download looks wrong ({len} bytes)"); }
        if (sha is not null && !Http.Sha256Hex(file).Equals(sha, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(file);
            throw new ProvisionException($"{name} didn't match the checksum GeyserMC published, so OMNIServers deleted it rather than run it. Try again.");
        }
        return BedrockNetwork.ParseGeyserBuild(build) ?? (int.TryParse(number, out var n) ? n : 0, version);
    }

    public static async Task<CrossplayStatus> EnableAsync(string dir, ServerType t, string? mcVersion = null, CancellationToken ct = default)
    {
        var artifact = Platform(t) ?? throw new ProvisionException("Bedrock cross-play needs Paper, Spigot, Fabric or NeoForge — Vanilla and Forge can't run Geyser.");
        var dest = Path.Combine(dir, Folder(t));

        var (build, version) = await DownloadGeyserMcAsync("geyser", artifact, dest, ct);
        RecordBuild(dir, build, version);

        // Floodgate lets Bedrock players in without a Java account. Not having it isn't fatal: say so, keep Geyser.
        Exception? floodgateError = null;
        try
        {
            if (artifact == "spigot") await DownloadGeyserMcAsync("floodgate", artifact, dest, ct);
            else await ModrinthClient.InstallAsync(dir, t, "floodgate", "mod", mcVersion, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException) { floodgateError = e; }

        // Geyser on Fabric needs the Fabric API.
        if (t == ServerType.Fabric)
            try { await ModrinthClient.InstallAsync(dir, t, "fabric-api", "mod", mcVersion, ct); } catch (Exception e) when (e is not OperationCanceledException) { }

        var st = Status(dir, t);
        if (floodgateError is not null && !st.Floodgate)
            throw new ProvisionException($"Geyser is installed. Floodgate couldn't be fetched automatically ({floodgateError.Message}). Get it from geysermc.org and drop it in {st.Folder}/.", floodgateError);
        return st;
    }

    /// <summary>
    /// Replaces an old Geyser with the newest build (the old jar goes to the server's trash folder; Floodgate stays).
    /// Needed for Bedrock 26.60: only Geyser build 1273 and newer speak NetherNet.
    /// </summary>
    public static async Task<CrossplayStatus> UpdateGeyserAsync(string dir, ServerType t, CancellationToken ct = default)
    {
        var artifact = Platform(t) ?? throw new ProvisionException("This server type can't run Geyser.");
        var dest = Path.Combine(dir, Folder(t));
        var staging = Path.Combine(dir, ".craftpanel-trash", "geyser-update-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(staging);
        // download first, so a failed download leaves the old Geyser in place
        var (build, version) = await DownloadGeyserMcAsync("geyser", artifact, staging, ct);
        foreach (var sub in new[] { Folder(t), "mods", "plugins", "mods-disabled" }.Distinct())
        {
            var d = Path.Combine(dir, sub);
            if (!Directory.Exists(d)) continue;
            foreach (var f in Directory.EnumerateFiles(d, "*.jar").ToList())
                if (Path.GetFileName(f).Contains("geyser", StringComparison.OrdinalIgnoreCase)) try { FileOps.MoveToTrash(f, Path.Combine(dir, ".craftpanel-trash")); } catch { }
        }
        Directory.CreateDirectory(dest);
        foreach (var f in Directory.EnumerateFiles(staging, "*.jar")) File.Move(f, Path.Combine(dest, Path.GetFileName(f)), true);
        try { Directory.Delete(staging, true); } catch { }
        RecordBuild(dir, build, version);
        return Status(dir, t);
    }

    /// <summary>Takes Geyser and Floodgate out (to the server's trash folder, never deleted) and tidies the add-on list.</summary>
    public static void Disable(string dir, ServerType t)
    {
        try { File.Delete(Path.Combine(dir, BuildFile)); } catch { }
        foreach (var e in ModrinthClient.Installed(dir).Where(e => e.Slug is "floodgate" or "geyser").ToList())
            try { ModrinthClient.RemoveOne(dir, t, e.ProjectId); } catch { }
        foreach (var sub in new[] { Folder(t), "mods", "plugins", "mods-disabled" }.Distinct())
        {
            var d = Path.Combine(dir, sub);
            if (!Directory.Exists(d)) continue;
            foreach (var f in Directory.EnumerateFiles(d, "*.jar").ToList())
            {
                var n = Path.GetFileName(f).ToLowerInvariant();
                if (n.Contains("geyser") || n.Contains("floodgate")) try { FileOps.MoveToTrash(f, Path.Combine(dir, ".craftpanel-trash")); } catch { }
            }
        }
    }
}
