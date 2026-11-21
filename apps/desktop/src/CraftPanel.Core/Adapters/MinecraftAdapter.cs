namespace CraftPanel.Core.Adapters;

public enum ServerStatus { Stopped, Starting, Running, Stopping, Crashed, Unknown }

public sealed record MinecraftDetection(ServerType ServerType, string LaunchTarget, string? McVersion, IReadOnlyList<string> Evidence);

/// <summary>What to run: program, arguments and working directory.</summary>
public sealed record LaunchSpec(string FileName, IReadOnlyList<string> Args, string WorkingDirectory);

/// <summary>Everything the adapter needs to build a launch command.</summary>
public sealed record ServerConfig(string Path, string LaunchTarget, string JavaPath, uint RamMB, ServerType ServerType, string? JvmArgs);

/// <summary>
/// Minecraft (Java Edition) detection and launch. Detection precedence is load-bearing: Fabric/Quilt must
/// win over a bare <c>server.jar</c> (a Fabric install keeps the vanilla jar next to its launcher).
/// </summary>
public static class MinecraftAdapter
{
    // ---- detection ------------------------------------------------------------------

    public static MinecraftDetection? Inspect(string path)
    {
        var entries = ListFiles(path);
        bool Has(string n) => entries.Any(e => e.Equals(n, StringComparison.OrdinalIgnoreCase));
        string? Glob(string prefix, string suffix) => entries.FirstOrDefault(e => { var l = e.ToLowerInvariant(); return l.StartsWith(prefix) && l.EndsWith(suffix); });
        bool Dir(string rel) => Directory.Exists(System.IO.Path.Combine(path, rel));
        var evidence = new List<string>();

        // Fabric / Quilt — must run before the generic server.jar check.
        var launchJar = Has("fabric-server-launch.jar") ? "fabric-server-launch.jar"
            : Has("quilt-server-launch.jar") ? "quilt-server-launch.jar"
            : Glob("fabric-server", ".jar") ?? Glob("quilt-server", ".jar");
        var props = Has("fabric-server-launcher.properties");
        var fabricDir = Dir(".fabric") || Dir(".quilt");
        var fabricLibs = Dir("libraries/net/fabricmc") || Dir("libraries/org/quiltmc");
        if (launchJar is not null || props || fabricDir || fabricLibs)
        {
            if (launchJar is not null) evidence.Add(launchJar);
            if (props) evidence.Add("fabric-server-launcher.properties");
            if (fabricDir) evidence.Add(".fabric/");
            if (fabricLibs) evidence.Add("libraries/net/fabricmc");
            return new(ServerType.Fabric, launchJar ?? "fabric-server-launch.jar", DetectVersion(path, entries), evidence);
        }

        // Forge / NeoForge
        var hasRun = Has("run.sh") || Has("run.bat");
        var forgeJar = Glob("forge-", ".jar") ?? Glob("neoforge-", ".jar");
        var forgeLibs = Dir("libraries/net/minecraftforge") || Dir("libraries/net/neoforged");
        if (hasRun || forgeJar is not null || forgeLibs)
        {
            var target = Platform.IsWindows
                ? (Has("run.bat") ? "run.bat" : Has("run.sh") ? "run.sh" : forgeJar ?? "run.bat")
                : (Has("run.sh") ? "run.sh" : Has("run.bat") ? "run.bat" : forgeJar ?? "run.sh");
            if (hasRun) evidence.Add("run script");
            if (forgeJar is not null) evidence.Add(forgeJar);
            if (forgeLibs) evidence.Add("libraries/net/minecraftforge");
            var isNeo = Glob("neoforge-", ".jar") is not null || Dir("libraries/net/neoforged");
            return new(isNeo ? ServerType.NeoForge : ServerType.Forge, target, DetectVersion(path, entries), evidence);
        }

        // Paper
        if (JarMatching(entries, "paper") is { } paper)
            return new(ServerType.Paper, paper, DetectVersion(path, entries), [paper]);

        // Spigot / Bukkit / CraftBukkit
        foreach (var key in new[] { "spigot", "craftbukkit", "bukkit" })
            if (JarMatching(entries, key) is { } jar)
                return new(ServerType.Spigot, jar, DetectVersion(path, entries), [jar]);

        // Vanilla / generic
        if (Has("server.jar")) return new(ServerType.Vanilla, "server.jar", DetectVersion(path, entries), ["server.jar"]);
        var jars = entries.Where(e => e.EndsWith(".jar", StringComparison.OrdinalIgnoreCase)).ToList();
        if (jars.Count == 1) return new(ServerType.Vanilla, jars[0], DetectVersion(path, entries), [jars[0]]);
        return null;
    }

    public static ServerType? Detect(string path) => Inspect(path)?.ServerType;

    // ---- launch ---------------------------------------------------------------------

    /// <summary>
    /// Start with a small heap and grow on demand: <c>-Xms</c> equal to <c>-Xmx</c> makes Java claim the whole
    /// allocation from the OS at launch even with nobody online. <c>-Xmx</c> stays the cap.
    /// </summary>
    public static uint InitialHeapMB(uint ramMB) => Math.Min(ramMB, 1024);

    public static LaunchSpec StartCommand(ServerConfig c)
    {
        if (c.ServerType.IsBedrock()) return new(System.IO.Path.Combine(c.Path, BedrockAdapter.BinaryName), [], c.Path);

        var java = ResolveJava(c.JavaPath);
        if (c.ServerType.IsForgeFamily() && ForgeArgsFile(c.Path) is { } argFile)
            return new(java, ["@user_jvm_args.txt", "@" + argFile, "nogui"], c.Path);

        var target = c.LaunchTarget;
        if (target.EndsWith(".sh", StringComparison.OrdinalIgnoreCase) || target.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
        {
            // Legacy Forge (pre-1.17): no args file; run the server jar directly.
            target = ListFiles(c.Path).FirstOrDefault(f => f.EndsWith(".jar", StringComparison.OrdinalIgnoreCase)
                && (f.Contains("forge", StringComparison.OrdinalIgnoreCase)) && !f.Contains("installer", StringComparison.OrdinalIgnoreCase))
                ?? throw new ProvisionException("This Forge server has no launcher jar or args file — reinstall it or pick its start jar in Settings.");
        }
        var args = new List<string> { $"-Xms{InitialHeapMB(c.RamMB)}M", $"-Xmx{c.RamMB}M" };
        args.AddRange(JvmArgTokens(c.JvmArgs));
        args.AddRange(["-jar", target, "nogui"]);
        return new(java, args, c.Path);
    }

    /// <summary>Whitespace-split extra JVM flags, keeping only tokens that look like flags.</summary>
    public static IEnumerable<string> JvmArgTokens(string? jvmArgs) =>
        (jvmArgs ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Where(t => t.StartsWith('-'));

    /// <summary>Path (forward slashes, relative to the server dir) to the platform args file in a modern Forge/NeoForge install.</summary>
    public static string? ForgeArgsFile(string dir)
    {
        var file = Platform.IsWindows ? "win_args.txt" : "unix_args.txt";
        foreach (var b in new[] { "libraries/net/minecraftforge/forge", "libraries/net/neoforged/neoforge" })
        {
            var root = System.IO.Path.Combine(dir, b);
            if (!Directory.Exists(root)) continue;
            foreach (var entry in Directory.EnumerateDirectories(root))
                if (File.Exists(System.IO.Path.Combine(entry, file)))
                    return $"{b}/{System.IO.Path.GetFileName(entry)}/{file}";
        }
        return null;
    }

    /// <summary>
    /// Forge args files read JVM flags from <c>user_jvm_args.txt</c>, not argv: strip any heap/extra flags we wrote
    /// before, keep everything else the user (or the installer) put there, re-append fresh ones.
    /// </summary>
    public static void EnsureUserJvmArgs(ServerConfig c)
    {
        if (!c.ServerType.IsForgeFamily() || ForgeArgsFile(c.Path) is null) return;
        var path = System.IO.Path.Combine(c.Path, "user_jvm_args.txt");
        var existing = File.Exists(path) ? File.ReadAllText(path) : "";
        var extra = JvmArgTokens(c.JvmArgs).ToList();
        var kept = existing.Split('\n').Select(l => l.TrimEnd('\r')).Where(l =>
        {
            var t = l.TrimStart(' ', '\t');
            return !t.StartsWith("-Xmx") && !t.StartsWith("-Xms") && !extra.Contains(t.Trim());
        });
        var text = string.Join("\n", kept).TrimEnd('\n');
        if (text.Length > 0) text += "\n";
        text += $"-Xms{InitialHeapMB(c.RamMB)}M\n-Xmx{c.RamMB}M\n";
        foreach (var t in extra) text += t + "\n";
        File.WriteAllText(path, text);
    }

    static string ResolveJava(string java)
    {
        if (string.IsNullOrWhiteSpace(java)) java = "java";
        return java;
    }

    // ---- console parsing ------------------------------------------------------------

    public static ServerStatus ParseStatus(string output)
    {
        var o = output.ToLowerInvariant();
        if (o.Contains("done (") && o.Contains("for help")) return ServerStatus.Running;
        if (o.Contains("starting minecraft server") || o.Contains("loading properties")) return ServerStatus.Starting;
        if (o.Contains("stopping the server") || o.Contains("stopping server")) return ServerStatus.Stopping;
        if (o.Contains("exception in server tick loop") || o.Contains("failed to start")) return ServerStatus.Crashed;
        return ServerStatus.Unknown;
    }

    // ---- helpers --------------------------------------------------------------------

    static string[] ListFiles(string path)
    {
        try { return Directory.EnumerateFileSystemEntries(path).Select(System.IO.Path.GetFileName).Where(n => n is not null).Cast<string>().ToArray(); }
        catch { return []; }
    }

    static string? JarMatching(string[] entries, string key) =>
        entries.FirstOrDefault(e => { var l = e.ToLowerInvariant(); return l.EndsWith(".jar") && l.Contains(key); });

    static string? DetectVersion(string path, string[] entries)
    {
        try
        {
            var vh = System.IO.Path.Combine(path, "version_history.json");
            if (File.Exists(vh) && ExtractMcParen(File.ReadAllText(vh)) is { } v1) return v1;
            var fl = System.IO.Path.Combine(path, "fabric-server-launcher.properties");
            if (File.Exists(fl))
                foreach (var line in File.ReadLines(fl))
                    if (line.StartsWith("serverJar=") && ExtractVersionToken(line["serverJar=".Length..]) is { } v2) return v2;
            foreach (var e in entries) if (ExtractVersionToken(e) is { } v3) return v3;
            var libs = System.IO.Path.Combine(path, "libraries", "net", "minecraft", "server");
            if (Directory.Exists(libs))
                foreach (var d in Directory.EnumerateDirectories(libs)) if (ExtractVersionToken(System.IO.Path.GetFileName(d)) is { } v4) return v4;
            var versions = System.IO.Path.Combine(path, "versions");
            if (Directory.Exists(versions))
                foreach (var d in Directory.EnumerateDirectories(versions)) if (IsMcVersion(System.IO.Path.GetFileName(d))) return System.IO.Path.GetFileName(d);
        }
        catch { }
        return null;
    }

    static string? ExtractMcParen(string text)
    {
        var i = text.IndexOf("(MC:", StringComparison.Ordinal);
        if (i < 0) return null;
        var tail = text[(i + 4)..];
        var end = tail.IndexOf(')');
        if (end < 0) return null;
        var v = tail[..end].Trim();
        return v.Length == 0 ? null : v;
    }

    public static string? ExtractVersionToken(string s)
    {
        var i = 0;
        while (i < s.Length)
        {
            if (char.IsAsciiDigit(s[i]) && (i == 0 || !char.IsAsciiDigit(s[i - 1])))
            {
                var j = i;
                while (j < s.Length && (char.IsAsciiDigit(s[j]) || s[j] == '.')) j++;
                var tok = s[i..j].TrimEnd('.');
                if (IsMcVersion(tok)) return tok;
                i = j;
            }
            else i++;
        }
        return null;
    }

    public static bool IsMcVersion(string tok)
    {
        var parts = tok.Split('.');
        if (parts.Length is < 2 or > 3) return false;
        if (!parts.All(p => p.Length > 0 && p.All(char.IsAsciiDigit))) return false;
        var major = int.Parse(parts[0]);
        return major == 1 || major is >= 20 and <= 99;
    }
}

public static class BedrockAdapter
{
    public static string BinaryName => Platform.IsWindows ? "bedrock_server.exe" : "bedrock_server";
    public static bool IsPlatformSupported => !Platform.IsMac;

    public static string? Inspect(string path) => File.Exists(System.IO.Path.Combine(path, BinaryName)) ? BinaryName : null;

    public static ServerStatus ParseStatus(string text)
    {
        var o = text.ToLowerInvariant();
        if (o.Contains("server started.")) return ServerStatus.Running;
        if (o.Contains("stopping server")) return ServerStatus.Stopping;
        return ServerStatus.Unknown;
    }
}

/// <summary>Aikar's flags (heap flags come from the RAM setting). No AlwaysPreTouch: it fills the whole heap at launch.</summary>
public static class JvmArgs
{
    public static string AikarFlags(uint ramMB)
    {
        var big = ramMB >= 12_288;
        return "-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC "
            + $"-XX:G1NewSizePercent={(big ? 40 : 30)} -XX:G1MaxNewSizePercent={(big ? 50 : 40)} -XX:G1HeapRegionSize={(big ? "16M" : "8M")} "
            + $"-XX:G1ReservePercent={(big ? 15 : 20)} -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 "
            + $"-XX:InitiatingHeapOccupancyPercent={(big ? 20 : 15)} -XX:G1MixedGCLiveThresholdPercent=90 "
            + "-XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem "
            + "-XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true";
    }

    public static string Describe(ServerRecord r)
    {
        var spec = MinecraftAdapter.StartCommand(new(r.Path, r.LaunchTarget, r.JavaPath, r.RamMB, r.ServerType, Network.CrossplayManager.LaunchJvmArgs(r.Path, r.ServerType, r.JvmArgs)));
        return spec.FileName + " " + string.Join(" ", spec.Args);
    }
}
