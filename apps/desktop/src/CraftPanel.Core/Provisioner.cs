using System.Text.Json.Nodes;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Java;

namespace CraftPanel.Core;

public enum Loader { Vanilla, Paper, Fabric, NeoForge, Forge, Bedrock }

public static class LoaderExt
{
    public static ServerType ServerType(this Loader l) => l switch
    {
        Loader.Vanilla => Core.ServerType.Vanilla, Loader.Paper => Core.ServerType.Paper, Loader.Fabric => Core.ServerType.Fabric,
        Loader.NeoForge => Core.ServerType.NeoForge, Loader.Bedrock => Core.ServerType.Bedrock, _ => Core.ServerType.Forge,
    };
    public static string Label(this Loader l) => l == Loader.NeoForge ? "NeoForge" : l.ToString();
}

public sealed record VersionInfo(string Id, string Kind);

public sealed record CreateSpec(Loader Loader, string McVersion, string? LoaderVersion, string Dir, string Name, uint RamMB, string? JavaPath);

public sealed record Created(ServerType ServerType, string LaunchTarget, string McVersion, string Dir, string JavaPath);

/// <summary>Creates servers: version lists, verified downloads, loader installers, first boot.</summary>
public static class Provisioner
{
    // ---- version lists ---------------------------------------------------------------

    public static async Task<List<VersionInfo>> ListVersionsAsync(Loader loader, CancellationToken ct = default) => loader switch
    {
        Loader.Vanilla => await MojangVersions(ct),
        Loader.Paper => await PaperVersions(ct),
        Loader.Fabric => await FabricGameVersions(ct),
        Loader.NeoForge => await NeoForgeVersions(ct),
        Loader.Bedrock => await BedrockVersions(ct),
        _ => await ForgeVersions(ct),
    };

    static async Task<List<VersionInfo>> MojangVersions(CancellationToken ct)
    {
        var j = await Http.GetJsonAsync("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json", ct);
        return j["versions"]!.AsArray().Select(v => new VersionInfo(v!["id"]!.GetValue<string>(), v["type"]?.GetValue<string>() ?? "release")).ToList();
    }

    static async Task<List<VersionInfo>> PaperVersions(CancellationToken ct)
    {
        var j = await Http.GetJsonAsync("https://fill.papermc.io/v3/projects/paper", ct);
        var list = new List<VersionInfo>();
        foreach (var (_, arr) in j["versions"]!.AsObject())
            foreach (var s in arr!.AsArray()) { var id = s!.GetValue<string>(); list.Add(new(id, id.Contains('-') ? "snapshot" : "release")); }
        return list.OrderByDescending(v => VersionSortKey(v.Id)).ToList();
    }

    static async Task<List<VersionInfo>> FabricGameVersions(CancellationToken ct)
    {
        var j = await Http.GetJsonAsync("https://meta.fabricmc.net/v2/versions/game", ct);
        return j.AsArray().Select(v => new VersionInfo(v!["version"]!.GetValue<string>(), v["stable"]?.GetValue<bool>() == true ? "release" : "snapshot")).ToList();
    }

    static async Task<List<VersionInfo>> NeoForgeVersions(CancellationToken ct)
    {
        var j = await Http.GetJsonAsync("https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge", ct);
        return j["versions"]!.AsArray().Select(v => v!.GetValue<string>()).Reverse().Select(s => new VersionInfo(s, s.Contains("beta") ? "beta" : "release")).ToList();
    }

    static async Task<List<VersionInfo>> ForgeVersions(CancellationToken ct)
    {
        var j = await Http.GetJsonAsync("https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json", ct);
        var list = new List<VersionInfo>();
        foreach (var (k, v) in j["promos"]!.AsObject())
        {
            var rec = k.EndsWith("-recommended");
            if (!rec && !k.EndsWith("-latest")) continue;
            var mc = k[..k.LastIndexOf('-')];
            list.Add(new($"{mc}-{v!.GetValue<string>()}", rec ? "release" : "beta"));
        }
        return list.OrderByDescending(v => VersionSortKey(v.Id)).ToList();
    }

    static Version VersionSortKey(string id)
    {
        var digits = new string(id.TakeWhile(c => char.IsAsciiDigit(c) || c == '.').ToArray()).Trim('.');
        return Version.TryParse(digits.Contains('.') ? digits : digits + ".0", out var v) ? v : new Version(0, 0);
    }

    /// <summary>
    /// Forge "1.20.1-47.2.0" → "1.20.1". NeoForge 20.x/21.x are Minecraft 1.20.x/1.21.x ("21.0.x" is plain 1.21);
    /// the year scheme (26.x on) is the Minecraft version itself; anything else (snapshots) is left as is.
    /// </summary>
    public static string DeriveMcVersion(Loader loader, string versionId)
    {
        if (loader == Loader.Forge) return versionId.Split('-', 2)[0];
        if (loader != Loader.NeoForge) return versionId;
        var p = versionId.Split('.');
        if (p.Length < 2 || !int.TryParse(p[0], out var a) || !int.TryParse(p[1], out var b)) return versionId;
        if (a >= 26) return $"{a}.{b}";
        if (a >= 20) return b == 0 ? $"1.{a}" : $"1.{a}.{b}";
        return versionId;
    }

    // ---- Bedrock Dedicated Server (Windows and Linux; Mojang ships no macOS build) ----

    public const string BedrockLinksUrl = "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links";

    /// <summary>The Bedrock Dedicated Server downloads for this OS from Mojang's links JSON: stable first, then the preview.</summary>
    public static List<(string Version, string Url, bool Preview)> ParseBedrockLinks(System.Text.Json.Nodes.JsonNode json, bool windows)
    {
        var os = windows ? "Windows" : "Linux";
        var found = new List<(string, string, bool)>();
        foreach (var l in json["result"]?["links"]?.AsArray() ?? [])
        {
            var type = l?["downloadType"]?.GetValue<string>(); var url = l?["downloadUrl"]?.GetValue<string>();
            if (url is null || type is null) continue;
            var preview = type == $"serverBedrockPreview{os}";
            if (type != $"serverBedrock{os}" && !preview) continue;
            var m = System.Text.RegularExpressions.Regex.Match(url, @"bedrock-server-([\d.]+)\.zip$");
            if (m.Success) found.Add((m.Groups[1].Value, url, preview));
        }
        return found.OrderBy(f => f.Item3).ToList();
    }

    static async Task<List<VersionInfo>> BedrockVersions(CancellationToken ct)
    {
        if (OperatingSystem.IsMacOS()) throw new ProvisionException("Mojang doesn't make a Bedrock server for macOS. Run it on Windows or Linux, or add Bedrock players to a Java server with Geyser.");
        var links = ParseBedrockLinks(await Http.GetJsonAsync(BedrockLinksUrl, ct), OperatingSystem.IsWindows());
        return links.Select(l => new VersionInfo(l.Version, l.Preview ? "snapshot" : "release")).ToList();
    }

    static async Task<Created> CreateBedrockAsync(CreateSpec spec, string dir, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        if (OperatingSystem.IsMacOS()) throw new ProvisionException("Mojang doesn't make a Bedrock server for macOS. Run it on Windows or Linux, or add Bedrock players to a Java server with Geyser.");
        var links = ParseBedrockLinks(await Http.GetJsonAsync(BedrockLinksUrl, ct), OperatingSystem.IsWindows());
        var pick = links.FirstOrDefault(l => l.Version == spec.McVersion);
        if (pick.Url is null) throw new ProvisionException($"Bedrock server {spec.McVersion} isn't available for download any more. Pick the newest version.");
        var zip = Path.Combine(dir, "bedrock-server.zip");
        await Http.DownloadAsync(pick.Url, zip, "Bedrock Dedicated Server", progress, ct);
        progress?.Report(new("unpack", "Unpacking the server", null));
        System.IO.Compression.ZipFile.ExtractToDirectory(zip, dir, overwriteFiles: true);   // rejects paths that escape dir
        File.Delete(zip);
        var bin = Path.Combine(dir, BedrockAdapter.BinaryName);
        if (!File.Exists(bin)) throw new ProvisionException("The download didn't contain the Bedrock server program.");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(bin, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
        return new(ServerType.Bedrock, BedrockAdapter.BinaryName, spec.McVersion, dir, "");
    }

    /// <summary>First free UDP-friendly Bedrock port from 19132 up that no other server uses.</summary>
    public static int? PickFreeBedrockPort(ISet<int> taken)
    {
        for (var p = 19132; p < 19232; p++) if (!taken.Contains(p) && Net.PortFree(p)) return p;
        return null;
    }

    // ---- creation --------------------------------------------------------------------

    public static async Task<Created> CreateAsync(CreateSpec spec, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        var dir = spec.Dir;
        Directory.CreateDirectory(dir);
        if (Directory.EnumerateFileSystemEntries(dir).Any())
            throw new ProvisionException("That folder isn't empty — pick a fresh folder for a new server.");
        if (spec.Loader == Loader.Bedrock) return await CreateBedrockAsync(spec, dir, progress, ct);

        var need = JavaProbe.RequiredJava(spec.McVersion);
        var java = await EnsureJavaAsync(string.IsNullOrWhiteSpace(spec.JavaPath) ? "java" : spec.JavaPath!, need, spec.McVersion, progress, ct);

        string launch;
        switch (spec.Loader)
        {
            case Loader.Vanilla: launch = await DownloadVanilla(spec, dir, progress, ct); break;
            case Loader.Paper: launch = await DownloadPaper(spec, dir, progress, ct); break;
            case Loader.Fabric: launch = await DownloadFabric(spec, dir, progress, ct); break;
            default: launch = await RunInstaller(spec, dir, java, progress, ct); break;
        }
        var type = spec.Loader.ServerType();

        progress?.Report(new("eula", "Accepting the Minecraft EULA", null));
        File.WriteAllText(Path.Combine(dir, "eula.txt"), "# Accepted via OMNIServers — https://aka.ms/MinecraftEULA\neula=true\n");

        await FirstBootAsync(spec, dir, java, launch, type, progress, ct);
        return new(type, launch, spec.McVersion, dir, java);
    }

    /// <summary>The configured Java if new enough; else a matching installed JDK; else a verified Temurin download.</summary>
    public static async Task<string> EnsureJavaAsync(string java, uint need, string mcVersion, IProgress<ProvisionProgress>? progress, CancellationToken ct = default)
    {
        if (await JavaProbe.ProbeAsync(java, ct) is { } cur && cur.Major >= need) return java;
        if (await JavaProbe.FindCompatibleAsync(need, ct) is { } found)
        {
            progress?.Report(new("java", $"Using the installed Java {need}+ runtime for Minecraft {mcVersion}.", null));
            return found;
        }
        if (JavaInstaller.OfferableFeature(need) is not { } f)
            throw new ProvisionException($"Minecraft {mcVersion} needs Java {need}, which isn't installed and can't be auto-installed.");
        progress?.Report(new("java", $"Installing Java {f} (needed for Minecraft {mcVersion})…", null));
        return (await JavaInstaller.InstallAsync(f, progress, ct)).Path;
    }

    // ---- starting settings -----------------------------------------------------------

    /// <summary>First free port in 25565..25664 not used by another server and actually bindable.</summary>
    public static int? PickFreePort(ISet<int> taken)
    {
        for (var p = 25565; p < 25665; p++) if (!taken.Contains(p) && Net.PortFree(p)) return p;
        return null;
    }

    /// <summary>Line-preserving; never touches online-mode.</summary>
    public static void ApplyStartingSettings(string dir, bool bedrock, int? port, string? seed, string? gamemode, string? difficulty, string? motd, int? maxPlayers)
    {
        if (!File.Exists(Path.Combine(dir, "server.properties"))) return;
        var p = Properties.Load(dir);
        if (port is { } pt)
        {
            p.Set("server-port", pt.ToString());
            if (!bedrock) { p.Set("query.port", pt.ToString()); p.Set("rcon.port", (pt + 10).ToString()); }
        }
        if (seed?.Trim() is { Length: > 0 } s) p.Set("level-seed", s);
        if (gamemode is "survival" or "creative" or "adventure" or "spectator") p.Set("gamemode", gamemode);
        if (difficulty is "peaceful" or "easy" or "normal" or "hard") p.Set("difficulty", difficulty);
        if (motd?.Trim() is { Length: > 0 } m && !m.Contains('\n')) p.Set(bedrock ? "server-name" : "motd", m);
        if (maxPlayers is >= 1 and <= 1000) p.Set("max-players", maxPlayers.Value.ToString());
        if (bedrock) Network.BedrockNetwork.ApplyNewBdsDefaults(p, port ?? p.GetInt("server-port", 19132));
        p.Save();
    }

    // ---- change version --------------------------------------------------------------

    /// <summary>
    /// Swaps a server's jar/loader in place (world, mods, configs untouched). Downloads into a staging folder first and
    /// only then moves the old launcher aside, so a failed download leaves the server runnable.
    /// </summary>
    public static async Task<Created> ChangeVersionAsync(string dir, string oldLaunchTarget, Loader loader, string mcVersion, string? loaderVersion,
        string javaPath, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        if (loader is Loader.Forge or Loader.NeoForge)
            throw new ProvisionException("Changing to Forge or NeoForge isn't supported — create a new server for that.");
        if (!Directory.Exists(dir)) throw new ProvisionException("Server folder not found.");
        var staging = Path.Combine(dir, ".craftpanel-staging-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        Directory.CreateDirectory(staging);
        try
        {
            var spec = new CreateSpec(loader, mcVersion, loaderVersion, staging, "", 0, javaPath);
            var target = loader switch
            {
                Loader.Vanilla => await DownloadVanilla(spec, staging, progress, ct),
                Loader.Paper => await DownloadPaper(spec, staging, progress, ct),
                _ => await DownloadFabric(spec, staging, progress, ct),
            };
            var trash = Path.Combine(dir, ".craftpanel-trash");
            foreach (var old in new[] { oldLaunchTarget, target }.Distinct())
            {
                var p = Path.Combine(dir, old);
                if (Path.GetFileName(old) == old && File.Exists(p)) FileOps.MoveToTrash(p, trash);
            }
            File.Move(Path.Combine(staging, target), Path.Combine(dir, target));
            progress?.Report(new("done", $"Switched to {loader.Label()} {mcVersion}", 100));
            return new(loader.ServerType(), target, mcVersion, dir, javaPath);
        }
        finally { try { Directory.Delete(staging, true); } catch { } }
    }

    // ---- downloads -------------------------------------------------------------------

    internal static async Task<string> DownloadVanilla(CreateSpec spec, string dir, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        var manifest = await Http.GetJsonAsync("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json", ct);
        var entry = manifest["versions"]!.AsArray().FirstOrDefault(v => v!["id"]!.GetValue<string>() == spec.McVersion)
            ?? throw new ProvisionException($"Minecraft {spec.McVersion} not found");
        var pkg = await Http.GetJsonAsync(entry["url"]!.GetValue<string>(), ct);
        var server = pkg["downloads"]?["server"] ?? throw new ProvisionException("this version has no server download");
        var dest = Path.Combine(dir, "server.jar");
        await Http.DownloadAsync(server["url"]!.GetValue<string>(), dest, "Minecraft server", progress, ct);
        if (server["sha1"]?.GetValue<string>() is { Length: > 0 } want)
        {
            progress?.Report(new("verify", "Verifying checksum", null));
            var got = Http.Sha1Hex(dest);
            if (!got.Equals(want, StringComparison.OrdinalIgnoreCase)) { File.Delete(dest); throw new ProvisionException($"checksum mismatch (sha1 {got} != {want})"); }
        }
        return "server.jar";
    }

    internal static async Task<string> DownloadPaper(CreateSpec spec, string dir, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        var builds = (await Http.GetJsonAsync($"https://fill.papermc.io/v3/projects/paper/versions/{spec.McVersion}/builds", ct)).AsArray();
        if (builds.Count == 0) throw new ProvisionException("no builds");
        var build = builds.FirstOrDefault(b => b!["channel"]?.GetValue<string>() == "STABLE") ?? builds[0]!;
        var dl = build["downloads"]?["server:default"] ?? throw new ProvisionException("no download url");
        var name = dl["name"]?.GetValue<string>() ?? "paper.jar";
        if (name != Path.GetFileName(name)) throw new ProvisionException("unsafe file name from server");
        var dest = Path.Combine(dir, name);
        await Http.DownloadAsync(dl["url"]!.GetValue<string>(), dest, name, progress, ct);
        if (dl["checksums"]?["sha256"]?.GetValue<string>() is { Length: > 0 } want)
        {
            progress?.Report(new("verify", "Verifying checksum", null));
            var got = Http.Sha256Hex(dest);
            if (!got.Equals(want, StringComparison.OrdinalIgnoreCase)) { File.Delete(dest); throw new ProvisionException($"checksum mismatch (sha256 {got} != {want})"); }
        }
        return name;
    }

    internal static async Task<string> DownloadFabric(CreateSpec spec, string dir, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        string loaderVersion;
        if (spec.LoaderVersion is { } pinned) loaderVersion = pinned;
        else
        {
            var arr = (await Http.GetJsonAsync("https://meta.fabricmc.net/v2/versions/loader", ct)).AsArray();
            loaderVersion = (arr.FirstOrDefault(l => l!["stable"]?.GetValue<bool>() == true) ?? arr.FirstOrDefault())?["version"]?.GetValue<string>()
                ?? throw new ProvisionException("no fabric loader");
        }
        var iarr = (await Http.GetJsonAsync("https://meta.fabricmc.net/v2/versions/installer", ct)).AsArray();
        var installer = (iarr.FirstOrDefault(l => l!["stable"]?.GetValue<bool>() == true) ?? iarr.FirstOrDefault())?["version"]?.GetValue<string>()
            ?? throw new ProvisionException("no fabric installer");
        var url = $"https://meta.fabricmc.net/v2/versions/loader/{spec.McVersion}/{loaderVersion}/{installer}/server/jar";
        await Http.DownloadAsync(url, Path.Combine(dir, "fabric-server-launch.jar"), "Fabric server launcher", progress, ct);
        return "fabric-server-launch.jar";
    }

    internal static async Task<string> RunInstaller(CreateSpec spec, string dir, string java, IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        var ver = spec.LoaderVersion ?? throw new ProvisionException("pick a loader version for NeoForge/Forge");
        string url, name, flag;
        if (spec.Loader == Loader.NeoForge)
        {
            url = $"https://maven.neoforged.net/releases/net/neoforged/neoforge/{ver}/neoforge-{ver}-installer.jar";
            name = $"neoforge-{ver}-installer.jar"; flag = "--install-server";
        }
        else
        {
            url = $"https://maven.minecraftforge.net/net/minecraftforge/forge/{ver}/forge-{ver}-installer.jar";
            name = $"forge-{ver}-installer.jar"; flag = "--installServer";
        }
        await Http.DownloadAsync(url, Path.Combine(dir, name), name, progress, ct);
        progress?.Report(new("install", "Running the loader installer (this takes a minute)…", null));
        var r = await Proc.RunAsync(java, ["-jar", name, flag], dir, TimeSpan.FromMinutes(20), ct)
            ?? throw new ProvisionException("couldn't run the installer: Java wasn't found");
        if (r.TimedOut) throw new ProvisionException("installer took longer than 20 minutes and was stopped");
        if (!r.Success) throw new ProvisionException("installer failed:\n" + (r.StdErr.Length > 0 ? r.StdErr : r.StdOut)[..Math.Min(800, (r.StdErr.Length > 0 ? r.StdErr : r.StdOut).Length)]);
        try { File.Delete(Path.Combine(dir, name)); File.Delete(Path.Combine(dir, name + ".log")); } catch { }

        if (MinecraftAdapter.ForgeArgsFile(dir) is not null)
            return Platform.IsWindows ? "run.bat" : "run.sh";   // StartCommand resolves the args file itself
        if (File.Exists(Path.Combine(dir, "run.bat")) || File.Exists(Path.Combine(dir, "run.sh")))
            return File.Exists(Path.Combine(dir, "run.bat")) && Platform.IsWindows ? "run.bat" : "run.sh";
        var legacy = Directory.EnumerateFiles(dir, "forge-*.jar").FirstOrDefault(f => !f.Contains("installer"));
        if (legacy is not null) return Path.GetFileName(legacy);
        throw new ProvisionException("installer finished but produced no run script or args file");
    }

    // ---- first boot ------------------------------------------------------------------

    internal static async Task FirstBootAsync(CreateSpec spec, string dir, string java, string launch, ServerType type,
        IProgress<ProvisionProgress>? progress, CancellationToken ct)
    {
        progress?.Report(new("firstboot", "Starting the server once to generate its config…", null));
        var config = new ServerConfig(dir, launch, java, Math.Min(spec.RamMB, 2048), type, null);   // first boot is light
        MinecraftAdapter.EnsureUserJvmArgs(config);
        var run = MinecraftAdapter.StartCommand(config);
        using var boot = new BootProcess(run);
        boot.Start();

        var deadline = DateTime.UtcNow.AddSeconds(240);
        var ready = false;
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            if (boot.Ready) { ready = true; break; }
            if (boot.EulaBlocked || boot.HasExited) break;
            await Task.Delay(500, ct);
        }
        var exited = false;
        if (ready)
        {
            boot.Send("stop");
            for (var i = 0; i < 180 && !boot.HasExited; i++) await Task.Delay(500, ct);
            exited = boot.HasExited;
        }
        if (!exited) boot.Kill();

        var level = Properties.Load(dir).GetOr("level-name", "world");
        try { File.Delete(Path.Combine(dir, level, "session.lock")); } catch { }
        await Task.Delay(400, ct);
        if (!File.Exists(Path.Combine(dir, "server.properties")))
            throw new ProvisionException("first boot didn't generate server.properties — the Java version may be too old for this Minecraft version");
        progress?.Report(new("done", "Server ready", 100));
    }

    /// <summary>A short-lived server process for first boot: watches output for "Done (" / the EULA notice.</summary>
    sealed class BootProcess(LaunchSpec spec) : IDisposable
    {
        readonly System.Diagnostics.Process _p = new()
        {
            StartInfo = new(spec.FileName)
            {
                WorkingDirectory = spec.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            },
        };
        public volatile bool Ready, EulaBlocked;
        public bool HasExited => _p.HasExited;

        public void Start()
        {
            foreach (var a in spec.Args) _p.StartInfo.ArgumentList.Add(a);
            _p.OutputDataReceived += (_, e) => Observe(e.Data);
            _p.ErrorDataReceived += (_, e) => Observe(e.Data);   // drained so a chatty JVM can't stall
            try { _p.Start(); }
            catch (Exception e) { throw new ProvisionException($"couldn't start Java: {e.Message}", e); }
            _p.BeginOutputReadLine(); _p.BeginErrorReadLine();
        }

        void Observe(string? line)
        {
            if (line is null) return;
            if (line.Contains("Done (") && line.Contains("For help", StringComparison.OrdinalIgnoreCase)) Ready = true;
            if (line.Contains("agree to the EULA", StringComparison.OrdinalIgnoreCase)) EulaBlocked = true;
        }

        public void Send(string s) { try { _p.StandardInput.WriteLine(s); _p.StandardInput.Flush(); } catch { } }
        public void Kill() { try { _p.Kill(entireProcessTree: true); _p.WaitForExit(5000); } catch { } }
        public void Dispose() => _p.Dispose();
    }
}
