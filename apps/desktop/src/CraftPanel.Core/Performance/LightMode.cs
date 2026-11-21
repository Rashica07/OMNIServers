using System.Runtime.InteropServices;

namespace CraftPanel.Core.Performance;

public enum LightSetting { Auto, On, Off }

public sealed record LightDecision(bool Active, bool SoftwareDrawing, string Reason);

/// <summary>
/// "Light mode" for slow, small or remote PCs: OMNIServers does less in the background (samples server stats and re-reads the
/// log less often) and, on a remote-desktop session or when you choose it, draws with the CPU instead of the graphics
/// driver (the safest path on virtual machines and old drivers). Automatic turns it on for PCs with under 8 GB of memory,
/// under 4 cores, or a remote session.
/// </summary>
public static class LightMode
{
    public static LightSetting Parse(string? s) => s?.ToLowerInvariant() switch { "on" => LightSetting.On, "off" => LightSetting.Off, _ => LightSetting.Auto };
    public static string Name(LightSetting s) => s.ToString().ToLowerInvariant();

    /// <summary>Pure decision: setting + what this PC is like → whether Light mode is on, and why (said in plain words).</summary>
    public static LightDecision Decide(LightSetting setting, SystemMemory mem, bool remoteSession)
    {
        if (setting == LightSetting.Off) return new(false, false, "Light mode is turned off.");
        if (setting == LightSetting.On) return new(true, true, "You turned Light mode on.");
        if (remoteSession) return new(true, true, "This is a remote-desktop session, so OMNIServers is using Light mode.");
        if (mem.IsWeak) return new(true, false, $"This PC has {mem.TotalMB / 1024.0:0.#} GB of memory and {mem.Cores} CPU cores, so OMNIServers is using Light mode.");
        return new(false, false, $"This PC ({mem.TotalMB / 1024.0:0.#} GB, {mem.Cores} cores) doesn't need Light mode.");
    }

    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    const int SM_REMOTESESSION = 0x1000;

    /// <summary>True when running inside a Remote Desktop / RDP session (Windows only).</summary>
    public static bool IsRemoteSession()
    {
        try
        {
            if (OperatingSystem.IsWindows()) return GetSystemMetrics(SM_REMOTESESSION) != 0;
        }
        catch { }
        return false;
    }

    /// <summary>Set once at start-up; everything that polls reads it.</summary>
    public static LightDecision Current { get; set; } = new(false, false, "Light mode is turned off.");
    public static bool Active => Current.Active;

    public static void Configure(string? setting) => Current = Decide(Parse(setting), SystemMemory.Current(), IsRemoteSession());

    /// <summary>How often running servers' CPU/memory are sampled.</summary>
    public static TimeSpan MetricsInterval => Active ? TimeSpan.FromSeconds(10) : TimeSpan.FromSeconds(3);
    /// <summary>How often the open log file view refreshes.</summary>
    public static TimeSpan LogRefresh => Active ? TimeSpan.FromSeconds(4) : TimeSpan.FromMilliseconds(1500);
}
