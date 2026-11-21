using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace CraftPanel.Core.Power;

/// <summary>
/// Keeps the computer running for a hosted server: no idle sleep, and optionally no sleep when the laptop lid is closed.
/// Windows: SetThreadExecutionState plus the "lid close" power-plan action (powercfg, no administrator needed).
/// Linux: a systemd-inhibit lock. Elsewhere it does nothing and says so.
/// </summary>
public static class KeepAwake
{
    public static bool Supported => OperatingSystem.IsWindows() || (OperatingSystem.IsLinux() && File.Exists("/usr/bin/systemd-inhibit"));

    // ---- pure helpers (tested) ----------------------------------------------------------------

    /// <summary>The AC or battery value from `powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION`, or null.</summary>
    public static int? ParseLidIndex(string powercfgOutput, bool ac)
    {
        var m = Regex.Match(powercfgOutput, $@"Current {(ac ? "AC" : "DC")} Power Setting Index:\s*0x([0-9a-fA-F]+)");
        return m.Success ? Convert.ToInt32(m.Groups[1].Value, 16) : null;
    }

    /// <summary>powercfg arguments that set the lid-close action (0 = do nothing, 1 = sleep) for AC and battery, then re-apply the plan.</summary>
    public static IReadOnlyList<string[]> LidCommands(int ac, int dc) =>
    [
        ["/setacvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", ac.ToString()],
        ["/setdcvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", dc.ToString()],
        ["/setactive", "SCHEME_CURRENT"],
    ];

    public static string[] InhibitArgs() =>
        ["--what=handle-lid-switch:sleep:idle", "--who=OMNIServers", "--why=A Minecraft server is running", "--mode=block", "sleep", "infinity"];

    // ---- Windows ----------------------------------------------------------------------------------

    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    const uint EsContinuous = 0x80000000, EsSystemRequired = 0x00000001;
    static Thread? _holder; static readonly ManualResetEventSlim _release = new(false);
    static System.Diagnostics.Process? _inhibit;

    /// <summary>Stop the computer sleeping while idle (and while the app runs).</summary>
    public static void SetStayAwake(bool on)
    {
        if (OperatingSystem.IsWindows())
        {
            if (on && _holder is null)
            {
                _release.Reset();
                _holder = new Thread(() => { SetThreadExecutionState(EsContinuous | EsSystemRequired); _release.Wait(); SetThreadExecutionState(EsContinuous); }) { IsBackground = true, Name = "keep-awake" };
                _holder.Start();
            }
            else if (!on && _holder is not null) { _release.Set(); _holder.Join(500); _holder = null; }
        }
        else if (OperatingSystem.IsLinux()) SetInhibit(on);
    }

    static void SetInhibit(bool on)
    {
        try
        {
            if (on && (_inhibit is null || _inhibit.HasExited) && Supported)
                _inhibit = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("systemd-inhibit", InhibitArgs()) { UseShellExecute = false, CreateNoWindow = true });
            else if (!on && _inhibit is { HasExited: false }) { _inhibit.Kill(); _inhibit = null; }
        }
        catch { /* no systemd: nothing to hold */ }
    }

    /// <summary>
    /// Keep running with the lid closed. Turning it on remembers the current lid actions in <paramref name="settings"/> and sets "do nothing";
    /// turning it off puts them back. On Linux the inhibit lock covers the lid switch.
    /// </summary>
    public static async Task<bool> SetLidClosedAsync(bool on, AppSettings settings)
    {
        if (OperatingSystem.IsLinux()) { SetInhibit(on || settings.StayAwake); return Supported; }
        if (!OperatingSystem.IsWindows()) return false;
        if (on)
        {
            var q = await Proc.RunAsync("powercfg", ["/query", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION"], timeout: TimeSpan.FromSeconds(10));
            if (q is null) return false;
            if (settings.LidSavedAc is null) { settings.LidSavedAc = ParseLidIndex(q.StdOut, true) ?? 1; settings.LidSavedDc = ParseLidIndex(q.StdOut, false) ?? 1; }
            return await ApplyAsync(0, 0);
        }
        var ok = await ApplyAsync(settings.LidSavedAc ?? 1, settings.LidSavedDc ?? 1);
        if (ok) { settings.LidSavedAc = null; settings.LidSavedDc = null; }
        return ok;
    }

    static async Task<bool> ApplyAsync(int ac, int dc)
    {
        foreach (var args in LidCommands(ac, dc))
        {
            var r = await Proc.RunAsync("powercfg", args, timeout: TimeSpan.FromSeconds(10));
            if (r is not { Success: true }) return false;
        }
        return true;
    }

    /// <summary>Put things in the state the saved settings describe (called at start-up and on every change).</summary>
    public static async Task ApplyAsync(AppSettings s)
    {
        SetStayAwake(s.StayAwake || s.KeepRunningLidClosed);
        if (s.KeepRunningLidClosed || s.LidSavedAc is not null) await SetLidClosedAsync(s.KeepRunningLidClosed, s);
        s.Save();
    }
}
