using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CraftPanel.Core.Adapters;

/// <summary>
/// Moves a Java server onto OMNIHost: a COPY of its world (the engine converts the copy to its own format, one way), its settings,
/// player lists and icon. The Java server is never touched, so it stays as the backup and the way back. Mods and plugins do not move:
/// they don't run on OMNIHost.
/// </summary>
public static partial class OmniHostTransfer
{
    /// <summary>What each mod in <c>mods/</c> means for OMNIHost. None of them run there; this says why.</summary>
    public sealed record ModReport
    {
        /// <summary>Client-only mods: they belong in the player's launcher, not on a server.</summary>
        public List<string> ClientOnly { get; init; } = [];
        /// <summary>Server speed-ups (Lithium, FerriteCore ...): the engine is already fast, nothing to port.</summary>
        public List<string> NotNeeded { get; init; } = [];
        /// <summary>Mods that add gameplay: they stay on the Java server.</summary>
        public List<string> Gameplay { get; init; } = [];
        public int Total => ClientOnly.Count + NotNeeded.Count + Gameplay.Count;
    }

    public sealed record Plan(string Name, string SourceDir, string LevelName, long WorldBytes, PumpkinConfig.Settings Settings,
        int ModCount, int PluginCount, bool HasIcon, IReadOnlyList<string> Lists, int PlayerCount, ModReport Mods);

    public sealed class TransferException(string message) : Exception(message);

    public static string Format(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.#} GB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0.#} MB",
        >= 1L << 10 => $"{bytes / (double)(1L << 10):0.#} KB",
        _ => $"{bytes} bytes",
    };

    public static bool CanTransfer(ServerType t) => t.UsesJava();

    /// <summary>Player lists the engine reads from <c>data/</c> (same file names and format as vanilla, checked).</summary>
    public static readonly string[] ListFiles = ["ops.json", "whitelist.json", "banned-players.json", "banned-ips.json"];
    /// <summary>Inside the world folder: mod-only data and the lock, left behind.</summary>
    public static readonly string[] SkippedInWorld = ["session.lock", "vss-lod"];

    static bool Flag(Properties p, string key) => p.Get(key)?.Trim().Equals("true", StringComparison.OrdinalIgnoreCase) == true;
    static bool NotFalse(Properties p, string key) => p.Get(key)?.Trim().Equals("false", StringComparison.OrdinalIgnoreCase) != true;
    static int? Int(Properties p, string key) => int.TryParse(p.Get(key)?.Trim(), out var v) ? v : null;

    /// <summary><c>server.properties</c> to the settings the engine understands.</summary>
    public static PumpkinConfig.Settings SettingsFrom(Properties p)
    {
        var level = (p.Get("level-name") ?? "world").Trim();
        if (level.Length == 0 || level.Contains('/') || level.Contains('\\') || level.Contains("..") || level.StartsWith('.')) level = "world";
        var port = int.TryParse(p.Get("server-port")?.Trim(), out var pt) && pt is > 0 and <= 65535 ? pt : 25565;
        return new PumpkinConfig.Settings
        {
            Motd = p.Get("motd") ?? "",
            Port = port,
            MaxPlayers = Int(p, "max-players") ?? 20,
            Gamemode = (p.Get("gamemode") ?? "survival").ToLowerInvariant(),
            Difficulty = (p.Get("difficulty") ?? "normal").ToLowerInvariant(),
            Seed = p.Get("level-seed") ?? "",
            OnlineMode = NotFalse(p, "online-mode"),
            LevelName = level,
            ViewDistance = Int(p, "view-distance"),
            SimulationDistance = Int(p, "simulation-distance"),
            Whitelist = Flag(p, "white-list"),
            EnforceWhitelist = Flag(p, "enforce-whitelist"),
            Hardcore = Flag(p, "hardcore"),
            AllowNether = NotFalse(p, "allow-nether"),
            SpawnProtection = Int(p, "spawn-protection") ?? 16,
            ForceGamemode = Flag(p, "force-gamemode"),
            OpPermissionLevel = Int(p, "op-permission-level") ?? 4,
            Pvp = NotFalse(p, "pvp"),
            ResourcePackUrl = p.Get("resource-pack") ?? "",
            ResourcePackSha1 = p.Get("resource-pack-sha1") ?? "",
            ResourcePackForce = Flag(p, "require-resource-pack"),
            ResourcePackPrompt = p.Get("resource-pack-prompt") ?? "",
        };
    }

    // ---- players ---------------------------------------------------------------------

    /// <summary>The id this engine gives an offline-mode player: the first 16 bytes of SHA-256 of the name. (Java uses an MD5 based id, so offline players need their files renamed. Checked against the real engine.)</summary>
    public static string OfflineUuid(string name)
    {
        var hex = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(name)).AsSpan(0, 16)).ToLowerInvariant();
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..32]}";
    }

    static JsonArray? ReadArray(string path)
    {
        try { return File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) as JsonArray : null; } catch { return null; }
    }

    /// <summary>id to name from the files a Java server keeps (usercache, whitelist, ops, bans).</summary>
    public static Dictionary<string, string> KnownPlayers(string dir)
    {
        var map = new Dictionary<string, string>();
        foreach (var f in new[] { "usercache.json", "whitelist.json", "ops.json", "banned-players.json" })
            foreach (var e in ReadArray(Path.Combine(dir, f)) ?? [])
                if (e?["uuid"]?.GetValue<string>() is { } u && e["name"]?.GetValue<string>() is { Length: > 0 } n) map[u.ToLowerInvariant()] = n;
        return map;
    }

    /// <summary>Saved player data files (<c>world/players/data/&lt;uuid&gt;.dat</c>).</summary>
    public static List<string> PlayerIds(string world)
    {
        var dir = Path.Combine(world, "players", "data");
        return Directory.Exists(dir)
            ? Directory.EnumerateFiles(dir, "*.dat").Select(f => Path.GetFileNameWithoutExtension(f).ToLowerInvariant()).Order(StringComparer.Ordinal).ToList()
            : [];
    }

    [GeneratedRegex(@"^(.*\s)([+-]\d{2})(\d{2})$")] private static partial Regex ZoneNoColon();

    /// <summary>Java's advancement file to the engine's: <c>{"adv": {"criteria": {"c": "2026-08-29 17:40:46 +0200"}, "done": true}}</c> becomes <c>{"adv": {"c": {"secs_since_epoch": ..., "nanos_since_epoch": 0}}}</c>. Null if it can't be read.</summary>
    public static string? ConvertAdvancements(string json)
    {
        JsonObject? root;
        try { root = JsonNode.Parse(json) as JsonObject; } catch { return null; }
        if (root is null) return null;
        var output = new JsonObject();
        foreach (var (adv, v) in root)
        {
            if (v is not JsonObject entry || entry["criteria"] is not JsonObject criteria) continue;
            var c = new JsonObject();
            foreach (var (name, t) in criteria)
            {
                var str = t is JsonValue jv && jv.TryGetValue<string>(out var s) ? s : null;
                if (str is null) continue;
                str = ZoneNoColon().Replace(str, "$1$2:$3");
                if (!DateTimeOffset.TryParseExact(str, "yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) continue;
                c[name] = new JsonObject { ["secs_since_epoch"] = date.ToUnixTimeSeconds(), ["nanos_since_epoch"] = 0 };
            }
            output[adv] = c;
        }
        return output.ToJsonString();
    }

    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };

    /// <summary>Rewrites <c>uuid</c> fields of a player list with <paramref name="map"/> (old id to new id).</summary>
    public static string? RemapList(string json, IReadOnlyDictionary<string, string> map)
    {
        JsonArray? arr;
        try { arr = JsonNode.Parse(json) as JsonArray; } catch { return null; }
        if (arr is null) return null;
        foreach (var e in arr)
            if (e is JsonObject o && o["uuid"]?.GetValue<string>() is { } u && map.TryGetValue(u.ToLowerInvariant(), out var n)) o["uuid"] = n;
        return arr.ToJsonString(Pretty);
    }

    static void Move(string a, string b)
    {
        if (!File.Exists(a)) return;
        try { File.Delete(b); File.Move(a, b); } catch { }
    }

    /// <summary>Moves each player's data over to the new engine: offline servers get their ids renamed, and advancements are converted. Returns how many players were carried.</summary>
    public static int CarryPlayers(string sourceDir, string world, string dataDir, bool onlineMode)
    {
        var names = KnownPlayers(sourceDir);
        var map = new Dictionary<string, string>();
        foreach (var id in PlayerIds(world))
        {
            if (onlineMode) map[id] = id;
            else if (names.TryGetValue(id, out var n)) map[id] = OfflineUuid(n);
        }
        var carried = 0;
        var basePath = Path.Combine(world, "players");
        foreach (var (old, @new) in map)
        {
            if (old != @new)
            {
                foreach (var ext in new[] { "dat", "dat_old" })
                    Move(Path.Combine(basePath, "data", $"{old}.{ext}"), Path.Combine(basePath, "data", $"{@new}.{ext}"));
                Move(Path.Combine(basePath, "stats", $"{old}.json"), Path.Combine(basePath, "stats", $"{@new}.json"));
            }
            // Advancements always need converting; the engine rejects the Java layout.
            var aa = Path.Combine(basePath, "advancements", $"{old}.json");
            if (File.Exists(aa))
            {
                var text = File.ReadAllText(aa);
                File.Delete(aa);
                if (ConvertAdvancements(text) is { } converted) File.WriteAllText(Path.Combine(basePath, "advancements", $"{@new}.json"), converted);
            }
            carried++;
        }
        // Advancements/stats of players we can't map (offline, unknown name) would only confuse the engine.
        foreach (var sub in new[] { "advancements", "stats" })
        {
            var dir = Path.Combine(basePath, sub);
            if (!Directory.Exists(dir)) continue;
            foreach (var f in Directory.EnumerateFiles(dir, "*.json").ToList())
                if (!map.Values.Contains(Path.GetFileNameWithoutExtension(f).ToLowerInvariant())) File.Delete(f);
        }
        // Lists: ids follow the same map.
        foreach (var f in ListFiles)
        {
            var path = Path.Combine(dataDir, f);
            if (File.Exists(path) && RemapList(File.ReadAllText(path), map) is { } r) File.WriteAllText(path, r);
        }
        // Players on the lists who never had a data file still need their new id (offline only).
        if (!onlineMode)
            foreach (var f in ListFiles)
            {
                var path = Path.Combine(dataDir, f);
                if (ReadArray(path) is not { } arr) continue;
                foreach (var e in arr)
                    if (e is JsonObject o && o["name"]?.GetValue<string>() is { Length: > 0 } n && o["uuid"]?.GetValue<string>() is { } u
                        && !map.ContainsKey(u.ToLowerInvariant()) && !u.Equals(OfflineUuid(n), StringComparison.OrdinalIgnoreCase)) o["uuid"] = OfflineUuid(n);
                File.WriteAllText(path, arr.ToJsonString(Pretty));
            }
        return carried;
    }

    // ---- mods ------------------------------------------------------------------------

    /// <summary>Mod ids that only make a Java server faster. OMNIHost doesn't need them.</summary>
    public static readonly HashSet<string> PerformanceMods =
    [
        "lithium", "ferritecore", "c2me", "c2me-fabric", "krypton", "noisium", "servercore", "starlight",
        "modernfix", "vmp", "vmp-fabric", "scalablelux", "moonrise", "spark", "memoryleakfix", "fastback",
        "chunky", "no-chat-reports", "badoptimizations", "dimthread", "async",
    ];

    /// <summary>Sorts the jars in <c>mods/</c> by what they are, from each jar's <c>fabric.mod.json</c>.</summary>
    public static ModReport ClassifyMods(string dir)
    {
        var report = new ModReport();
        var folder = Path.Combine(dir, "mods");
        if (!Directory.Exists(folder)) return report;
        foreach (var jar in Directory.EnumerateFiles(folder, "*.jar").Order(StringComparer.Ordinal))
        {
            var fallback = Path.GetFileNameWithoutExtension(jar);
            JsonObject? json = null;
            try
            {
                using var zip = ZipFile.OpenRead(jar);
                if (zip.GetEntry("fabric.mod.json") is { } e)
                {
                    using var r = new StreamReader(e.Open());
                    json = JsonNode.Parse(r.ReadToEnd()) as JsonObject;
                }
            }
            catch { }
            if (json is null) { report.Gameplay.Add(fallback); continue; }
            var id = (json["id"]?.GetValue<string>() ?? "").ToLowerInvariant();
            var name = json["name"]?.GetValue<string>() is { Length: > 0 } n ? n : fallback;
            var env = json["environment"]?.GetValue<string>() ?? "*";
            if (id.StartsWith("fabric-") || id is "fabricloader" or "fabric-api" or "java" or "minecraft") continue;   // libraries
            if (env == "client") report.ClientOnly.Add(name);
            else if (PerformanceMods.Contains(id)) report.NotNeeded.Add(name);
            else report.Gameplay.Add(name);
        }
        return report;
    }

    // ---- plan and perform ------------------------------------------------------------

    public static Plan MakePlan(string sourceDir, string name)
    {
        var props = Properties.Load(sourceDir);
        var s = SettingsFrom(props);
        var world = Path.Combine(sourceDir, s.LevelName);
        if (!File.Exists(Path.Combine(world, "level.dat")))
            throw new TransferException("No world found in this server yet (no level.dat). Start the Java server once so it creates one, then try again.");
        int Jars(string folder) => Directory.Exists(Path.Combine(sourceDir, folder)) ? Directory.EnumerateFiles(Path.Combine(sourceDir, folder), "*.jar").Count() : 0;
        var lists = ListFiles.Where(f => ReadArray(Path.Combine(sourceDir, f)) is { Count: > 0 }).ToList();
        return new Plan(name, sourceDir, s.LevelName, SizeOf(world), s, Jars("mods"), Jars("plugins"),
            File.Exists(Path.Combine(sourceDir, PumpkinConfig.IconFile)), lists, PlayerIds(world).Count, ClassifyMods(sourceDir));
    }

    /// <summary>Bytes under <paramref name="dir"/>, not counting what <see cref="SkippedInWorld"/> leaves behind.</summary>
    public static long SizeOf(string dir)
    {
        long total = 0;
        foreach (var f in Directory.EnumerateFiles(dir))
            if (!SkippedInWorld.Contains(Path.GetFileName(f))) total += new FileInfo(f).Length;
        foreach (var d in Directory.EnumerateDirectories(dir))
            if (!SkippedInWorld.Contains(Path.GetFileName(d))) total += SizeOf(d);
        return total;
    }

    /// <summary>The engine rewrites the copy in its own format (about a third bigger in a real test), so ask for room for that, plus a little for the engine's own files.</summary>
    public static long RequiredFreeBytes(Plan plan) => plan.WorldBytes * 3 / 2 + 100_000_000;

    public static long FreeBytes(string dir)
    {
        try
        {
            var probe = dir;
            while (!Directory.Exists(probe) && Path.GetDirectoryName(probe) is { Length: > 0 } up) probe = up;
            return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(probe))!).AvailableFreeSpace;
        }
        catch { return long.MaxValue; }
    }

    /// <summary>One sentence for the popup about mods and plugins.</summary>
    public static string LeftBehindSummary(Plan plan)
    {
        var m = plan.Mods;
        static string N(int c, string one, string many) => c == 1 ? $"1 {one}" : $"{c} {many}";
        var parts = new List<string>();
        if (m.Gameplay.Count > 0) parts.Add($"{N(m.Gameplay.Count, "gameplay mod stays", "gameplay mods stay")} on the Java server (they don't run on OMNIHost, so blocks, biomes or items they added may be lost or look wrong)");
        if (m.NotNeeded.Count > 0) parts.Add(N(m.NotNeeded.Count, "speed-up mod isn't", "speed-up mods aren't") + " needed");
        if (m.ClientOnly.Count > 0) parts.Add(N(m.ClientOnly.Count, "client-only mod belongs", "client-only mods belong") + " in your launcher");
        if (plan.PluginCount > 0) parts.Add(N(plan.PluginCount, "plugin stays", "plugins stay") + " behind");
        if (parts.Count == 0) parts.Add($"{plan.ModCount} mod file(s) stay behind");
        return string.Join("; ", parts) + ". A list is saved in the new server folder.";
    }

    /// <summary>A plain-text note saved next to the new server: what came along and what stayed on the Java server.</summary>
    public static string Report(Plan plan)
    {
        var l = new List<string>
        {
            $"Moved from the Java server \"{plan.Name}\" to OMNIHost.", "",
            $"Came along: world, {plan.PlayerCount} player(s) with inventory, position, stats and advancements, whitelist, ops, bans, settings, icon.",
        };
        if (plan.Mods.ClientOnly.Count > 0) { l.AddRange(["", "Client-only mods (install these in your launcher, not on the server):"]); l.AddRange(plan.Mods.ClientOnly.Select(x => "  - " + x)); }
        if (plan.Mods.NotNeeded.Count > 0) { l.AddRange(["", "Speed-up mods (OMNIHost is already fast, not needed):"]); l.AddRange(plan.Mods.NotNeeded.Select(x => "  - " + x)); }
        if (plan.Mods.Gameplay.Count > 0) { l.AddRange(["", "Mods that stay on the Java server (they do not run on OMNIHost):"]); l.AddRange(plan.Mods.Gameplay.Select(x => "  - " + x)); }
        if (plan.PluginCount > 0) l.AddRange(["", $"{plan.PluginCount} plugin(s) stay on the Java server."]);
        return string.Join("\n", l) + "\n";
    }

    /// <summary>Copies a folder tree, leaving out <see cref="SkippedInWorld"/>. Uses copy-on-write where the file system has it (Linux <c>cp --reflink=auto</c>), else plain copies.</summary>
    static async Task CopyWorldAsync(string src, string dst, CancellationToken ct)
    {
        if (OperatingSystem.IsLinux())
        {
            var r = await Proc.RunAsync("cp", ["-a", "--reflink=auto", src, dst], null, TimeSpan.FromHours(1), ct);
            if (r is { Success: true }) return;
            if (Directory.Exists(dst)) Directory.Delete(dst, recursive: true);
        }
        await Task.Run(() => CopyTree(src, dst, ct), ct);
    }

    static void CopyTree(string src, string dst, CancellationToken ct)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.EnumerateFiles(src))
        {
            ct.ThrowIfCancellationRequested();
            if (SkippedInWorld.Contains(Path.GetFileName(f))) continue;
            File.Copy(f, Path.Combine(dst, Path.GetFileName(f)));
        }
        foreach (var d in Directory.EnumerateDirectories(src))
            if (!SkippedInWorld.Contains(Path.GetFileName(d))) CopyTree(d, Path.Combine(dst, Path.GetFileName(d)), ct);
    }

    /// <summary>Builds the OMNIHost server folder at <paramref name="dest"/>. Removes it again if anything fails.</summary>
    public static async Task PerformAsync(Plan plan, string dest, long? free = null, IProgress<string>? progress = null, CancellationToken ct = default)
    {
        if (Directory.Exists(dest) || File.Exists(dest)) throw new TransferException($"A folder named \"{Path.GetFileName(dest)}\" already exists. Pick another name.");
        var available = free ?? FreeBytes(Path.GetDirectoryName(Path.GetFullPath(dest)) ?? dest);
        var needed = RequiredFreeBytes(plan);
        if (available < needed) throw new TransferException($"Not enough free space: the copy needs about {Format(needed)} and {Format(available)} is free.");
        try
        {
            Directory.CreateDirectory(dest);
            progress?.Report($"Copying the world ({Format(plan.WorldBytes)})…");
            var src = Path.Combine(plan.SourceDir, plan.LevelName);
            var target = Path.Combine(dest, plan.LevelName);
            try { await CopyWorldAsync(src, target, ct); }
            catch (Exception e) when (e is not OperationCanceledException) { throw new TransferException("Copying the world failed: " + e.Message); }
            foreach (var skip in SkippedInWorld)
            {
                var p = Path.Combine(target, skip);
                try { if (Directory.Exists(p)) Directory.Delete(p, true); else File.Delete(p); } catch { }
            }

            progress?.Report("Copying player lists…");
            var data = Path.Combine(dest, "data");
            Directory.CreateDirectory(data);
            foreach (var f in plan.Lists) File.Copy(Path.Combine(plan.SourceDir, f), Path.Combine(data, f));

            progress?.Report("Moving players (inventory, position, advancements)…");
            CarryPlayers(plan.SourceDir, target, data, plan.Settings.OnlineMode);

            progress?.Report("Writing settings…");
            if (plan.HasIcon) File.Copy(Path.Combine(plan.SourceDir, PumpkinConfig.IconFile), Path.Combine(dest, PumpkinConfig.IconFile));
            else OmniHostAdapter.InstallIcon(dest);
            File.WriteAllText(Path.Combine(dest, "OMNIHost-transfer.txt"), Report(plan));
            File.WriteAllText(Path.Combine(dest, PumpkinConfig.FileName), PumpkinConfig.Render(plan.Settings));
        }
        catch
        {
            try { if (Directory.Exists(dest)) Directory.Delete(dest, true); } catch { }
            throw;
        }
    }
}
