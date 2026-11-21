using System.Text.RegularExpressions;

namespace CraftPanel.Core.Adapters;

/// <summary>OMNIHost servers run on PumpkinMC (see <see cref="PumpkinEngine"/>): one native binary, no Java.</summary>
public static class OmniHostAdapter
{
    /// <summary>The folder is an OMNIHost server when it has Pumpkin's <c>pumpkin.toml</c> (or the older <c>omnihost.toml</c>).</summary>
    public static bool IsServerFolder(string dir) =>
        File.Exists(Path.Combine(dir, PumpkinConfig.FileName)) || File.Exists(Path.Combine(dir, "omnihost.toml"));

    /// <summary>The program to run: the absolute path stored with the server, else a file of that name in the server folder, else the installed engine. Null when none exists.</summary>
    public static string? ResolveBinary(string launchTarget, string serverDir, string? engine)
    {
        if (Path.IsPathRooted(launchTarget) && File.Exists(launchTarget)) return launchTarget;
        if (launchTarget.Length > 0 && !Path.IsPathRooted(launchTarget) && File.Exists(Path.Combine(serverDir, launchTarget))) return Path.Combine(serverDir, launchTarget);
        return engine;
    }

    public const string MissingEngineReason = "The OMNIHost engine isn't installed on this computer. Create an OMNIHost server (or reinstall) to download it again.";

    /// <summary>Pumpkin keeps its config, world, plugins and logs in the working folder, so run it there. It reads commands (<c>stop</c>) from stdin when it isn't attached to a terminal.</summary>
    public static LaunchSpec? StartCommand(ServerConfig c, string? engine = null)
    {
        var exe = ResolveBinary(c.LaunchTarget, c.Path, engine ?? PumpkinEngine.InstalledBinary());
        return exe is null ? null : new LaunchSpec(exe, [], c.Path);
    }

    /// <summary>From Pumpkin's own log lines (checked against the real binary, 0.2.2+26.3-26.60).</summary>
    public static ServerStatus ParseStatus(string text)
    {
        var o = text.ToLowerInvariant();
        if (o.Contains("server is now running")) return ServerStatus.Running;
        if (o.Contains("received interrupt signal") || o.Contains("stopped accepting incoming connections") || o.Contains("stop requested")) return ServerStatus.Stopping;
        if (o.Contains("panicked at") || o.Contains("thread 'main' panicked")) return ServerStatus.Crashed;
        return ServerStatus.Unknown;
    }

    /// <summary>Prepares an existing server folder before a start: the OMNIHost icon and favicon setting (servers made before they existed), without replacing an icon the user chose.</summary>
    public static void PrepareFolder(string dir)
    {
        PumpkinConfig.EnsureFavicon(dir);
        InstallIcon(dir);
    }

    /// <summary>The icon every OMNIHost server starts with: the OMNI app icon as <c>server-icon.png</c>. Never replaces an icon the user already set. Returns whether one was written.</summary>
    public static bool InstallIcon(string dir)
    {
        var dest = Path.Combine(dir, PumpkinConfig.IconFile);
        if (File.Exists(dest)) return false;
        try
        {
            using var s = typeof(OmniHostAdapter).Assembly.GetManifestResourceStream("omnihost-icon-64.png");
            if (s is null) return false;
            using var f = File.Create(dest);
            s.CopyTo(f);
            return true;
        }
        catch { return false; }
    }

    /// <summary>The Java port of an OMNIHost server, or <paramref name="fallback"/>.</summary>
    public static int Port(string dir, int fallback = 25565) => PumpkinConfig.JavaPortOf(dir) ?? fallback;
}

/// <summary>Turns the engine's console output into short lines under the OMNIHost name: <c>[12:00:00] Ready. Join on port 25565</c>. Start-up chatter, banners and engine internals are dropped; player, chat, warning and error lines are kept.</summary>
public static partial class OmniHostLog
{
    [GeneratedRegex("\u001b\\[[0-9;]*m")] private static partial Regex Ansi();
    [GeneratedRegex(@"^(\d{2}:\d{2}:\d{2})\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+(.*)$")] private static partial Regex Line();
    [GeneratedRegex(@"Java Edition: [^\s|]*:(\d+)")] private static partial Regex Port();
    [GeneratedRegex("pumpkin(mc)?", RegexOptions.IgnoreCase)] private static partial Regex Name();

    static readonly string[] Noise =
    [
        "donat", "discord", "report issues", "heavy development", "embedded test instance",
        "embedded context provider", "enabled dimensions", "loading minecraft:", "nethernet",
        "stopped accepting incoming", "ending player tasks", "plugins unloaded", "starting save",
        "starting worlds", "saving level", "saving chunks", "joining 1 threads", "schedule: waiting",
        "flushing", "completed worlds", "telemetry", "not a tty",
    ];

    /// <summary>Every spelling of the engine's name becomes OMNIHost.</summary>
    public static string Rename(string s) => Name().Replace(s, "OMNIHost");

    /// <summary>Null means "don't show this line".</summary>
    public static string? Simplify(string raw)
    {
        var clean = Ansi().Replace(raw, "").Trim();
        if (clean.Length == 0) return null;
        var m = Line().Match(clean);
        if (!m.Success) return Rename(clean);
        var time = m.Groups[1].Value;
        var level = m.Groups[2].Value;
        var msg = m.Groups[3].Value.Trim();
        if (level is "TRACE" or "DEBUG") return null;
        var lower = msg.ToLowerInvariant();
        if (Noise.Any(lower.Contains)) return null;

        string text;
        if (lower.StartsWith("starting pumpkin")) text = $"Starting OMNIHost (Minecraft {PumpkinEngine.MinecraftVersion})";
        else if (lower.Contains("all worlds loaded")) text = "World loaded";
        else if (lower.Contains("server is now running"))
            text = Port().Match(msg) is { Success: true } pm ? $"Ready. Join on port {pm.Groups[1].Value}" : "Ready";
        else if (lower.Contains("creating a new world")) text = "Creating a new world";
        else if (lower.Contains("received interrupt signal")) text = "Stopping…";
        else if (lower.Contains("the server has stopped")) text = "Stopped";
        else if (lower.Contains("completed save")) text = "World saved";
        else text = Rename(msg);
        return level switch { "WARN" => $"[{time}] Warning: {text}", "ERROR" => $"[{time}] Error: {text}", _ => $"[{time}] {text}" };
    }
}
