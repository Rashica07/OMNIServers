using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Java;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

public sealed class ServerSettingsViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    readonly ServerDetailViewModel? _detail;
    string _name, _java, _jvm, _motd = "", _difficulty = "normal", _gamemode = "survival", _javaStatus = "Checking Java…", _raw = "", _rconStatus = "";
    double _ram, _maxPlayers = 20, _port = 25565, _viewDistance = 10;
    bool _pvp = true, _whitelist, _allowFlight, _commandBlocks, _dirty, _loading;
    bool _restartOnCrash, _dailyOn, _backupOnStop, _autoStart, _snapOn;
    double _snapMins = 15, _snapRecent = 24, _snapDaily = 30;
    double _maxCrash = 3;
    string _dailyAt = "04:00";

    public static string[] Difficulties { get; } = ["peaceful", "easy", "normal", "hard"];
    public static string[] Gamemodes { get; } = ["survival", "creative", "adventure", "spectator"];

    public ServerItemViewModel Server => _server;
    ServerRecord R => _server.Record;

    public ServerSettingsViewModel(ServerItemViewModel server, ServerDetailViewModel? detail = null)
    {
        _server = server; _detail = detail;
        _name = R.Name; _java = R.JavaPath; _jvm = R.JvmArgs ?? ""; _ram = R.RamMB;
        LoadSchedule();
        LoadProperties();
        SaveCommand = new AsyncCommand(SaveAsync, () => Dirty);
        DiscardCommand = new RelayCommand(Discard);
        LowSpecCommand = new AsyncCommand(LowSpecAsync);
        AikarCommand = new RelayCommand(() => JvmArgs = JvmArgsPreset());
        InstallJavaCommand = new AsyncCommand(InstallJavaAsync);
        BrowseJavaCommand = new AsyncCommand(BrowseJavaAsync);
        AutoJavaCommand = new RelayCommand(() => JavaPath = "java");
        EnableRconCommand = new RelayCommand(EnableRcon);
        SaveRawCommand = new RelayCommand(SaveRaw);
        RemoveCommand = new AsyncCommand(RemoveAsync);
        DeleteFilesCommand = new AsyncCommand(DeleteFilesAsync);
        AcceptEulaCommand = new AsyncCommand(async () => { await File.WriteAllTextAsync(Path.Combine(R.Path, "eula.txt"), "# Accepted via OMNIServers — https://aka.ms/MinecraftEULA\neula=true\n"); ToastService.Shared.Show("EULA accepted", "", "check-circle", "ok"); });
        server.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ServerItemViewModel.IsRunning)) { Raise(nameof(Locked)); Raise(nameof(LockedNote)); Raise(nameof(CanEdit)); } };
        RefreshRcon();
        _ = RefreshJavaAsync();
    }

    public bool Locked => _server.IsRunning;
    public bool CanEdit => !Locked;
    public string LockedNote => Locked ? "Stop the server to change its Java, memory or port." : "";
    public bool IsBedrock => R.ServerType.IsBedrock();
    public bool IsJava => !IsBedrock;
    public bool ExpertMode => AppServices.Settings.ExpertMode;
    public RamKind RamKind => RamAdvisor.KindFor(R.ServerType);
    public string LaunchTarget => R.LaunchTarget;
    public string FolderPath => R.Path;
    public string TypeLine => $"{R.ServerType.Label()}{(R.McVersion is null ? "" : " " + R.McVersion)}";

    public bool Dirty { get => _dirty; private set { if (Set(ref _dirty, value)) SaveCommand.RaiseCanExecuteChanged(); } }

    T Edit<T>(ref T field, T value, string name) { if (!_loading && !EqualityComparer<T>.Default.Equals(field, value)) Dirty = true; Set(ref field, value, name); return field; }

    public string Name { get => _name; set { Edit(ref _name, value, nameof(Name)); } }
    public string JavaPath { get => _java; set { if (Edit(ref _java, value, nameof(JavaPath)) == value) _ = RefreshJavaAsync(); } }
    public string JvmArgs { get => _jvm; set { Edit(ref _jvm, value, nameof(JvmArgs)); Raise(nameof(LaunchPreview)); } }
    public double RamMB { get => _ram; set { Edit(ref _ram, value, nameof(RamMB)); Raise(nameof(LaunchPreview)); } }
    public string Motd { get => _motd; set => Edit(ref _motd, value, nameof(Motd)); }
    public double MaxPlayers { get => _maxPlayers; set => Edit(ref _maxPlayers, value, nameof(MaxPlayers)); }
    public double Port { get => _port; set => Edit(ref _port, value, nameof(Port)); }
    public double ViewDistance { get => _viewDistance; set => Edit(ref _viewDistance, value, nameof(ViewDistance)); }
    public string Difficulty { get => _difficulty; set => Edit(ref _difficulty, value, nameof(Difficulty)); }
    public string Gamemode { get => _gamemode; set => Edit(ref _gamemode, value, nameof(Gamemode)); }
    public bool Pvp { get => _pvp; set => Edit(ref _pvp, value, nameof(Pvp)); }
    public bool Whitelist { get => _whitelist; set => Edit(ref _whitelist, value, nameof(Whitelist)); }
    public bool AllowFlight { get => _allowFlight; set => Edit(ref _allowFlight, value, nameof(AllowFlight)); }
    public bool CommandBlocks { get => _commandBlocks; set => Edit(ref _commandBlocks, value, nameof(CommandBlocks)); }
    public bool RestartOnCrash { get => _restartOnCrash; set => Edit(ref _restartOnCrash, value, nameof(RestartOnCrash)); }
    public double MaxCrashRestarts { get => _maxCrash; set => Edit(ref _maxCrash, value, nameof(MaxCrashRestarts)); }
    public bool SnapshotsOn { get => _snapOn; set { Edit(ref _snapOn, value, nameof(SnapshotsOn)); Raise(nameof(SnapshotSummary)); } }
    public double SnapshotMins { get => _snapMins; set { Edit(ref _snapMins, value, nameof(SnapshotMins)); Raise(nameof(SnapshotSummary)); } }
    public double SnapshotRecentHours { get => _snapRecent; set { Edit(ref _snapRecent, value, nameof(SnapshotRecentHours)); Raise(nameof(SnapshotSummary)); } }
    public double SnapshotDailyDays { get => _snapDaily; set { Edit(ref _snapDaily, value, nameof(SnapshotDailyDays)); Raise(nameof(SnapshotSummary)); } }
    public string SnapshotSummary => $"A snapshot of the world every {_snapMins:0} min while the server runs. Keeps all from the last {_snapRecent:0} h, then one a day for {_snapDaily:0} days.";
    public bool DailyRestartOn { get => _dailyOn; set => Edit(ref _dailyOn, value, nameof(DailyRestartOn)); }
    public string DailyRestartAt { get => _dailyAt; set => Edit(ref _dailyAt, value, nameof(DailyRestartAt)); }
    public bool BackupOnStop { get => _backupOnStop; set => Edit(ref _backupOnStop, value, nameof(BackupOnStop)); }
    string _onStart = "";
    /// <summary>One command per line, sent each time the server finishes starting.</summary>
    public string OnStartText { get => _onStart; set => Edit(ref _onStart, value ?? "", nameof(OnStartText)); }
    public bool AutoStartWithApp { get => _autoStart; set => Edit(ref _autoStart, value, nameof(AutoStartWithApp)); }

    void LoadSchedule()
    {
        var c = R.Schedule;
        _restartOnCrash = c.RestartOnCrash; _maxCrash = c.MaxCrashRestarts; _dailyOn = c.DailyRestart is not null; _dailyAt = c.DailyRestart ?? "04:00";
        _onStart = string.Join("\n", c.OnStartCommands); _backupOnStop = c.BackupOnStop; _autoStart = c.AutoStartWithApp;
        _snapOn = c.SnapshotIntervalMins is > 0; _snapMins = c.SnapshotIntervalMins ?? 15; _snapRecent = c.SnapshotRecentHours; _snapDaily = c.SnapshotDailyDays;
    }

    public string JavaStatus { get => _javaStatus; private set => Set(ref _javaStatus, value); }
    public string RawProperties { get => _raw; set => Set(ref _raw, value); }
    public string RconStatus { get => _rconStatus; private set => Set(ref _rconStatus, value); }

    public string LaunchPreview
    {
        get
        {
            try
            {
                var tmp = new ServerRecord { Path = R.Path, LaunchTarget = R.LaunchTarget, JavaPath = _java, RamMB = (uint)_ram, ServerType = R.ServerType, JvmArgs = _jvm };
                return Core.Adapters.JvmArgs.Describe(tmp);
            }
            catch (Exception e) { return e.Message; }
        }
    }

    string JvmArgsPreset() => Core.Adapters.JvmArgs.AikarFlags((uint)_ram);

    public RelayCommand DiscardCommand { get; }
    public AsyncCommand LowSpecCommand { get; }

    /// <summary>Shows what would change, then lowers view/simulation distance in server.properties.</summary>
    async Task LowSpecAsync()
    {
        if (Locked) { ToastService.Shared.Error("Stop the server first — these settings apply when it starts."); return; }
        if (Dirty && !await Dialogs.Current.ConfirmAsync("Unsaved changes", "You have unsaved changes on this page. Save them first, then lighten the server.", "OK")) return;
        var plan = Core.Performance.LowSpecPreset.Plan(Properties.Load(R.Path), R.ServerType);
        if (plan.Count == 0) { ToastService.Shared.Show("Already light", "View and simulation distance are already low.", "check-circle", "ok"); return; }
        var list = string.Join("\n", plan.Select(c => $"• {c.Key}: {c.From ?? "default"} → {c.To}  ({c.Why})"));
        if (!await Dialogs.Current.ConfirmAsync("Lighten this server?", $"These settings make the server easier on a small PC:\n\n{list}\n\nWorlds look a little less far away. You can change them back here any time.", "Apply")) return;
        Core.Performance.LowSpecPreset.Apply(Properties.Load(R.Path), plan);
        LoadProperties();
        ToastService.Shared.Show("Server lightened", "Takes effect the next time it starts.", "check-circle", "ok");
    }
    public AsyncCommand SaveCommand { get; }
    public RelayCommand AikarCommand { get; }
    public AsyncCommand InstallJavaCommand { get; }
    public AsyncCommand BrowseJavaCommand { get; }
    public RelayCommand AutoJavaCommand { get; }
    public RelayCommand EnableRconCommand { get; }
    public RelayCommand SaveRawCommand { get; }
    public AsyncCommand RemoveCommand { get; }
    public AsyncCommand DeleteFilesCommand { get; }
    public AsyncCommand AcceptEulaCommand { get; }

    // ---- server.properties ---------------------------------------------------------------

    string MotdKey => IsBedrock ? "server-name" : "motd";

    void LoadProperties()
    {
        _loading = true;
        var p = Properties.Load(R.Path);
        Motd = p.GetOr(MotdKey, "");
        MaxPlayers = p.GetInt("max-players", 20);
        Port = p.GetInt("server-port", IsBedrock ? 19132 : 25565);
        ViewDistance = p.GetInt("view-distance", 10);
        Difficulty = p.GetOr("difficulty", "normal");
        Gamemode = p.GetOr("gamemode", "survival");
        Pvp = p.GetBool("pvp", true);
        Whitelist = p.GetBool("white-list", false);
        AllowFlight = p.GetBool("allow-flight", false);
        CommandBlocks = p.GetBool("enable-command-block", false);
        RawProperties = File.Exists(Path.Combine(R.Path, "server.properties")) ? File.ReadAllText(Path.Combine(R.Path, "server.properties")) : "";
        _loading = false;
        Raise(nameof(HasProperties));
    }

    public bool HasProperties => File.Exists(Path.Combine(R.Path, "server.properties"));

    void Discard()
    {
        _loading = true;
        Name = R.Name; JavaPath = R.JavaPath; JvmArgs = R.JvmArgs ?? ""; RamMB = R.RamMB;
        _loading = false;
        LoadSchedule();
        foreach (var n in new[] { nameof(RestartOnCrash), nameof(MaxCrashRestarts), nameof(DailyRestartOn), nameof(DailyRestartAt), nameof(BackupOnStop), nameof(OnStartText), nameof(AutoStartWithApp), nameof(SnapshotsOn), nameof(SnapshotMins), nameof(SnapshotRecentHours), nameof(SnapshotDailyDays), nameof(SnapshotSummary) }) Raise(n);
        LoadProperties();
        Dirty = false;
    }

    async Task SaveAsync()
    {
        var newName = Name.Trim();
        if (newName.Length == 0) { ToastService.Shared.Error("Give the server a name."); return; }
        R.Name = newName;
        R.JavaPath = string.IsNullOrWhiteSpace(JavaPath) ? "java" : JavaPath.Trim();
        R.JvmArgs = string.IsNullOrWhiteSpace(JvmArgs) ? null : JvmArgs.Trim();
        R.RamMB = (uint)RamMB;
        if (DailyRestartOn && !TimeOnly.TryParse(DailyRestartAt, out _)) { ToastService.Shared.Error("Enter the daily restart time like 04:00."); return; }
        R.Schedule.RestartOnCrash = RestartOnCrash; R.Schedule.MaxCrashRestarts = (int)MaxCrashRestarts; R.Schedule.BackupOnStop = BackupOnStop;
        R.Schedule.OnStartCommands = OnStartText.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(l => l.TrimStart('/')).ToList();
        R.Schedule.AutoStartWithApp = AutoStartWithApp;
        R.Schedule.SnapshotIntervalMins = SnapshotsOn ? Math.Max(5, (int)SnapshotMins) : null;
        R.Schedule.SnapshotKeepRecentHours = (int)SnapshotRecentHours; R.Schedule.SnapshotKeepDailyDays = (int)SnapshotDailyDays;
        R.Schedule.DailyRestart = DailyRestartOn ? TimeOnly.Parse(DailyRestartAt).ToString("HH:mm") : null;
        if (HasProperties)
        {
            var p = Properties.Load(R.Path);
            p.Set(MotdKey, Motd); p.Set("max-players", ((int)MaxPlayers).ToString()); p.Set("difficulty", Difficulty); p.Set("gamemode", Gamemode);
            if (!IsBedrock)
            {
                p.Set("pvp", Pvp ? "true" : "false"); p.Set("white-list", Whitelist ? "true" : "false"); p.Set("allow-flight", AllowFlight ? "true" : "false");
                p.Set("enable-command-block", CommandBlocks ? "true" : "false"); p.Set("view-distance", ((int)ViewDistance).ToString());
            }
            if (!Locked) p.Set("server-port", ((int)Port).ToString());
            p.Save();
            RawProperties = File.ReadAllText(Path.Combine(R.Path, "server.properties"));
            Raise(nameof(RawProperties));
        }
        AppServices.Store.Update(R);
        _server.Refresh();
        Dirty = false;
        ToastService.Shared.Show("Settings saved", Locked ? "Restart the server for property changes to apply." : "", "check-circle", "ok");
        await Task.CompletedTask;
    }

    // ---- Java ----------------------------------------------------------------------------

    public async Task RefreshJavaAsync()
    {
        if (IsBedrock) { JavaStatus = "Bedrock servers don't use Java."; return; }
        var path = JavaProbe.AutoResolve(_java, R.McVersion) ?? _java;
        var info = await JavaProbe.ProbeAsync(path);
        var need = R.McVersion is { } mc ? JavaProbe.RequiredJava(mc) : 0;
        Ui.Post(() => JavaStatus = info is null ? $"Java wasn't found{(need > 0 ? $" — this server needs Java {need}+" : "")}."
            : $"Java {info.Major}{(need > 0 && info.Major < need ? $" — too old, needs {need}+" : "")} · {info.Path}");
    }

    async Task InstallJavaAsync()
    {
        var need = R.McVersion is { } mc ? JavaProbe.RequiredJava(mc) : 21;
        if (JavaInstaller.OfferableFeature(need) is not { } f) { ToastService.Shared.Error($"Java {need} can't be auto-installed. Install a matching JDK yourself and browse to it."); return; }
        var last = "";
        var progress = new Progress<ProvisionProgress>(p => { if (p.Stage != last) { last = p.Stage; JavaStatus = p.Message; } });
        var info = await JavaInstaller.InstallAsync(f, progress);
        JavaPath = info.Path;
        await RefreshJavaAsync();
    }

    async Task BrowseJavaAsync()
    {
        var files = await Dialogs.Current.PickFilesAsync("Choose java" + Platform.ExeSuffix);
        if (files.Count > 0) JavaPath = files[0];
    }

    // ---- RCON ----------------------------------------------------------------------------

    void RefreshRcon()
    {
        var p = Properties.Load(R.Path);
        RconStatus = !p.Existed ? "Start the server once so it can generate server.properties."
            : p.GetOr("enable-rcon", "false") == "true" ? $"On · port {p.GetOr("rcon.port", "25575")} · used for player actions and the Players tab"
            : "Off — OMNIServers turns it on automatically when the server starts.";
    }

    void EnableRcon()
    {
        try { var (changed, port) = RconService.Setup(R); RefreshRcon(); ToastService.Shared.Show(changed.Count == 0 ? "RCON was already set up" : "RCON enabled", Locked ? "Restart the server to apply." : $"Port {port}", "check-circle", "ok"); }
        catch (Exception e) { ToastService.Shared.Error(e.Message); }
    }

    void SaveRaw()
    {
        try { AppPaths.WriteAtomic(Path.Combine(R.Path, "server.properties"), RawProperties); LoadProperties(); Dirty = false; ToastService.Shared.Show("server.properties saved", "", "check-circle", "ok"); }
        catch (Exception e) { ToastService.Shared.Error(e.Message); }
    }

    // ---- removal ---------------------------------------------------------------------------

    async Task RemoveAsync()
    {
        if (Locked) { ToastService.Shared.Error("Stop the server first."); return; }
        if (!await Dialogs.Current.ConfirmAsync($"Remove {R.Name}?", "The server disappears from OMNIServers but its folder and world stay exactly where they are. You can add it again any time.", "Remove", true)) return;
        AppServices.Store.Remove(R.Id);
    }

    async Task DeleteFilesAsync()
    {
        if (Locked) { ToastService.Shared.Error("Stop the server first."); return; }
        if (!await Dialogs.Current.ConfirmAsync($"Delete {R.Name} and its files?", $"The folder\n{R.Path}\nis moved to a \".craftpanel-trash\" folder next to it (not permanently deleted), and the server is removed from OMNIServers.", "Move to trash", true)) return;
        try
        {
            var parent = Path.GetDirectoryName(R.Path.TrimEnd('/', '\\'))!;
            FileOps.MoveToTrash(R.Path, Path.Combine(parent, ".craftpanel-trash"));
            AppServices.Store.Remove(R.Id);
        }
        catch (Exception e) { ToastService.Shared.Error("Couldn't move the folder: " + e.Message); }
    }
}
