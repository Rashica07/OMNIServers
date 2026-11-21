using CraftPanel.Core.Updates;
using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Java;
using CraftPanel.Core.Security;

namespace CraftPanel.App.ViewModels;

public enum SettingsTab { General, Account, Java, Backups, Diagnostics, About }

public sealed class SettingsTabItem(SettingsTab tab, Action<SettingsTab> select) : ViewModelBase
{
    bool _active;
    public SettingsTab Tab { get; } = tab;
    public string Label => Tab.ToString();
    public string Icon => Tab switch { SettingsTab.General => "sliders", SettingsTab.Account => "user", SettingsTab.Java => "cpu", SettingsTab.Backups => "archive", SettingsTab.Diagnostics => "activity", _ => "info" };
    public bool IsActive { get => _active; set => Set(ref _active, value); }
    public RelayCommand SelectCommand { get; } = new(() => select(tab));
}

public sealed class ThemeChoice(string name, string label, Palette pal, bool locked) : ViewModelBase
{
    bool _selected;
    public string Name { get; } = name;
    public string Label { get; } = label;
    public Avalonia.Media.IBrush Bg { get; } = Brush(pal.Bg);
    public Avalonia.Media.IBrush Surface { get; } = Brush(pal.Surface2);
    public Avalonia.Media.IBrush Accent { get; } = Brush(pal.Accent);
    public bool Locked { get; } = locked;
    public bool Selected { get => _selected; set => Set(ref _selected, value); }
    static Avalonia.Media.IBrush Brush(uint rgb) => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
}

public sealed class RuntimeRow(JavaInfo info) { public string Title { get; } = $"Java {info.Major}"; public string Path { get; } = info.Path; public string Raw { get; } = info.Raw; }

public sealed class CheckRow(DoctorCheck c)
{
    public string Name { get; } = c.Name; public string Detail { get; } = c.Detail;
    public string Tone { get; } = c.Level switch { CheckLevel.Ok => "ok", CheckLevel.Warn => "warn", _ => "bad" };
    public string Icon { get; } = c.Level switch { CheckLevel.Ok => "check-circle", CheckLevel.Warn => "alert", _ => "alert-octagon" };
}

public sealed class AppSettingsViewModel : ViewModelBase
{
    SettingsTab _tab = SettingsTab.General;
    string _javaMsg = "", _lockMsg = "";
    bool _busy, _checking;

    public ObservableCollection<SettingsTabItem> Tabs { get; } = [];
    public ObservableCollection<ThemeChoice> Themes { get; } = [];
    public ObservableCollection<RuntimeRow> Runtimes { get; } = [];
    public ObservableCollection<CheckRow> Checks { get; } = [];
    AppSettings S => AppServices.Settings;

    public static string[] LightChoices { get; } = ["Automatic (recommended)", "Always light", "Never"];
    public int LightIndex
    {
        get => (int)CraftPanel.Core.Performance.LightMode.Parse(S.LightMode);
        set
        {
            S.LightMode = CraftPanel.Core.Performance.LightMode.Name((CraftPanel.Core.Performance.LightSetting)Math.Clamp(value, 0, 2));
            S.Save(); Raise(nameof(LightIndex)); Raise(nameof(LightStatus));
        }
    }
    /// <summary>What Light mode is doing on this PC right now, and why.</summary>
    public string LightStatus
    {
        get
        {
            var now = CraftPanel.Core.Performance.LightMode.Current;
            var chosen = CraftPanel.Core.Performance.LightMode.Decide(CraftPanel.Core.Performance.LightMode.Parse(S.LightMode), Core.SystemMemory.Current(), CraftPanel.Core.Performance.LightMode.IsRemoteSession());
            return chosen.Reason + (chosen.Active != now.Active || chosen.SoftwareDrawing != now.SoftwareDrawing ? " This applies the next time OMNIServers starts." : "");
        }
    }

    public AppSettingsViewModel()
    {
        foreach (var t in Enum.GetValues<SettingsTab>()) Tabs.Add(new SettingsTabItem(t, Select));
        foreach (var n in Palette.Names) Themes.Add(new ThemeChoice(n, char.ToUpper(n[0]) + n[1..], Palette.ByName(n), false));
        SelectTheme = new RelayCommand(o => { if (o is ThemeChoice t) ApplyTheme(t); });
        InstallJavaCommand = new AsyncCommand(InstallJavaAsync);
        RemoveJavaCommand = new AsyncCommand(RemoveJavaAsync);
        RefreshJavaCommand = new AsyncCommand(RefreshJavaAsync);
        RunChecksCommand = new AsyncCommand(RunChecksAsync);
        CheckUpdateCommand = new AsyncCommand(CheckUpdateAsync, () => !_updating);
        InstallUpdateCommand = new AsyncCommand(InstallUpdateAsync, () => CanInstallUpdate);
        ReportProblemCommand = new AsyncCommand(() => Dialogs.Current.ShowReportAsync());
        SetPinCommand = new AsyncCommand(SetPinAsync);
        RemovePinCommand = new AsyncCommand(RemovePinAsync);
        CopyCommand = new RelayCommand(o => { if (o is string s) { Dialogs.Current.CopyText(s); ToastService.Shared.Show("Copied", "", "copy", "ok", null, 2); } });
        OpenDataCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(AppPaths.DataDir));
        OpenDiscordCommand = new RelayCommand(() => Dialogs.Current.OpenUrl("https://discord.gg/SQwCjE38Jt"));
        OpenSourceCommand = new RelayCommand(() => Dialogs.Current.OpenUrl("https://github.com/Rashica07/OMNIServers"));
        OpenServersCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(AppPaths.EnsureFolder(AppPaths.DefaultServersDir)));
        Select(SettingsTab.General);
        MarkTheme();
        _ = RefreshJavaAsync();
    }

    // ---- updates ---------------------------------------------------------------------------

    UpdateInfo? _update;
    bool _updating;
    string _updateStatus = "";
    public AsyncCommand CheckUpdateCommand { get; }
    public AsyncCommand InstallUpdateCommand { get; }
    public bool AutoCheckUpdates { get => S.AutoCheckUpdates; set { S.AutoCheckUpdates = value; S.Save(); Raise(); } }
    public string UpdateStatus { get => _updateStatus; private set => Set(ref _updateStatus, value); }
    public bool CanInstallUpdate => !_updating && _update is { Newer: true, ZipUrl: not null };
    public string InstallUpdateLabel => _updating ? "Updating…" : $"Update to {_update?.Latest}";
    public bool UpdateBusy => _updating;

    void UpdateChanged() { Raise(nameof(CanInstallUpdate)); Raise(nameof(InstallUpdateLabel)); Raise(nameof(UpdateBusy)); CheckUpdateCommand.RaiseCanExecuteChanged(); InstallUpdateCommand.RaiseCanExecuteChanged(); }

    async Task CheckUpdateAsync()
    {
        _updating = true; UpdateStatus = "Checking…"; UpdateChanged();
        _update = await CraftPanel.Core.Updates.AppUpdater.CheckAsync(CurrentVersion);
        _updating = false;
        UpdateStatus = _update.Unavailable ?? (_update.Newer
            ? (_update.ZipUrl is null ? $"Version {_update.Latest} is out, but it has no download for this PC. Get it from the releases page." : $"Version {_update.Latest} is available.")
            : "You're on the latest version.");
        UpdateChanged();
    }

    async Task InstallUpdateAsync()
    {
        if (_update is not { Newer: true } info || Environment.ProcessPath is not { } exe) return;
        if (AppServices.Processes.AnyRunning) { UpdateStatus = "Stop your servers first, then update. OMNIServers restarts to finish."; return; }
        if (!CraftPanel.Core.Updates.AppUpdater.CanReplace(exe))
        {
            UpdateStatus = "CraftPanel can't replace itself in this folder. Move CraftPanel.exe somewhere you can write (like Documents or the Desktop), or download the new version by hand.";
            if (info.ReleaseUrl is { } u) Dialogs.Current.OpenUrl(u);
            return;
        }
        _updating = true; UpdateChanged();
        try
        {
            var progress = new Progress<ProvisionProgress>(p => UpdateStatus = p.Message);
            var staged = await CraftPanel.Core.Updates.AppUpdater.StageAsync(info, exe, progress);
            CraftPanel.Core.Updates.AppUpdater.Swap(exe, staged);
            UpdateStatus = "Restarting into the new version…";
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe, CraftPanel.Core.Updates.AppUpdater.WaitArg) { UseShellExecute = false, WorkingDirectory = System.IO.Path.GetDirectoryName(exe)! });
            (Avalonia.Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
        }
        catch (Exception e) { UpdateStatus = "The update didn't install: " + e.Message; }
        finally { _updating = false; UpdateChanged(); }
    }

    public SettingsTab Tab => _tab;
    public bool IsGeneral => _tab == SettingsTab.General;
    public bool IsAccount => _tab == SettingsTab.Account;
    public bool IsJava => _tab == SettingsTab.Java;
    public bool IsBackups => _tab == SettingsTab.Backups;
    public bool IsDiagnostics => _tab == SettingsTab.Diagnostics;
    public bool IsAbout => _tab == SettingsTab.About;

    public void Select(SettingsTab t)
    {
        _tab = t;
        foreach (var x in Tabs) x.IsActive = x.Tab == t;
        foreach (var n in new[] { nameof(IsGeneral), nameof(IsAccount), nameof(IsJava), nameof(IsBackups), nameof(IsDiagnostics), nameof(IsAbout) }) Raise(n);
        if (t == SettingsTab.Diagnostics && Checks.Count == 0) _ = RunChecksAsync();
    }

    // ---- general ---------------------------------------------------------------------------

    public double DefaultRam { get => S.DefaultRamMB; set { S.DefaultRamMB = (uint)value; S.Save(); Raise(); } }
    public string DefaultJava { get => S.DefaultJava; set { S.DefaultJava = string.IsNullOrWhiteSpace(value) ? "java" : value.Trim(); S.Save(); Raise(); } }
    public bool KeepOnQuit { get => S.KeepServersOnQuit; set { S.KeepServersOnQuit = value; S.Save(); Raise(); } }
    public bool KeepAwakeSupported => CraftPanel.Core.Power.KeepAwake.Supported;
    public bool StayAwake { get => S.StayAwake; set { S.StayAwake = value; _ = CraftPanel.Core.Power.KeepAwake.ApplyAsync(S); Raise(); } }
    public bool KeepLidClosed { get => S.KeepRunningLidClosed; set { S.KeepRunningLidClosed = value; _ = CraftPanel.Core.Power.KeepAwake.ApplyAsync(S); Raise(); } }
    public bool NotifyJoins { get => S.NotifyJoins; set { S.NotifyJoins = value; S.Save(); Raise(); } }
    public bool NotifyChat { get => S.NotifyChat; set { S.NotifyChat = value; S.Save(); Raise(); } }
    public string ChatName { get => S.ChatName; set { S.ChatName = value; S.Save(); Raise(); Raise(nameof(ChatNameHint)); } }
    public string ChatNameHint => $"Messages you send from the Chat tab show in-game as <{S.EffectiveChatName}> …";
    public bool Expert { get => S.ExpertMode; set { S.ExpertMode = value; S.Save(); Raise(); } }
    public RelayCommand SelectTheme { get; }

    void ApplyTheme(ThemeChoice t)
    {
        S.Theme = t.Name; S.Save();
        Palette.ByName(t.Name).Apply(Avalonia.Application.Current!);
        MarkTheme();
    }

    void MarkTheme() { foreach (var t in Themes) t.Selected = t.Name == S.Theme; }

    // ---- account ---------------------------------------------------------------------------

    public string InstallId => S.InstallId;
    public bool LockSet => AppServices.Lock.IsSet;
    public string LockMessage { get => _lockMsg; private set { Set(ref _lockMsg, value); Raise(nameof(HasLockMessage)); } }
    public bool HasLockMessage => _lockMsg.Length > 0;
    public AsyncCommand SetPinCommand { get; }
    public AsyncCommand RemovePinCommand { get; }
    public RelayCommand CopyCommand { get; }

    async Task SetPinAsync()
    {
        if (LockSet && !await CheckPinAsync("Enter your current PIN")) return;
        var pin = await Dialogs.Current.PromptAsync(LockSet ? "New PIN" : "Set a PIN", "PIN or password (4+ characters)", null, "Save");
        if (pin is null) return;
        try { await Task.Run(() => AppServices.Lock.Set(pin)); LockMessage = "OMNIServers will ask for it each time it opens."; Raise(nameof(LockSet)); }
        catch (Exception e) { LockMessage = e.Message; }
    }

    async Task RemovePinAsync()
    {
        if (!await CheckPinAsync("Enter your PIN to remove it")) return;
        AppServices.Lock.Clear(); LockMessage = "The app lock is off."; Raise(nameof(LockSet));
    }

    async Task<bool> CheckPinAsync(string title)
    {
        var pin = await Dialogs.Current.PromptAsync(title, "PIN", null, "Continue");
        if (pin is null) return false;
        if (await Task.Run(() => AppServices.Lock.Verify(pin))) return true;
        LockMessage = "That PIN isn't right."; return false;
    }

    // ---- java ------------------------------------------------------------------------------

    public string JavaMessage { get => _javaMsg; private set { Set(ref _javaMsg, value); Raise(nameof(HasJavaMessage)); } }
    public bool HasJavaMessage => _javaMsg.Length > 0;
    public uint[] Features => JavaInstaller.Features;
    public AsyncCommand InstallJavaCommand { get; }
    public AsyncCommand RemoveJavaCommand { get; }
    public AsyncCommand RefreshJavaCommand { get; }

    async Task RefreshJavaAsync()
    {
        var list = await JavaProbe.ListRuntimesAsync();
        Ui.Post(() => { Runtimes.Clear(); foreach (var r in list) Runtimes.Add(new RuntimeRow(r)); JavaMessage = list.Count == 0 ? "No Java found on this PC." : ""; });
    }

    async Task InstallJavaAsync(object? p)
    {
        if (p is not uint f) return;
        var last = "";
        var progress = new Progress<ProvisionProgress>(pp => { if (pp.Stage != last) { last = pp.Stage; JavaMessage = pp.Message; } });
        try { await JavaInstaller.InstallAsync(f, progress); JavaMessage = $"Java {f} installed."; }
        catch (Exception e) { JavaMessage = e.Message; }
        await RefreshJavaAsync();
    }

    async Task RemoveJavaAsync(object? p)
    {
        if (p is not uint f) return;
        if (JavaInstaller.InstalledPath(f) is null) { JavaMessage = $"OMNIServers hasn't installed Java {f}."; return; }
        if (!await Dialogs.Current.ConfirmAsync($"Remove Java {f}?", "Only the copy OMNIServers installed is removed. Servers using it get a new Java the next time they start.", "Remove", true)) return;
        try { JavaInstaller.Uninstall(f); JavaMessage = $"Java {f} removed."; } catch (Exception e) { JavaMessage = e.Message; }
        await RefreshJavaAsync();
    }

    // ---- backups ---------------------------------------------------------------------------

    public double BackupKeep { get => S.BackupKeep; set { S.BackupKeep = (int)value; S.Save(); Raise(); } }
    public bool Tiered
    {
        get => S.BackupTiered;
        set
        {
            S.BackupTiered = value; S.Save(); Raise();
        }
    }

    // ---- diagnostics -----------------------------------------------------------------------

    public bool Checking { get => _checking; private set => Set(ref _checking, value); }
    public AsyncCommand RunChecksCommand { get; }
    public AsyncCommand ReportProblemCommand { get; }

    async Task RunChecksAsync()
    {
        Checking = true;
        try { var r = await Doctor.RunAsync(AppPaths.DefaultServersDir); Ui.Post(() => { Checks.Clear(); foreach (var c in r) Checks.Add(new CheckRow(c)); }); }
        finally { Checking = false; }
    }

    // ---- about -----------------------------------------------------------------------------

    public static string CurrentVersion => typeof(AppSettingsViewModel).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "2.6.0";
    public string Version => CurrentVersion;
    public string DataFolder => AppPaths.DataDir;
    public RelayCommand OpenDataCommand { get; }
    public RelayCommand OpenServersCommand { get; }
    public RelayCommand OpenDiscordCommand { get; }
    public RelayCommand OpenSourceCommand { get; }
}
