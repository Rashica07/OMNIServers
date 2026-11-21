using System.Runtime.InteropServices;
using Avalonia;

namespace CraftPanel.App;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        // Two copies would fight over the same servers; the second one just says so and leaves.
        using var mutex = OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("CRAFTPANEL_DATA") is null ? new Mutex(true, "Local\\CraftPanel-single-instance", out var first) : null;
        if (mutex is not null && !FirstInstance(mutex, args.Contains(CraftPanel.Core.Updates.AppUpdater.WaitArg))) return;
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    static bool FirstInstance(Mutex m, bool waitForPrevious)
    {
        // Right after an update the old copy is still closing; give it a moment instead of complaining.
        try { if (m.WaitOne(waitForPrevious ? TimeSpan.FromSeconds(20) : TimeSpan.Zero)) return true; } catch (AbandonedMutexException) { return true; }
        MessageBoxW(IntPtr.Zero, "OMNIServers is already running — look for it in your taskbar or system tray.", "OMNIServers", 0x40);
        return false;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    public static AppBuilder BuildAvaloniaApp()
    {
        var builder = AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
        try { CraftPanel.Core.Performance.LightMode.Configure(CraftPanel.Core.AppSettings.Load().LightMode); } catch { /* an unreadable settings file means "automatic" */ }
        if (OperatingSystem.IsWindows())
        {
            // Under Wine/CrossOver the GPU paths (ANGLE/D3D, WGL) are hit-and-miss; software rendering always works and is plenty for this UI.
            // Override with CRAFTPANEL_RENDER=angle|wgl|software (or "auto" to let Avalonia choose).
            var forced = Environment.GetEnvironmentVariable("CRAFTPANEL_RENDER");
            var mode = (forced ?? (IsWine() || CraftPanel.Core.Performance.LightMode.Current.SoftwareDrawing ? "software" : "auto")).ToLowerInvariant();   // Light mode on a remote session (or by choice) draws with the CPU
            RenderMode = mode;
            Win32RenderingMode[]? modes = mode switch
            {
                "software" => [Win32RenderingMode.Software],
                "wgl" => [Win32RenderingMode.Wgl, Win32RenderingMode.Software],
                "angle" => [Win32RenderingMode.AngleEgl, Win32RenderingMode.Software],
                _ => null,
            };
            if (modes is not null || IsWine())
                builder = builder.With(new Win32PlatformOptions
                {
                    RenderingMode = modes ?? [Win32RenderingMode.Software],
                    // WinUI/DirectComposition need real Windows shell interfaces; plain redirection surfaces work everywhere.
                    CompositionMode = IsWine() ? [Win32CompositionMode.RedirectionSurface] : [Win32CompositionMode.WinUIComposition, Win32CompositionMode.DirectComposition, Win32CompositionMode.RedirectionSurface],
                });
        }
        return builder;
    }

    /// <summary>The drawing mode chosen at start-up ("auto", "software", "wgl", "angle"), for problem reports.</summary>
    public static string RenderMode { get; private set; } = "auto";

    public static bool IsWine() => CraftPanel.Core.Platform.IsWine;
}
