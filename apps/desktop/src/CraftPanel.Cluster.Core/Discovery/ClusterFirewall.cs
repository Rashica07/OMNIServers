using CraftPanel.Core;

namespace CraftPanel.Cluster.Discovery;

public sealed record FirewallAdvice(string Summary, string Steps, string Command);

/// <summary>
/// Windows Defender Firewall and discovery. Discovery needs UDP 5353 (multicast DNS) inbound; if the firewall drops it, the
/// service looks like it works but hears nothing. We notice that and say exactly what to allow, instead of failing silently.
/// </summary>
public static class ClusterFirewall
{
    public const string RuleName = "CraftPanel cluster discovery (mDNS)";
    public static bool Supported => OperatingSystem.IsWindows();

    public static FirewallAdvice Advice() => new(
        "Windows Firewall may be blocking CraftPanel from finding other PCs.",
        "Allow CraftPanel to receive UDP port 5353 (multicast DNS) on private networks. Windows normally asks the first time; if you chose Cancel, or your network is set to Public, it won't have been allowed.",
        $"netsh advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow protocol=UDP localport=5353 profile=private program=\"{Environment.ProcessPath}\"");

    public static async Task<bool?> RuleExistsAsync()
    {
        if (!Supported) return null;
        var r = await Proc.RunAsync("netsh", ["advfirewall", "firewall", "show", "rule", $"name={RuleName}"], timeout: TimeSpan.FromSeconds(8));
        return r is null ? null : r.ExitCode == 0 && !r.StdOut.Contains("No rules match", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Adds an inbound rule for this program only, private networks only, asking Windows for administrator permission.</summary>
    public static async Task<bool> AddRuleAsync()
    {
        if (!Supported || Environment.ProcessPath is not { } exe) return false;
        var args = $"advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow protocol=UDP localport=5353 profile=private program=\"{exe.Replace("\"", "")}\"";
        var ps = $"Start-Process -FilePath netsh -ArgumentList '{args.Replace("'", "''")}' -Verb RunAs -Wait -WindowStyle Hidden";
        var r = await Proc.RunAsync("powershell", ["-NoProfile", "-NonInteractive", "-Command", ps], timeout: TimeSpan.FromSeconds(90));
        return r is { Success: true } && await RuleExistsAsync() == true;
    }
}
