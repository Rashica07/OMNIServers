using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Addons;

namespace CraftPanel.App.ViewModels;

public enum MapState { Unsupported, NotInstalled, NeedsConsent, Stopped, NeedsRestart, Starting, Up }

public sealed class MapViewModel : ViewModelBase, IDisposable
{
    readonly ServerItemViewModel _server;
    readonly CancellationTokenSource _cts = new();
    MapState _state;
    bool _agreed, _installed, _consent, _needsRestart, _up;
    string _busy = "", _error = "";
    int _port = BlueMap.DefaultPort;

    ServerRecord R => _server.Record;

    public MapViewModel(ServerItemViewModel server)
    {
        _server = server;
        InstallCommand = new AsyncCommand(InstallAsync, () => Agreed && _busy.Length == 0);
        ConsentCommand = new AsyncCommand(ConsentAsync, () => Agreed);
        RestartCommand = new AsyncCommand(RestartAsync, () => _busy.Length == 0);
        OpenCommand = new RelayCommand(() => Dialogs.Current.OpenUrl(BlueMap.LocalUrl(_port)));
        CopyLinkCommand = new RelayCommand(() => { Dialogs.Current.CopyText(LanLink); ToastService.Shared.Show("Map link copied", LanLink, "copy", "ok", null, 2); });
        Refresh();
        _ = PollAsync();
    }

    public MapState State { get => _state; private set { if (Set(ref _state, value)) foreach (var n in new[] { nameof(IsUnsupported), nameof(IsNotInstalled), nameof(IsNeedsConsent), nameof(IsStopped), nameof(IsNeedsRestart), nameof(IsStarting), nameof(IsUp) }) Raise(n); } }
    public bool IsUnsupported => State == MapState.Unsupported;
    public bool IsNotInstalled => State == MapState.NotInstalled;
    public bool IsNeedsConsent => State == MapState.NeedsConsent;
    public bool IsStopped => State == MapState.Stopped;
    public bool IsNeedsRestart => State == MapState.NeedsRestart;
    public bool IsStarting => State == MapState.Starting;
    public bool IsUp => State == MapState.Up;

    public bool Agreed { get => _agreed; set { if (Set(ref _agreed, value)) { InstallCommand.RaiseCanExecuteChanged(); ConsentCommand.RaiseCanExecuteChanged(); } } }
    public string Busy { get => _busy; private set { Set(ref _busy, value); Raise(nameof(HasBusy)); InstallCommand.RaiseCanExecuteChanged(); RestartCommand.RaiseCanExecuteChanged(); } }
    public bool HasBusy => _busy.Length > 0;
    public string Error { get => _error; private set { Set(ref _error, value); Raise(nameof(HasError)); } }
    public bool HasError => _error.Length > 0;
    public string LocalLink => BlueMap.LocalUrl(_port);
    public string LanLink => Net.LanIp() is { } ip ? $"http://{ip}:{_port}" : LocalLink;
    public string UnsupportedText => R.ServerType.IsBedrock() ? "Bedrock servers can't run BlueMap."
        : "Vanilla servers can't load add-ons. Switch this server to Paper or Fabric with Change version (the ⋯ menu) — your world stays — and the live map becomes available.";

    public AsyncCommand InstallCommand { get; }
    public AsyncCommand ConsentCommand { get; }
    public AsyncCommand RestartCommand { get; }
    public RelayCommand OpenCommand { get; }
    public RelayCommand CopyLinkCommand { get; }

    void Refresh()
    {
        var dir = R.Path;
        _installed = BlueMap.IsInstalled(dir, R.ServerType);
        _consent = BlueMap.ConsentGiven(dir, R.ServerType);
        _port = BlueMap.Port(dir, R.ServerType);
        State = !BlueMap.Supported(R.ServerType) ? MapState.Unsupported
            : !_installed ? MapState.NotInstalled
            : !_consent ? MapState.NeedsConsent
            : !_server.IsRunning ? MapState.Stopped
            : _needsRestart && !_up ? MapState.NeedsRestart
            : _up ? MapState.Up : MapState.Starting;
        Raise(nameof(LocalLink)); Raise(nameof(LanLink));
    }

    async Task PollAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            _up = _installed && _consent && _server.IsRunning && await BlueMap.IsUpAsync(_port);
            if (_up) _needsRestart = false;
            Ui.Post(Refresh);
            try { await Task.Delay(_up ? 10_000 : 2_000, _cts.Token); } catch { return; }
        }
    }

    List<(string, ServerType)> Others() => AppServices.Store.All.Where(s => s.Id != R.Id).Select(s => (s.Path, s.ServerType)).ToList();

    async Task InstallAsync()
    {
        Busy = "Installing BlueMap…"; Error = "";
        try
        {
            await BlueMap.InstallAsync(R.Path, R.ServerType, R.McVersion, BlueMap.PickPort(Others()));
            _needsRestart = _server.IsRunning;
        }
        catch (Exception e) { Error = "Couldn't install BlueMap: " + e.Message; }
        finally { Busy = ""; Ui.Post(Refresh); }
    }

    async Task ConsentAsync()
    {
        try
        {
            BlueMap.Configure(R.Path, R.ServerType, BlueMap.PickPort(Others()));
            if (_server.IsRunning) try { _server.Runtime.SendCommand("bluemap reload"); } catch { }
            Refresh();
        }
        catch (Exception e) { Error = e.Message; }
        await Task.CompletedTask;
    }

    async Task RestartAsync()
    {
        Busy = "Restarting…";
        try
        {
            _server.Runtime.Stop();
            for (var i = 0; i < 120 && _server.IsRunning; i++) await Task.Delay(500);
            _server.Runtime.Start(R);
            _needsRestart = false;
        }
        catch (Exception e) { Error = e.Message; }
        finally { Busy = ""; Ui.Post(Refresh); }
    }

    public void Dispose() => _cts.Cancel();
}
