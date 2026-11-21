using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Runtime;

namespace CraftPanel.Tests;

/// <summary>Renders a control/window to PNG (headless Skia) so screens can be reviewed without a display.</summary>
public static class Shot
{
    public static string Dir => Environment.GetEnvironmentVariable("CP_SHOTS") ?? Path.Combine(Path.GetTempPath(), "cp-shots");

    public static string Save(Window window, string name)
    {
        window.Show();
        for (var i = 0; i < 4; i++) { Dispatcher.UIThread.RunJobs(); AvaloniaHeadlessPlatform.ForceRenderTimerTick(); }
        var frame = window.CaptureRenderedFrame() ?? throw new InvalidOperationException("no frame");
        Directory.CreateDirectory(Dir);
        var path = Path.Combine(Dir, name + ".png");
        frame.Save(path);
        return path;
    }

    public static Window Host(Control content, double w, double h, string? theme = null)
    {
        if (theme is not null) CraftPanel.App.Services.Palette.ByName(theme).Apply(Application.Current!);
        return new Window { Width = w, Height = h, Content = content, Background = null };
    }

    /// <summary>Fresh, isolated services with a few seeded servers.</summary>
    public static TempDir Seed(bool withServers = true)
    {
        var t = new TempDir();
        AppPaths.DataOverride = t.Path;
        var settings = AppSettings.Load(Path.Combine(t.Path, "settings.json"));
        var store = new ServerStore(Path.Combine(t.Path, "servers.json"));
        var pm = new ProcessManager();
        AppServices.InitForTests(store, settings, pm);
        if (withServers)
        {
            foreach (var (name, type, ver, ram) in new[] { ("MCServ", ServerType.Fabric, "26.2", 4096u), ("Survival SMP", ServerType.Paper, "1.21.1", 6144u), ("Modded", ServerType.NeoForge, "1.21.1", 8192u) })
            {
                var dir = Path.Combine(t.Path, "servers", name); Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "server.properties"), "server-port=25565\nmotd=Hello\nmax-players=20\ndifficulty=normal\ngamemode=survival\nonline-mode=true\n");
                store.Add(new ServerRecord { Name = name, Path = dir, ServerType = type, McVersion = ver, LaunchTarget = "server.jar", RamMB = ram });
            }
        }
        return t;
    }
}
