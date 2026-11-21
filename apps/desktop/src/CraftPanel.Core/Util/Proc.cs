using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CraftPanel.Core;

public static class Platform
{
    [DllImport("ntdll.dll", EntryPoint = "wine_get_version")]
    static extern IntPtr WineGetVersion();

    static bool? _wine;
    /// <summary>True under Wine (CrossOver, Whisky…): only Wine's ntdll exports wine_get_version.</summary>
    public static bool IsWine => _wine ??= Detect();
    static bool Detect()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try { WineGetVersion(); return true; } catch { return false; }
    }

    public static bool IsWindows => OperatingSystem.IsWindows();
    public static bool IsMac => OperatingSystem.IsMacOS();
    public static string ExeSuffix => IsWindows ? ".exe" : "";
    /// <summary>Adoptium's names.</summary>
    public static string AdoptiumOs => IsWindows ? "windows" : IsMac ? "mac" : "linux";
    public static string AdoptiumArch => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "aarch64" : "x64";
}

public sealed record ProcResult(int ExitCode, string StdOut, string StdErr, bool TimedOut)
{
    public bool Success => ExitCode == 0 && !TimedOut;
}

/// <summary>Runs a program and drains both pipes concurrently (no pipe-fill deadlocks), never showing a console window.</summary>
public static class Proc
{
    public static async Task<ProcResult?> RunAsync(string exe, IEnumerable<string> args, string? cwd = null,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            UseShellExecute = false, CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (cwd != null) psi.WorkingDirectory = cwd;
        using var p = new Process { StartInfo = psi };
        try { p.Start(); }
        catch (Win32Exception) { return null; }
        catch (FileNotFoundException) { return null; }
        try { p.StandardInput.Close(); } catch { }
        var so = p.StandardOutput.ReadToEndAsync(ct);
        var se = p.StandardError.ReadToEndAsync(ct);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (timeout is { } t) cts.CancelAfter(t);
        var timedOut = false;
        try { await p.WaitForExitAsync(cts.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            timedOut = true;
            try { p.Kill(entireProcessTree: true); } catch { }
        }
        try { return new ProcResult(timedOut ? -1 : p.ExitCode, await so.ConfigureAwait(false), await se.ConfigureAwait(false), timedOut); }
        catch (OperationCanceledException) { return new ProcResult(-1, "", "", true); }
    }

    public static ProcResult? Run(string exe, IEnumerable<string> args, string? cwd = null, TimeSpan? timeout = null)
        => Task.Run(() => RunAsync(exe, args, cwd, timeout)).GetAwaiter().GetResult();

    /// <summary>Hard-kills a process tree (Windows has no SIGTERM for console apps).</summary>
    public static void KillTree(int pid)
    {
        try { Process.GetProcessById(pid).Kill(entireProcessTree: true); } catch { }
    }

    public static bool IsAlive(int pid)
    {
        try { using var p = Process.GetProcessById(pid); return !p.HasExited; } catch { return false; }
    }
}
