using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Platform;
using Avalonia.Threading;
using CraftPanel.App.Services;
using CraftPanel.App.ViewModels;
using CraftPanel.App.Views;

namespace CraftPanel.App;

public partial class App : Application
{
    IClassicDesktopStyleApplicationLifetime? _desktop;
    MainWindow? _main;
    TrayIcon? _tray;
    bool _quitting;

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        AppServices.Init();
        CrashLog.Install();
        ClickShake.Install();
        var pal = Palette.ByName(AppServices.Settings.Theme);
        pal.Apply(this);

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            _desktop = desktop;
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            desktop.ShutdownRequested += OnShutdownRequested;
            _ = SafeStartAsync();
        }
        base.OnFrameworkInitializationCompleted();
    }

    async Task SafeStartAsync()
    {
        try { await StartAsync(); }
        catch (Exception e)
        {
            CrashLog.Write("startup", e);
            var w = new Window { Title = "OMNIServers", Width = 520, Height = 290, WindowStartupLocation = WindowStartupLocation.CenterScreen };
            w.Content = new StackPanel
            {
                Margin = new Thickness(24), Spacing = 10,
                Children =
                {
                    new TextBlock { Text = "OMNIServers couldn't start", Classes = { "h2" } },
                    new TextBlock { Text = e.Message, TextWrapping = Avalonia.Media.TextWrapping.Wrap },
                    new TextBlock { Text = "Details were saved to " + CrashLog.FilePath, Classes = { "faint", "small" }, TextWrapping = Avalonia.Media.TextWrapping.Wrap },
                    SaveReportButton(e),
                },
            };
            w.Closed += (_, _) => _desktop?.Shutdown();
            w.Show();
        }
    }

    /// <summary>On the start-up failure screen: one click saves a report (no services are up, so it only has this PC and the error).</summary>
    static Button SaveReportButton(Exception e)
    {
        var note = new TextBlock { Classes = { "faint", "small" }, TextWrapping = Avalonia.Media.TextWrapping.Wrap };
        var b = new Button { Content = "Save a report to send", HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left };
        b.Classes.Add("primary");
        b.Click += (_, _) =>
        {
            try
            {
                var input = new CraftPanel.Core.Diagnostics.ReportInput { AppVersion = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "?", IsWine = Program.IsWine(), RenderMode = Program.RenderMode, Error = e.ToString(), Description = "OMNIServers couldn't start." };
                var path = CraftPanel.Core.Diagnostics.ReportBuilder.Save(input);
                b.Content = "Saved: " + System.IO.Path.GetFileName(path);
                b.IsEnabled = false;
                if (b.Parent is StackPanel sp) sp.Children.Add(new TextBlock { Text = "In " + System.IO.Path.GetDirectoryName(path), Classes = { "faint", "small" }, TextWrapping = Avalonia.Media.TextWrapping.Wrap });
            }
            catch (Exception ex) { b.Content = "Couldn't save a report: " + ex.Message; }
        };
        return b;
    }

    async Task StartAsync()
    {
        if (AppServices.Lock.IsSet)
        {
            var lockWin = new LockWindow();
            var closed = new TaskCompletionSource();
            lockWin.Closed += (_, _) => closed.TrySetResult();
            lockWin.Show();
            await closed.Task;
            if (!lockWin.Unlocked) { _desktop!.Shutdown(); return; }
        }
        // Servers that kept running while OMNIServers was closed are re-adopted, not orphaned.
        var adopted = AppServices.Processes.AdoptRunning(AppServices.Store.All);
        _main = new MainWindow();
        _main.Closing += OnMainClosing;
        _desktop!.MainWindow = _main;
        _main.Show();
        SetupTray();
        PlayerNotifier.Background = (title, sub, id) => BackgroundToast.Show(title, sub, () => Dispatcher.UIThread.Post(() => { ShowMain(); if (_main?.DataContext is MainViewModel vm) vm.Open(id, ServerSection.Chat); }));
        if (Environment.ProcessPath is { } self) CraftPanel.Core.Updates.AppUpdater.CleanUp(self);
        if (AppServices.Settings.AutoCheckUpdates) _ = CheckForUpdateQuietlyAsync();
        AppServices.Scheduler.StartAutoStartServers();
        _ = CraftPanel.Core.Power.KeepAwake.ApplyAsync(AppServices.Settings);
        // First launch: offer the tour once (it can always be reopened from Help).
        if (!AppServices.Settings.HelpTourDone && _main.DataContext is MainViewModel mvm) Dispatcher.UIThread.Post(() => mvm.ShowHelp(tour: true), DispatcherPriority.Background);
        if (adopted > 0) ToastService.Shared.Show($"Reconnected to {adopted} running server{(adopted == 1 ? "" : "s")}", "", "link", "ok");
    }

    static async Task CheckForUpdateQuietlyAsync()
    {
        var info = await CraftPanel.Core.Updates.AppUpdater.CheckAsync(CraftPanel.App.ViewModels.AppSettingsViewModel.CurrentVersion);
        if (info.Newer) ToastService.Shared.Show($"OMNIServers {info.Latest} is available", "Settings → General → Updates installs it", "download", "ok", null, 10);
    }

    // ---- window / quit -----------------------------------------------------------------------

    void ShowMain()
    {
        if (_main is null) return;
        _main.Show();
        if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
        _main.Activate();
    }

    async void OnMainClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_quitting) return;
        e.Cancel = true;   // decide first
        if (AppServices.Settings.KeepServersOnQuit || !AppServices.Processes.AnyRunning) { RequestQuit(); return; }
        var n = AppServices.Processes.RunningCount;
        var choice = await AskCloseAsync(n);
        if (choice == CloseChoice.Quit) RequestQuit();
        else if (choice == CloseChoice.Minimize && _main is not null) _main.WindowState = WindowState.Minimized;
    }

    enum CloseChoice { Cancel, Minimize, Quit }

    async Task<CloseChoice> AskCloseAsync(int running)
    {
        var result = CloseChoice.Cancel;
        var win = new Window { Title = "OMNIServers", SizeToContent = SizeToContent.WidthAndHeight, MinWidth = 420, MaxWidth = 520, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var body = new StackPanel { Spacing = 12, Margin = new Thickness(22) };
        body.Children.Add(new TextBlock { Text = running == 1 ? "A server is still running" : $"{running} servers are still running", Classes = { "h2" } });
        body.Children.Add(new TextBlock { Text = "Quitting stops them safely (the world is saved first). Or keep OMNIServers open, minimised, so they keep running.", Classes = { "dim" }, TextWrapping = Avalonia.Media.TextWrapping.Wrap });
        var row = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0) };
        Button Make(string text, string cls, CloseChoice c) { var b = new Button { Content = text }; b.Classes.Add(cls); b.Click += (_, _) => { result = c; win.Close(); }; return b; }
        row.Children.Add(Make("Cancel", "ghost", CloseChoice.Cancel));
        row.Children.Add(Make("Minimise", "ghost", CloseChoice.Minimize));
        row.Children.Add(Make("Stop servers and quit", "primary", CloseChoice.Quit));
        body.Children.Add(row);
        win.Content = body;
        await win.ShowDialog(_main!);
        return result;
    }

    void RequestQuit()
    {
        _quitting = true;
        _desktop?.Shutdown();
    }

    bool _shuttingDown;

    async void OnShutdownRequested(object? sender, ShutdownRequestedEventArgs e)
    {
        if (_shuttingDown) return;
        CraftPanel.Core.Network.TunnelManager.Shared.StopAll();   // a tunnel child would otherwise outlive the app
        if (AppServices.Settings.KeepServersOnQuit || !AppServices.Processes.AnyRunning) { _tray?.Dispose(); return; }
        e.Cancel = true;
        _shuttingDown = true;
        ToastService.Shared.Show("Stopping your servers…", "Saving worlds first", "power", "warn", null, 30);
        await AppServices.Processes.ShutdownAllAsync();
        _tray?.Dispose();
        _quitting = true;
        _desktop!.Shutdown();
    }

    // ---- tray ------------------------------------------------------------------------------

    void SetupTray()
    {
        if (!OperatingSystem.IsWindows()) return;   // macOS/Linux builds are for testing: Avalonia's macOS tray-menu support is flaky and the Mac has its own app
        try
        {
            _tray = new TrayIcon { Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://CraftPanel/Assets/icon.png"))), ToolTipText = "OMNIServers" };
            _tray.Clicked += (_, _) => ShowMain();
            TrayIcon.SetIcons(this, [_tray]);
            RebuildTray();
            AppServices.Processes.StateChanged += _ => Dispatcher.UIThread.Post(RebuildTray);
            AppServices.Processes.PlayerEvent += (_, _, _) => Dispatcher.UIThread.Post(RebuildTray);
            AppServices.Store.Changed += () => Dispatcher.UIThread.Post(RebuildTray);
        }
        catch (Exception e) { CrashLog.Write("tray", e); /* no tray on this system (or under a compatibility layer): the app works without it */ }
    }

    void RebuildTray()
    {
        if (_tray is null) return;
        var menu = new NativeMenu();
        var running = AppServices.Processes.RunningCount;
        var players = AppServices.Processes.TotalOnline;
        _tray.ToolTipText = running == 0 ? "OMNIServers — nothing running" : $"OMNIServers — {running} running, {players} online";
        menu.Add(new NativeMenuItem(running == 0 ? "No servers running" : $"{running} running · {players} player{(players == 1 ? "" : "s")} online") { IsEnabled = false });
        menu.Add(new NativeMenuItemSeparator());
        foreach (var s in AppServices.Store.All)
        {
            var rt = AppServices.Processes.Runtime(s.Id);
            var online = rt.IsRunning ? rt.Online().Count : 0;
            var sub = new NativeMenu();
            var toggle = new NativeMenuItem(rt.IsRunning ? "Stop" : "Start");
            toggle.Click += (_, _) => { try { if (rt.IsRunning) rt.Stop(); else AppServices.Processes.Start(s); } catch (Exception ex) { ToastService.Shared.Error(ex.Message); } };
            var open = new NativeMenuItem("Open"); var id = s.Id;
            open.Click += (_, _) => { ShowMain(); (_main?.DataContext as MainViewModel)?.Open(id); };
            sub.Add(toggle); sub.Add(open);
            menu.Add(new NativeMenuItem($"{(rt.IsRunning ? "[on] " : "")}{s.Name}{(online > 0 ? $" — {online} online" : "")}") { Menu = sub });
        }
        if (AppServices.Store.All.Count > 0) menu.Add(new NativeMenuItemSeparator());
        var openMain = new NativeMenuItem("Open OMNIServers"); openMain.Click += (_, _) => ShowMain();
        var quit = new NativeMenuItem("Quit OMNIServers"); quit.Click += (_, _) => RequestQuit();
        menu.Add(openMain); menu.Add(quit);
        _tray.Menu = menu;
    }
}
