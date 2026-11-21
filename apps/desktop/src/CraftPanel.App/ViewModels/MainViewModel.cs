using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Help;

namespace CraftPanel.App.ViewModels;

public sealed class MainViewModel : ViewModelBase
{
    ServerItemViewModel? _selected;
    ViewModelBase _content;
    bool _onOverview = true, _onSettings;

    public ObservableCollection<ServerItemViewModel> Servers { get; } = [];
    public ToastService Toasts => ToastService.Shared;

    public OverviewViewModel Overview { get; }
    AppSettingsViewModel? _settingsVm;

    public MainViewModel()
    {
        Overview = new OverviewViewModel(this);
        _content = Overview;
        Reload();
        AppServices.Store.Changed += () => Ui.Post(Reload);
        AppServices.Processes.PlayerEvent += OnPlayerEvent;
        ShowOverviewCommand = new RelayCommand(ShowOverview);
        ShowSettingsCommand = new RelayCommand(ShowSettings);
        ShowHelpCommand = new RelayCommand(() => ShowHelp());
        ShowShortcutsCommand = new RelayCommand(() => _ = Dialogs.Current.ConfirmAsync("Keyboard shortcuts", ShortcutsText, "Got it"));
        ReportIssueCommand = new RelayCommand(() =>
        {
            var crash = CraftPanel.Core.Diagnostics.ReportBuilder.RedactedTail(CraftPanel.App.Services.CrashLog.FilePath);
            var server = Selected is { } sel ? CraftPanel.Core.Diagnostics.ReportBuilder.RedactedTail(System.IO.Path.Combine(sel.Record.Dir, "logs", "latest.log")) : "";
            Dialogs.Current.OpenUrl(CraftPanel.Core.Diagnostics.ReportBuilder.NewIssueUrl(typeof(MainViewModel).Assembly.GetName().Version?.ToString(3) ?? "?", crash, server));
        });
        NewServerCommand = new AsyncCommand(() => Wizard(WizardMode.Custom));
        QuickStartCommand = new AsyncCommand(() => Wizard(WizardMode.QuickStart));
        ModpackCommand = new AsyncCommand(() => Wizard(WizardMode.Modpack));
        AddExistingCommand = new AsyncCommand(AddExistingAsync);
    }

    public ViewModelBase Content { get => _content; private set => Set(ref _content, value); }
    public bool OnOverview { get => _onOverview; private set => Set(ref _onOverview, value); }
    public bool SidebarCollapsed
    {
        get => AppServices.Settings.SidebarCollapsed;
        set { AppServices.Settings.SidebarCollapsed = value; AppServices.Settings.Save(); Raise(); Raise(nameof(SidebarExpanded)); }
    }
    public bool SidebarExpanded => !SidebarCollapsed;
    public RelayCommand ToggleSidebarCommand => new(() => SidebarCollapsed = !SidebarCollapsed);
    public bool OnSettings { get => _onSettings; private set => Set(ref _onSettings, value); }
    public bool HasServers => Servers.Count > 0;
    public int RunningCount => Servers.Count(s => s.IsRunning);

    public ServerItemViewModel? Selected
    {
        get => _selected;
        set
        {
            if (!Set(ref _selected, value) || value is null) return;
            OnOverview = false; OnSettings = false;
            Content = new ServerDetailViewModel(value, this);
        }
    }

    public RelayCommand ShowOverviewCommand { get; }
    public RelayCommand ShowSettingsCommand { get; }
    public RelayCommand ShowHelpCommand { get; }
    public RelayCommand ShowShortcutsCommand { get; }
    public const string ShortcutsText = "Ctrl+N   New server\nCtrl+0   Overview\nCtrl+,   App settings\nCtrl+/   This list\nF1   Help\n\nIn the console: Up and Down step through earlier commands.";
    public RelayCommand ReportIssueCommand { get; }
    public AsyncCommand NewServerCommand { get; }
    public AsyncCommand QuickStartCommand { get; }
    public AsyncCommand ModpackCommand { get; }
    public AsyncCommand AddExistingCommand { get; }

    // ---- help ------------------------------------------------------------------------------------------

    /// <summary>The help page id for whatever is on screen right now.</summary>
    public string CurrentHelpPage() => Content switch
    {
        ServerDetailViewModel d => HelpPages.ForServerSection(d.Current.ToString()),
        AppSettingsViewModel s => HelpPages.ForSettingsTab(s.Tab.ToString()),
        _ => HelpPages.Overview,
    };

    /// <summary>Opens Help on the current page (or on the full tour).</summary>
    public void ShowHelp(bool tour = false) => Dialogs.Current.ShowHelp(CurrentHelpPage(), tour, RunHelpAction);

    /// <summary>The buttons inside the guides: take the user to the tab/page the step is about.</summary>
    public void RunHelpAction(HelpAction a)
    {
        switch (a.Kind)
        {
            case HelpActionKind.Section:
                var target = Selected ?? Servers.FirstOrDefault();
                if (target is null) { ToastService.Shared.Show("Make a server first", "Press New server at the bottom left.", "info", "warn"); return; }
                if (Enum.TryParse<ServerSection>(a.Arg, out var sec)) Open(target.Id, sec);
                break;
            case HelpActionKind.SettingsTab:
                ShowSettings();
                if (Enum.TryParse<SettingsTab>(a.Arg, out var tab) && Content is AppSettingsViewModel sv) sv.Select(tab);
                break;
            case HelpActionKind.Overview: ShowOverview(); break;
            case HelpActionKind.NewServer: NewServerCommand.Execute(null); break;
            case HelpActionKind.Copy: Dialogs.Current.CopyText(a.Arg); ToastService.Shared.Show("Copied", a.Arg, "copy", "ok", null, 2); break;
            case HelpActionKind.ReportProblem: _ = Dialogs.Current.ShowReportAsync(); break;
        }
    }

    public void ShowOverview()
    {
        _selected = null; Raise(nameof(Selected));
        OnOverview = true; OnSettings = false;
        Content = Overview;
        Overview.Refresh();
    }

    public void ShowSettings()
    {
        _selected = null; Raise(nameof(Selected));
        OnOverview = false; OnSettings = true;
        Content = _settingsVm ??= new AppSettingsViewModel();
    }

    public void Open(Guid id, ServerSection? section = null)
    {
        var item = Servers.FirstOrDefault(s => s.Id == id);
        if (item is null) return;
        Selected = item;
        if (section is { } sec && Content is ServerDetailViewModel d) d.Select(sec);
    }

    /// <summary>Keeps the sidebar in step with servers.json, keeping existing item objects (and the selection) where possible.</summary>
    public void Reload()
    {
        var records = AppServices.Store.All;
        foreach (var gone in Servers.Where(s => records.All(r => r.Id != s.Id)).ToList()) Servers.Remove(gone);
        foreach (var r in records)
            if (Servers.All(s => s.Id != r.Id)) Servers.Add(new ServerItemViewModel(r));
        Raise(nameof(HasServers)); Raise(nameof(RunningCount));
        if (_selected is not null && Servers.All(s => s.Id != _selected.Id)) ShowOverview();
        Overview.Refresh();
    }

    async Task Wizard(WizardMode mode)
    {
        if (await Dialogs.Current.ShowCreateWizardAsync(mode) is { } id) Open(id);
    }

    async Task AddExistingAsync()
    {
        var folder = await Dialogs.Current.PickFolderAsync("Choose an existing server folder");
        if (folder is null) return;
        await AddFolderAsync(folder);
    }

    /// <summary>Adds the server in <paramref name="folder"/> (picked or dropped): detect, confirm, repair, open.</summary>
    public async Task AddFolderAsync(string folder)
    {
        var result = await ServerDetector.DetectAsync(folder);
        if (!result.Detected)
        {
            await Dialogs.Current.ShowMessageAsync("No server found", string.Join("\n", result.Warnings));
            return;
        }
        var note = result.Warnings.Count > 0 ? "\n\n" + string.Join("\n", result.Warnings) : "";
        var summary = $"{result.ServerType!.Value.Label()}{(result.McVersion is null ? "" : " " + result.McVersion)} — {string.Join(", ", result.Evidence)}{note}";
        if (!await Dialogs.Current.ConfirmAsync("Add this server?", summary, "Add server")) return;
        var rec = new ServerRecord
        {
            Name = Path.GetFileName(folder.TrimEnd('/', '\\')), Path = folder, ServerType = result.ServerType!.Value,
            LaunchTarget = result.LaunchTarget!, McVersion = result.McVersion, JavaPath = result.Java?.Path ?? AppServices.Settings.DefaultJava,
            RamMB = AppServices.Settings.DefaultRamMB,
        };
        if (rec.ServerType.IsGame())
        {
            var fix = GameServers.Fix(rec.ServerType, folder, rec.Name);
            AppServices.Store.Add(rec);
            Open(rec.Id);
            var lines = fix.Done.Concat(fix.ToDo.Select(t => "To do: " + t)).ToList();
            if (lines.Count > 0) await Dialogs.Current.ShowMessageAsync("Set up " + rec.ServerType.Label(), string.Join("\n\n", lines));
            return;
        }
        AppServices.Store.Add(rec);
        Open(rec.Id);
    }

    void OnPlayerEvent(Core.Runtime.ServerRuntime rt, Core.Runtime.LiveEvent ev, int online)
    {
        PlayerNotifier.Handle(rt, ev, online);
    }
}
