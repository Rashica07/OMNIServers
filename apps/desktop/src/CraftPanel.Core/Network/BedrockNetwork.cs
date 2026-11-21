using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;

namespace CraftPanel.Core.Network;

/// <summary>First and last UDP port (inclusive) from BDS's <c>server-udp-ports</c>.</summary>
public sealed record UdpPorts(int First, int Last)
{
    public int Count => Last - First + 1;
}

/// <summary>
/// Everything OMNIServers knows about Bedrock 26.60 networking. Since 26.60 clients only speak NetherNet: a TCP sign-in
/// (HTTP signaling) on the Bedrock port, then the game itself over WebRTC on UDP. Sources: GeyserMC's "Preparing for
/// NetherNet" post and system-properties page, Mojang's NetherNet onboarding guide, and the how-to that ships inside
/// BDS 1.26.63.1 (server.properties: transport, server-udp-ports, allow-list).
/// </summary>
public static class BedrockNetwork
{
    /// <summary>Geyser build 1273 (Geyser 2.12.1, 2026-10-26) is the first with Bedrock 26.60 support.</summary>
    public const int MinGeyserBuild = 1273;
    /// <summary>Geyser system property that turns NetherNet on. It overrides config.yml, so old RakNet configs are fixed too.</summary>
    public const string GeyserTransportFlag = "-DgeyserTransport=nethernet";
    /// <summary>BDS releases before this one only speak RakNet, which 26.60 clients no longer use.</summary>
    public static readonly Version FirstNetherNetBds = new(1, 26, 50);

    // ---- Geyser ------------------------------------------------------------------------------

    /// <summary>
    /// JVM args for a server with Geyser: adds <c>-DgeyserTransport=nethernet</c> unless the user already chose a transport
    /// (a <c>-DgeyserTransport</c> flag of their own, or <c>transport: both|nethernet</c> in Geyser's config).
    /// </summary>
    public static string? WithGeyserFlags(string? jvmArgs, bool geyserInstalled, string? configTransport)
    {
        if (!geyserInstalled) return jvmArgs;
        if ((jvmArgs ?? "").Contains("-DgeyserTransport", StringComparison.Ordinal)) return jvmArgs;
        if (configTransport?.Trim().ToLowerInvariant() is "both" or "nethernet") return jvmArgs;
        var t = (jvmArgs ?? "").Trim();
        return t.Length == 0 ? GeyserTransportFlag : $"{t} {GeyserTransportFlag}";
    }

    /// <summary>Geyser's one port: TCP for sign-in and UDP for the game, same number.</summary>
    public static IReadOnlyList<PortRule> GeyserRules(int bedrockPort) =>
        [new(PortProtocol.Both, bedrockPort, "Bedrock sign-in (TCP) + game (UDP)")];

    public static bool GeyserNeedsUpdate(bool geyserInstalled, int? installedBuild) =>
        geyserInstalled && (installedBuild is null || installedBuild < MinGeyserBuild);

    /// <summary>Reads <c>build</c> and <c>version</c> from GeyserMC's build JSON.</summary>
    public static (int Build, string Version)? ParseGeyserBuild(JsonNode? json)
    {
        try
        {
            var b = json?["build"]?.GetValue<int>();
            var v = json?["version"]?.GetValue<string>();
            return b is { } n && v is not null ? (n, v) : null;
        }
        catch { return null; }
    }

    // ---- official BDS ---------------------------------------------------------------------------

    /// <summary>
    /// Parses <c>server-udp-ports</c>: <c>N</c>, <c>A-B</c>, <c>public:local</c>, <c>IP:public:local</c> or
    /// <c>[IPv6]:public:local</c>. Returns the LOCAL range, or null when empty/unreadable (BDS then picks random UDP ports).
    /// </summary>
    public static UdpPorts? ParseUdpPorts(string? value)
    {
        var v = value?.Trim();
        if (string.IsNullOrEmpty(v)) return null;
        if (v[0] == '[') { var end = v.IndexOf(']'); if (end < 0 || end + 2 > v.Length) return null; v = v[(end + 2)..]; }
        var parts = v.Split(':');
        if (parts.Length == 3) parts = parts[1..];          // IPv4:public:local
        var local = parts[^1];
        var dash = local.IndexOf('-');
        if (dash > 0)
        {
            if (!int.TryParse(local[..dash], out var a) || !int.TryParse(local[(dash + 1)..], out var b)) return null;
            return Valid(a) && Valid(b) && a <= b ? new(a, b) : null;
        }
        return int.TryParse(local, out var p) && Valid(p) ? new(p, p) : null;
    }

    static bool Valid(int p) => p is >= 1 and <= 65535;

    /// <summary>
    /// The value to write for <c>server-udp-ports</c>: one shared UDP port equal to the server port, with the public IP in
    /// front when it is known (BDS hands that address to clients; Mojang's client has no STUN, so a NAT'd host needs it).
    /// </summary>
    public static string UdpPortsValue(int port, string? publicIp)
    {
        if (IPAddress.TryParse(publicIp?.Trim(), out var ip))
            return ip.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{ip}]:{port}:{port}" : $"{ip}:{port}:{port}";
        return port.ToString();
    }

    /// <summary>What a Bedrock server needs open: TCP on <c>server-port</c> (sign-in) plus its UDP port(s).</summary>
    public static IReadOnlyList<PortRule> BdsRules(int serverPort, string? udpPortsValue)
    {
        var rules = new List<PortRule> { new(PortProtocol.Tcp, serverPort, "Sign-in (signaling)") };
        var udp = ParseUdpPorts(udpPortsValue);
        if (udp is null) rules.Add(new(PortProtocol.Udp, serverPort, "Game (set server-udp-ports to pin it)"));
        else if (udp.Count == 1) rules.Add(new(PortProtocol.Udp, udp.First, "Game"));
        else rules.Add(new(PortProtocol.Udp, udp.First, $"Game (range {udp.First}-{udp.Last}, add the rest)"));
        return Merge(rules);
    }

    // a TCP and a UDP rule on the same number read better as one "TCP + UDP" row
    static IReadOnlyList<PortRule> Merge(List<PortRule> rules)
    {
        if (rules.Count == 2 && rules[0].Port == rules[1].Port && rules[0].Protocol == PortProtocol.Tcp && rules[1].Protocol == PortProtocol.Udp)
            return [new(PortProtocol.Both, rules[0].Port, "Sign-in (TCP) + game (UDP)")];
        return rules;
    }

    /// <summary>Port-rule preset and rules that fit this server (Bedrock server, or Java server with Geyser), else null.</summary>
    public static (string PresetId, IReadOnlyList<PortRule> Rules)? DefaultRules(ServerType type, string dir)
    {
        if (type.IsBedrock())
        {
            var p = Properties.Load(dir);
            return ("minecraft-bedrock", BdsRules(p.GetInt("server-port", 19132), p.Get("server-udp-ports")));
        }
        var xp = CrossplayManager.Status(dir, type);
        if (!xp.Geyser) return null;
        var javaPort = Properties.Load(dir).GetInt("server-port", 25565);
        var rules = new List<PortRule> { new(PortProtocol.Tcp, javaPort, "Java game") };
        rules.AddRange(GeyserRules(xp.BedrockPort));
        return ("minecraft-geyser", rules);
    }

    /// <summary>
    /// New Bedrock servers: one UDP port equal to the server port (two servers must not share BDS's default 19132), and
    /// the allow-list off. BDS now ships <c>allow-list=true</c> with an empty list, which refuses every player, the owner
    /// included. <c>online-mode</c> stays on, so every player is still Xbox-signed-in.
    /// </summary>
    public static void ApplyNewBdsDefaults(Properties p, int serverPort)
    {
        p.Set("server-udp-ports", serverPort.ToString());
        p.Set("allow-list", "false");
    }

    /// <summary>True when this BDS version predates NetherNet (null/unreadable = false, nothing to warn about).</summary>
    public static bool IsLegacyBds(string? mcVersion) =>
        Version.TryParse(mcVersion?.Trim(), out var v) && v < FirstNetherNetBds;

    // ---- addresses ------------------------------------------------------------------------------

    /// <summary>
    /// The address a Bedrock friend types: the public IP and the Bedrock port when known, else the LAN address. Never the
    /// free tunnel's address, which only carries Java (TCP).
    /// </summary>
    public static string BedrockAddress(string? publicIp, string? lanIp, int port)
    {
        var host = !string.IsNullOrWhiteSpace(publicIp) ? publicIp.Trim() : lanIp?.Trim();
        if (string.IsNullOrEmpty(host)) return "";
        var i = host.LastIndexOf(':');
        var hasPort = i > 0 && !host.Contains("::") && int.TryParse(host[(i + 1)..], out _);
        if (hasPort) host = host[..i];
        return $"{host}:{port}";
    }

    /// <summary>"TCP 19132 and UDP 19132" — what to say to a person about a set of rules.</summary>
    public static string Describe(IEnumerable<PortRule> rules)
    {
        var parts = PortRules.Expand(rules).Distinct().Select(p => $"{p.Protocol.ToString().ToUpperInvariant()} {p.Port}").ToList();
        return parts.Count switch { 0 => "no ports", 1 => parts[0], _ => string.Join(", ", parts[..^1]) + " and " + parts[^1] };
    }

    public const string TunnelNote = "The free tunnel can't carry Bedrock: Bedrock 26.60 needs a TCP sign-in plus a UDP game connection, and the tunnel only carries TCP. For friends outside your home, forward TCP and UDP on your router.";
    public const string TrustPromptNote = "Players see a one-time “trust this server” question the first time they join by IP address.";
}
