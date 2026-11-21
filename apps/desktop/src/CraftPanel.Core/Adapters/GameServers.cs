using System.Security.Cryptography;
using System.Text;

namespace CraftPanel.Core.Adapters;

/// <summary>What was found in a folder that holds a non-Minecraft game server.</summary>
public sealed record GameDetection(ServerType Type, string LaunchTarget, string Evidence);

/// <summary>FiveM and Terraria: find the server files, repair the setup, build the launch command, read the console.</summary>
public static class GameServers
{
    public const string BannerLine = "MADE WITH OMNISERVERS";

    /// <summary>Shown in the console every time a server starts. Games get the "made with" line, Minecraft the "set up with" one.</summary>
    public static IReadOnlyList<string> Banner(string game) =>
    [
        " ██████╗ ███╗   ███╗███╗   ██╗██╗",
        "██╔═══██╗████╗ ████║████╗  ██║██║",
        "██║   ██║██╔████╔██║██╔██╗ ██║██║",
        "██║   ██║██║╚██╔╝██║██║╚██╗██║██║",
        "╚██████╔╝██║ ╚═╝ ██║██║ ╚████║██║",
        " ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝",
        "███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ ███████╗",
        "██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗██╔════╝",
        "███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝███████╗",
        "╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗╚════██║",
        "███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║███████║",
        "╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝╚══════╝",
        game == "Minecraft" ? "      This server was set up with OMNIServers" : "      " + BannerLine + "  ·  " + game,
    ];

    public static int DefaultPort(ServerType t) => t switch { ServerType.FiveM => 30120, ServerType.Terraria => 7777, ServerType.Bedrock => 19132, _ => 25565 };

    public static string StopCommand(ServerType t) => t switch { ServerType.FiveM => "quit", ServerType.Terraria => "exit", _ => "stop" };

    /// <summary>FiveM's server software only exists for Windows and Linux; Terraria's for all three.</summary>
    public static bool IsPlatformSupported(ServerType t) => t != ServerType.FiveM || !OperatingSystem.IsMacOS();

    public static GameDetection? Inspect(string dir)
    {
        if (!Directory.Exists(dir)) return null;
        foreach (var f in new[] { "FXServer.exe", "run.sh" })
        {
            var full = Path.Combine(dir, f);
            if (!File.Exists(full)) continue;
            // run.sh alone is generic; only count it next to FiveM's own files.
            if (f == "run.sh" && !(Directory.Exists(Path.Combine(dir, "alpine")) || File.Exists(Path.Combine(dir, "server.cfg")) || Directory.Exists(Path.Combine(dir, "resources")))) continue;
            return new(ServerType.FiveM, f, f);
        }
        if (Directory.Exists(Path.Combine(dir, "resources")) && File.Exists(Path.Combine(dir, "server.cfg")) && Directory.Exists(Path.Combine(dir, "alpine")))
            return new(ServerType.FiveM, "run.sh", "alpine/");
        var app = Path.Combine("Terraria Server.app", "Contents", "MacOS", "TerrariaServer");
        if (File.Exists(Path.Combine(dir, app))) return new(ServerType.Terraria, app, "Terraria Server.app");
        foreach (var f in new[] { "TerrariaServer.exe", "TerrariaServer.bin.x86_64", "TerrariaServer.bin.osx", "TerrariaServer" })
            if (File.Exists(Path.Combine(dir, f))) return new(ServerType.Terraria, f, f);
        return null;
    }

    public static LaunchSpec StartCommand(ServerConfig c) => c.ServerType switch
    {
        ServerType.FiveM => new(Path.Combine(c.Path, c.LaunchTarget), ["+exec", "server.cfg"], c.Path),
        ServerType.Terraria => new(Path.Combine(c.Path, c.LaunchTarget), ["-config", Path.Combine(c.Path, "serverconfig.txt")], c.Path),
        _ => throw new ArgumentException("Not a game server: " + c.ServerType),
    };

    public static ServerStatus ParseStatus(ServerType t, string text)
    {
        var o = text.ToLowerInvariant();
        if (t == ServerType.FiveM)
        {
            if (o.Contains("server thread is now running") || o.Contains("server started") || o.Contains("started resource monitor")) return ServerStatus.Running;
            if (o.Contains("shutting down") || o.Contains("quit")) return ServerStatus.Stopping;
        }
        else if (t == ServerType.Terraria)
        {
            if (o.Contains("server started")) return ServerStatus.Running;
            if (o.Contains("saving world") || o.Contains("shutting down")) return ServerStatus.Stopping;
        }
        return ServerStatus.Unknown;
    }

    /// <summary>Repairs a game server folder so it can start. Returns what it changed (plain words) and what you must still do yourself.</summary>
    public static GameFixResult Fix(ServerType type, string dir, string serverName)
    {
        var done = new List<string>(); var todo = new List<string>();
        if (type == ServerType.FiveM) FixFiveM(dir, serverName, done, todo);
        else if (type == ServerType.Terraria) FixTerraria(dir, serverName, done, todo);
        return new(done, todo);
    }

    static string Pass()
    {
        var bytes = RandomNumberGenerator.GetBytes(12);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    static void FixFiveM(string dir, string name, List<string> done, List<string> todo)
    {
        var cfg = Path.Combine(dir, "server.cfg");
        if (!File.Exists(cfg))
        {
            var sb = new StringBuilder();
            sb.AppendLine("# Made by OMNIServers. Edit freely.");
            sb.AppendLine("endpoint_add_tcp \"0.0.0.0:30120\"");
            sb.AppendLine("endpoint_add_udp \"0.0.0.0:30120\"");
            sb.AppendLine();
            sb.AppendLine("sv_hostname \"" + name.Replace("\"", "") + "\"");
            sb.AppendLine("sv_maxclients 32");
            sb.AppendLine("set sv_enforceGameBuild 3095");
            sb.AppendLine("sv_licenseKeyToken \"PASTE-YOUR-KEY-HERE\"");
            sb.AppendLine("set rcon_password \"" + Pass() + "\"");
            sb.AppendLine();
            foreach (var r in new[] { "mapmanager", "chat", "spawnmanager", "sessionmanager", "basic-gamemode", "hardcap", "rconlog" })
                if (ResourceExists(dir, r)) sb.AppendLine("ensure " + r);
            File.WriteAllText(cfg, sb.ToString());
            done.Add("Created server.cfg with the standard ports and resources.");
        }
        else
        {
            var text = File.ReadAllText(cfg);
            var add = new StringBuilder();
            if (!text.Contains("endpoint_add_tcp", StringComparison.OrdinalIgnoreCase)) { add.AppendLine("endpoint_add_tcp \"0.0.0.0:30120\""); done.Add("Added the missing TCP port (30120) to server.cfg."); }
            if (!text.Contains("endpoint_add_udp", StringComparison.OrdinalIgnoreCase)) { add.AppendLine("endpoint_add_udp \"0.0.0.0:30120\""); done.Add("Added the missing UDP port (30120) to server.cfg."); }
            if (!text.Contains("rcon_password", StringComparison.OrdinalIgnoreCase)) { add.AppendLine("set rcon_password \"" + Pass() + "\""); done.Add("Set an RCON password so the console can be reached."); }
            if (add.Length > 0) File.WriteAllText(cfg, text.TrimEnd() + Environment.NewLine + add);
        }
        var final = File.ReadAllText(cfg);
        if (!System.Text.RegularExpressions.Regex.IsMatch(final, "sv_licenseKey(Token)?\\s+\"?(?!PASTE-YOUR-KEY-HERE)[A-Za-z0-9_-]{8,}", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            todo.Add("FiveM needs your own free licence key. Get it at keymaster.fivem.net and paste it into server.cfg (sv_licenseKeyToken).");
        if (!Directory.Exists(Path.Combine(dir, "resources")))
            todo.Add("No resources folder here. Download cfx-server-data and put its resources folder next to the server files.");
    }

    static bool ResourceExists(string dir, string name)
    {
        var root = Path.Combine(dir, "resources");
        if (!Directory.Exists(root)) return false;
        try { return Directory.EnumerateDirectories(root, name, SearchOption.AllDirectories).Any(); } catch { return false; }
    }

    static void FixTerraria(string dir, string name, List<string> done, List<string> todo)
    {
        var cfg = Path.Combine(dir, "serverconfig.txt");
        var worlds = Path.Combine(dir, "Worlds");
        Directory.CreateDirectory(worlds);
        if (!File.Exists(cfg))
        {
            var existing = Directory.EnumerateFiles(worlds, "*.wld").FirstOrDefault();
            var sb = new StringBuilder();
            sb.AppendLine("# Made by OMNIServers. Edit freely.");
            if (existing is not null) sb.AppendLine("world=" + existing);
            else
            {
                var file = Path.Combine(worlds, SafeName(name) + ".wld");
                sb.AppendLine("world=" + file);
                sb.AppendLine("autocreate=2");
                sb.AppendLine("worldname=" + SafeName(name));
            }
            sb.AppendLine("worldpath=" + worlds);
            sb.AppendLine("maxplayers=8");
            sb.AppendLine("port=7777");
            sb.AppendLine("password=");
            sb.AppendLine("motd=Made with OMNIServers");
            File.WriteAllText(cfg, sb.ToString());
            done.Add(existing is null ? "Created serverconfig.txt. A new medium world is made on first start." : "Created serverconfig.txt and pointed it at your existing world.");
        }
        else
        {
            var text = File.ReadAllText(cfg);
            if (!System.Text.RegularExpressions.Regex.IsMatch(text, "^\\s*port\\s*=", System.Text.RegularExpressions.RegexOptions.Multiline))
            { File.WriteAllText(cfg, text.TrimEnd() + Environment.NewLine + "port=7777" + Environment.NewLine); done.Add("Added the port (7777) to serverconfig.txt."); }
        }
    }

    static string SafeName(string n)
    {
        var s = new string(n.Where(c => char.IsLetterOrDigit(c) || c is '-' or '_').ToArray());
        return s.Length == 0 ? "World" : s;
    }
}

public sealed record GameFixResult(IReadOnlyList<string> Done, IReadOnlyList<string> ToDo);
