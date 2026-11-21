using CraftPanel.App.Services;
using CraftPanel.Core;

namespace CraftPanel.App.ViewModels;

/// <summary>The fleet landing page: totals and one card per server.</summary>
public sealed class OverviewViewModel : ViewModelBase
{
    readonly MainViewModel _main;
    public OverviewViewModel(MainViewModel main)
    {
        _main = main;
        OpenCommand = new RelayCommand(o => { if (o is ServerItemViewModel s) _main.Open(s.Id); });
        StartAllCommand = new AsyncCommand(async () =>
        {
            foreach (var s in _main.Servers.Where(s => s.CanStart))
                try { AppServices.Processes.Start(s.Record); } catch (Exception e) { ToastService.Shared.Error($"{s.Name}: {e.Message}"); }
        });
        StopAllCommand = new AsyncCommand(async () =>
        {
            AppServices.Processes.StopAll();
        });
        QuickCreateCommand = new AsyncCommand(QuickCreateAsync, () => !QuickBusy);
        BrowseCommand = new RelayCommand(() => _main.NewServerCommand.Execute(null));
        AppServices.Processes.StateChanged += _ => Ui.Post(Refresh);
    }

    public IEnumerable<ServerItemViewModel> Servers => _main.Servers;
    public bool HasServers => _main.Servers.Count > 0;
    public bool Empty => !HasServers;
    /// <summary>Server cards share the row evenly: one, two or three across.</summary>
    public int GridColumns => Math.Clamp(_main.Servers.Count, 1, 3);
    public int Total => _main.Servers.Count;
    public int Running => _main.Servers.Count(s => s.IsRunning);
    public int PlayersOnline => _main.Servers.Sum(s => s.IsRunning ? s.OnlineCount : 0);
    public string AllocatedText => RamAdvisor.Gb(_main.Servers.Where(s => s.IsRunning).Sum(s => (int)s.Record.RamMB));
    public string Greeting => Running == 0 ? "Nothing running right now." : Running == 1 ? "1 server running." : $"{Running} servers running.";

    // ---- one-click server ------------------------------------------------------------------
    bool _quickBusy; string _quickMessage = "", _quickError = ""; int? _quickPct;
    public bool QuickBusy { get => _quickBusy; private set { if (Set(ref _quickBusy, value)) { Raise(nameof(QuickIdle)); QuickCreateCommand.RaiseCanExecuteChanged(); } } }
    public bool QuickIdle => !QuickBusy;
    public string QuickMessage { get => _quickMessage; private set => Set(ref _quickMessage, value); }
    public string QuickError { get => _quickError; private set { if (Set(ref _quickError, value)) Raise(nameof(HasQuickError)); } }
    public bool HasQuickError => QuickError.Length > 0;
    public int? QuickPct { get => _quickPct; private set { if (Set(ref _quickPct, value)) { Raise(nameof(QuickIndeterminate)); Raise(nameof(QuickValue)); } } }
    public bool QuickIndeterminate => QuickPct is null;
    public double QuickValue => QuickPct ?? 0;
    public AsyncCommand QuickCreateCommand { get; }
    public RelayCommand BrowseCommand { get; }

    async Task QuickCreateAsync()
    {
        QuickError = ""; QuickBusy = true; QuickMessage = "Getting ready…"; QuickPct = null;
        try
        {
            var progress = new Progress<CraftPanel.Core.ProvisionProgress>(p => { QuickMessage = p.Message; QuickPct = p.Pct; });
            var (rec, _) = await QuickServer.CreateAsync(AppServices.Store, AppServices.Settings.DefaultJava, AppPaths.DefaultServersDir, progress);
            ToastService.Shared.Show($"{rec.Name} is ready", "Press Start to launch it.", "check-circle", "ok");
            _main.Open(rec.Id);
        }
        catch (Exception e) { QuickError = e.Message; }
        finally { QuickBusy = false; }
    }

    public RelayCommand OpenCommand { get; }
    public AsyncCommand StartAllCommand { get; }
    public AsyncCommand StopAllCommand { get; }

    public void Refresh()
    {
        Raise(nameof(Servers)); Raise(nameof(GridColumns)); Raise(nameof(HasServers)); Raise(nameof(Empty)); Raise(nameof(Total)); Raise(nameof(Running));
        Raise(nameof(PlayersOnline)); Raise(nameof(AllocatedText)); Raise(nameof(Greeting));
    }
}
