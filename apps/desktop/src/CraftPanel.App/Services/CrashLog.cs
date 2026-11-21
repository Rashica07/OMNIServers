using System.Text;
using Avalonia.Threading;
using CraftPanel.Core;

namespace CraftPanel.App.Services;

/// <summary>Writes unexpected errors to %APPDATA%\CraftPanel\logs\crash.log so a problem on someone else's PC can be diagnosed.</summary>
public static class CrashLog
{
    static readonly object Gate = new();

    public static string FilePath => Path.Combine(AppPaths.LogsDir, "crash.log");

    public static void Install()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Write("unhandled", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { Write("task", e.Exception); e.SetObserved(); };
        Dispatcher.UIThread.UnhandledException += (_, e) => { Write("ui", e.Exception); e.Handled = true; ToastService.Shared.Show("Something went wrong: " + e.Exception.Message, "Settings → Diagnostics → Report a problem saves a file you can send.", "alert-octagon", "bad", null, 12); };
    }

    public static void Write(string where, Exception? ex)
    {
        try
        {
            lock (Gate)
            {
                var sb = new StringBuilder();
                sb.AppendLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {where} — OMNIServers {typeof(CrashLog).Assembly.GetName().Version} on {Environment.OSVersion} ({(Program.IsWine() ? "Wine" : "native")})");
                sb.AppendLine(ex?.ToString() ?? "(no exception)");
                sb.AppendLine();
                var f = FilePath;
                if (File.Exists(f) && new FileInfo(f).Length > 512 * 1024) File.Move(f, f + ".old", true);
                File.AppendAllText(f, sb.ToString());
            }
        }
        catch { }
    }
}
