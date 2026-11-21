using System.Text.Json;
using System.Text.Json.Serialization;

namespace CraftPanel.Core.Network;

public enum PortProtocol { Tcp, Udp, Both }

/// <summary>One port a server needs open. "Both" means the same number for TCP and UDP.</summary>
public sealed record PortRule(PortProtocol Protocol, int Port, string Label = "");

public sealed record PortPreset(string Id, string Name, string Note, IReadOnlyList<PortRule> Rules, bool BuiltIn = true);

public enum IssueLevel { Error, Warning }
public sealed record RuleIssue(IssueLevel Level, string Message);

/// <summary>
/// Port rules and game presets. This is OMNIServers' own list of what a server needs; the OS firewall, the router
/// (UPnP) and tunnels are separate layers that change only when you apply the rules to them.
/// </summary>
public static class PortRules
{
    public static readonly IReadOnlyList<PortPreset> BuiltIn =
    [
        new("minecraft-java", "Minecraft Java", "The default Java server port.", [new(PortProtocol.Tcp, 25565, "Game")]),
        new("minecraft-bedrock", "Minecraft Bedrock", "Bedrock 26.60 and newer signs in over TCP and plays over UDP, so both must be open. Change the number if you changed server-port or server-udp-ports.", [new(PortProtocol.Both, 19132, "Sign-in (TCP) + game (UDP)")]),
        new("minecraft-geyser", "Bedrock on Java (Geyser)", "Your Java port, plus Geyser's port for Bedrock friends: TCP for sign-in and UDP for the game. The free tunnel only carries the Java port.", [new(PortProtocol.Tcp, 25565, "Java game"), new(PortProtocol.Both, 19132, "Bedrock sign-in (TCP) + game (UDP)")]),
        new("fivem", "FiveM", "The standard FiveM game endpoint.", [new(PortProtocol.Both, 30120, "Game")]),
        new("cs2", "Counter-Strike 2", "Dedicated server default. Check your launch options if you changed the port.", [new(PortProtocol.Both, 27015, "Game and query")]),
        new("terraria", "Terraria", "Default multiplayer port.", [new(PortProtocol.Tcp, 7777, "Game")]),
        new("ark-sa", "ARK: Survival Ascended", "Common defaults. ARK setups vary, so check your launch settings.", [new(PortProtocol.Udp, 7777, "Game"), new(PortProtocol.Udp, 7778, "Raw UDP"), new(PortProtocol.Udp, 27015, "Query")]),
        new("custom", "Custom", "Start empty and add your own TCP or UDP ports.", []),
    ];

    public static PortPreset? Find(string id, IEnumerable<PortPreset>? saved = null) =>
        BuiltIn.Concat(saved ?? []).FirstOrDefault(p => p.Id == id);

    /// <summary>Every concrete (protocol, port) pair, with "Both" split into TCP and UDP.</summary>
    public static IEnumerable<(PortProtocol Protocol, int Port)> Expand(IEnumerable<PortRule> rules)
    {
        foreach (var r in rules)
        {
            if (r.Protocol != PortProtocol.Udp) yield return (PortProtocol.Tcp, r.Port);
            if (r.Protocol != PortProtocol.Tcp) yield return (PortProtocol.Udp, r.Port);
        }
    }

    /// <summary>Errors for bad or repeated ports, and warnings for admin ports that shouldn't face the internet.</summary>
    public static List<RuleIssue> Validate(IReadOnlyList<PortRule> rules)
    {
        var issues = new List<RuleIssue>();
        foreach (var r in rules)
            if (r.Port is < 1 or > 65535) issues.Add(new(IssueLevel.Error, $"{r.Port} isn't a valid port. Use a number from 1 to 65535."));
        var seen = new HashSet<(PortProtocol, int)>();
        foreach (var pair in Expand(rules.Where(r => r.Port is >= 1 and <= 65535)))
            if (!seen.Add(pair)) issues.Add(new(IssueLevel.Error, $"{pair.Protocol.ToString().ToUpperInvariant()} {pair.Port} is listed twice."));
        foreach (var port in rules.Select(r => r.Port).Distinct())
            if (AdminPorts.TryGetValue(port, out var what))
                issues.Add(new(IssueLevel.Warning, $"Port {port} is {what}. Opening it to the internet lets anyone try to log in. Keep it closed unless you need it, and use a strong password."));
        return issues;
    }

    public static readonly IReadOnlyDictionary<int, string> AdminPorts = new Dictionary<int, string>
    {
        [22] = "SSH remote login", [23] = "Telnet", [3389] = "Windows Remote Desktop", [5900] = "VNC remote screen", [445] = "Windows file sharing",
        [25575] = "Minecraft RCON, the remote console", [3306] = "a MySQL database", [5432] = "a PostgreSQL database", [6379] = "a Redis database", [27017] = "a MongoDB database",
    };

    /// <summary>Ports another OMNIServers server already uses, plus anything else currently listening on this PC.</summary>
    public static List<RuleIssue> FindConflicts(IReadOnlyList<PortRule> rules, ISet<int> portsOfOtherServers, Func<PortProtocol, int, bool>? isFree = null)
    {
        isFree ??= Net.PortFreeFor;
        var issues = new List<RuleIssue>();
        foreach (var (proto, port) in Expand(rules).Where(p => p.Port is >= 1 and <= 65535).Distinct())
        {
            if (portsOfOtherServers.Contains(port)) issues.Add(new(IssueLevel.Warning, $"Another OMNIServers server already uses port {port}."));
            else if (!isFree(proto, port)) issues.Add(new(IssueLevel.Warning, $"{proto.ToString().ToUpperInvariant()} {port} is already in use by another program on this PC."));
        }
        return issues;
    }

    // ---- turning rules into firewall commands (shown to copy, or run on Windows) ----

    public static IEnumerable<string> NetshCommands(string name, IEnumerable<PortRule> rules) =>
        Expand(rules).Select(p => $"netsh advfirewall firewall add rule name=\"{name.Replace("\"", "")} {p.Protocol.ToString().ToUpperInvariant()} {p.Port}\" dir=in action=allow protocol={p.Protocol.ToString().ToUpperInvariant()} localport={p.Port} profile=private,public");

    public static IEnumerable<string> UfwCommands(IEnumerable<PortRule> rules) =>
        Expand(rules).Select(p => $"sudo ufw allow {p.Port}/{p.Protocol.ToString().ToLowerInvariant()}");

    // ---- saved custom presets ----

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public static List<PortPreset> LoadSaved(string file)
    {
        try { return File.Exists(file) ? (JsonSerializer.Deserialize<List<PortPreset>>(File.ReadAllText(file), Json) ?? []).Select(p => p with { BuiltIn = false }).ToList() : []; }
        catch { return []; }
    }

    public static void Save(string file, IEnumerable<PortPreset> saved)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, JsonSerializer.Serialize(saved.Where(p => !p.BuiltIn).ToList(), Json));
    }
}
