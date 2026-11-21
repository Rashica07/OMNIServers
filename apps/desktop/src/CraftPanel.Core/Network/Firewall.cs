namespace CraftPanel.Core.Network;

/// <summary>Windows Defender Firewall inbound rule for a server's port (Windows only; other platforms report "unsupported").</summary>
public static class Firewall
{
    public static bool Supported => OperatingSystem.IsWindows();
    public static string RuleName(string serverName, int port) => $"CraftPanel - {serverName} ({port})";

    /// <summary>Does an inbound allow-rule with this name exist? Null if we can't tell.</summary>
    public static async Task<bool?> RuleExistsAsync(string ruleName)
    {
        if (!Supported) return null;
        var r = await Proc.RunAsync("netsh", ["advfirewall", "firewall", "show", "rule", $"name={ruleName}"], timeout: TimeSpan.FromSeconds(8));
        if (r is null) return null;
        return r.ExitCode == 0 && !r.StdOut.Contains("No rules match", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The <c>netsh</c> arguments for one inbound allow rule.</summary>
    public static string NetshArgs(string ruleName, int port, bool udp)
    {
        var safe = ruleName.Replace("'", "''").Replace("\"", "");
        return $"advfirewall firewall add rule name=\"{safe}\" dir=in action=allow protocol={(udp ? "UDP" : "TCP")} localport={port} profile=private,public";
    }

    /// <summary>Adds the rule, asking Windows for administrator permission (UAC prompt).</summary>
    public static async Task<bool> AddRuleAsync(string ruleName, int port, bool udp = false)
    {
        if (!Supported) return false;
        var args = NetshArgs(ruleName, port, udp);
        var ps = $"Start-Process -FilePath netsh -ArgumentList '{args.Replace("'", "''")}' -Verb RunAs -Wait -WindowStyle Hidden";
        var r = await Proc.RunAsync("powershell", ["-NoProfile", "-NonInteractive", "-Command", ps], timeout: TimeSpan.FromSeconds(90));
        return r is { Success: true } && await RuleExistsAsync(ruleName) == true;
    }

    /// <summary>The two rule names used for a port that needs both protocols (Bedrock 26.60: TCP sign-in + UDP game).</summary>
    public static (string Tcp, string Udp) BothRuleNames(string ruleName) => ($"{ruleName} TCP", $"{ruleName} UDP");

    /// <summary>Are the rules for these ports in place? (A Both rule needs both TCP and UDP rules.)</summary>
    public static async Task<bool?> RulesExistAsync(string ruleName, IEnumerable<PortRule> rules)
    {
        if (!Supported) return null;
        foreach (var (name, _, _) in RuleSet(ruleName, rules))
        {
            var e = await RuleExistsAsync(name);
            if (e is not true) return e;
        }
        return true;
    }

    /// <summary>Every (rule name, port, udp) a set of port rules needs: Both becomes a TCP rule plus a UDP rule.</summary>
    public static List<(string Name, int Port, bool Udp)> RuleSet(string ruleName, IEnumerable<PortRule> rules) =>
        PortRules.Expand(rules).Distinct().Select(p => ($"{ruleName} {p.Protocol.ToString().ToUpperInvariant()} {p.Port}", p.Port, p.Protocol == PortProtocol.Udp)).ToList();

    /// <summary>Allows every port in <paramref name="rules"/> (TCP and UDP where asked) with ONE administrator prompt.</summary>
    public static async Task<bool> AddForRulesAsync(string ruleName, IEnumerable<PortRule> rules)
    {
        if (!Supported) return false;
        var set = RuleSet(ruleName, rules);
        if (set.Count == 0) return false;
        var script = string.Join("; ", set.Select(r => $"Start-Process -FilePath netsh -ArgumentList '{NetshArgs(r.Name, r.Port, r.Udp).Replace("'", "''")}' -Verb RunAs -Wait -WindowStyle Hidden"));
        var r = await Proc.RunAsync("powershell", ["-NoProfile", "-NonInteractive", "-Command", script], timeout: TimeSpan.FromSeconds(120));
        if (r is not { Success: true }) return false;
        foreach (var x in set) if (await RuleExistsAsync(x.Name) != true) return false;
        return true;
    }

    /// <summary>Allows <paramref name="port"/> for TCP and UDP with ONE administrator prompt.</summary>
    public static async Task<bool> AddBothRulesAsync(string ruleName, int port)
    {
        if (!Supported) return false;
        var (tcp, udp) = BothRuleNames(ruleName);
        var script = $"Start-Process -FilePath netsh -ArgumentList '{NetshArgs(tcp, port, false).Replace("'", "''")}' -Verb RunAs -Wait -WindowStyle Hidden; " +
                     $"Start-Process -FilePath netsh -ArgumentList '{NetshArgs(udp, port, true).Replace("'", "''")}' -Verb RunAs -Wait -WindowStyle Hidden";
        var r = await Proc.RunAsync("powershell", ["-NoProfile", "-NonInteractive", "-Command", script], timeout: TimeSpan.FromSeconds(120));
        return r is { Success: true } && await RuleExistsAsync(tcp) == true && await RuleExistsAsync(udp) == true;
    }
}
