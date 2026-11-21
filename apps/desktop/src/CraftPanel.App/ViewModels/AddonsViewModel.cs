using System.Collections.ObjectModel;
using Avalonia.Media.Imaging;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Addons;

namespace CraftPanel.App.ViewModels;

public sealed class AddonRow : ViewModelBase
{
    Bitmap? _icon;
    bool _installed, _busy;
    public ModrinthHit Hit { get; }
    public AddonRow(ModrinthHit hit) { Hit = hit; _installed = hit.Installed; _ = LoadIcon(); }
    async Task LoadIcon() { var b = await ImageCache.LoadAsync(Hit.IconUrl); Ui.Post(() => Icon = b); }

    public string Title => Hit.Title;
    public string Description => Hit.Description;
    public string ProjectId => Hit.ProjectId;
    public string Downloads => Hit.Downloads >= 1_000_000 ? $"{Hit.Downloads / 1_000_000.0:0.#}M downloads" : Hit.Downloads >= 1000 ? $"{Hit.Downloads / 1000.0:0.#}k downloads" : $"{Hit.Downloads} downloads";
    public bool Compatible => Hit.Compatible;
    public bool NotCompatible => !Hit.Compatible;
    public bool HasIcon => _icon is not null;
    public Bitmap? Icon { get => _icon; private set { Set(ref _icon, value); Raise(nameof(HasIcon)); } }
    public bool Installed { get => _installed; set { Set(ref _installed, value); Raise(nameof(CanInstall)); } }
    public bool Busy { get => _busy; set { Set(ref _busy, value); Raise(nameof(CanInstall)); } }
    public bool CanInstall => !_installed && !_busy;
}

public sealed class InstalledRow(InstalledEntry e) : ViewModelBase
{
    public InstalledEntry Entry { get; } = e;
    public string Title => Entry.Title;
    public string Version => Entry.VersionNumber;
    public string ProjectId => Entry.ProjectId;
    public bool IsDependency => Entry.Dependency;
    public bool HasUpdate => Entry.Update is not null;
    public string UpdateText => Entry.Update is { } u ? $"Update to {u.VersionNumber}" : "";
}

public sealed class AddonsViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    string _query = "", _kind, _status = "";
    bool _loading;
    int _offset, _total;
    CancellationTokenSource? _cts;

    ServerRecord R => _server.Record;
    public ObservableCollection<AddonRow> Results { get; } = [];
    public ObservableCollection<InstalledRow> Installed { get; } = [];
    public ObservableCollection<KindChoice> Kinds { get; } = [];

    public sealed class KindChoice(string id, string label, Action<string> pick) : ViewModelBase
    {
        bool _on;
        public string Id { get; } = id; public string Label { get; } = label;
        public bool On { get => _on; set => Set(ref _on, value); }
        public RelayCommand PickCommand { get; } = new(() => pick(id));
    }

    public AddonsViewModel(ServerItemViewModel server, string? initialQuery = null)
    {
        _server = server;
        Kinds.Add(new KindChoice("mod", R.ServerType.UsesPlugins() ? "Plugins" : "Mods", PickKind));
        Kinds.Add(new KindChoice("datapack", "Datapacks", PickKind));
        Kinds.Add(new KindChoice("resourcepack", "Resource packs", PickKind));
        _kind = "mod"; Kinds[0].On = true;
        _query = initialQuery ?? "";
        SearchCommand = new AsyncCommand(() => SearchAsync(true));
        MoreCommand = new AsyncCommand(() => SearchAsync(false), () => !_loading && Results.Count < _total);
        InstallCommand = new AsyncCommand(InstallAsync);
        UpdateCheckCommand = new AsyncCommand(CheckUpdatesAsync);
        UpdateCommand = new AsyncCommand(UpdateAsync);
        RemoveCommand = new AsyncCommand(RemoveAsync);
        ReloadInstalled();
        _ = SearchAsync(true);
    }

    public string Query { get => _query; set => Set(ref _query, value); }
    public string Status { get => _status; private set { Set(ref _status, value); Raise(nameof(HasStatus)); } }
    public bool HasStatus => _status.Length > 0;
    public bool Loading { get => _loading; private set { Set(ref _loading, value); MoreCommand.RaiseCanExecuteChanged(); } }
    public bool CanLoadMore => Results.Count < _total && !_loading;
    public bool NoResults => !_loading && Results.Count == 0;
    public bool NoInstalled => Installed.Count == 0;
    public string McLine => R.McVersion is { } v ? $"Showing what works on {R.ServerType.Label()} {v}; anything without a build for {v} is marked." : "";

    public AsyncCommand SearchCommand { get; }
    public AsyncCommand MoreCommand { get; }
    public AsyncCommand InstallCommand { get; }
    public AsyncCommand UpdateCheckCommand { get; }
    public AsyncCommand UpdateCommand { get; }
    public AsyncCommand RemoveCommand { get; }

    void PickKind(string id)
    {
        _kind = id;
        foreach (var k in Kinds) k.On = k.Id == id;
        _ = SearchAsync(true);
    }

    async Task SearchAsync(bool fresh)
    {
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        if (fresh) { _offset = 0; Results.Clear(); }
        Loading = true; Status = "";
        try
        {
            var r = await ModrinthClient.SearchAsync(R.Path, R.ServerType, Query.Trim(), _kind, null, R.McVersion, _offset, cts.Token);
            if (cts.IsCancellationRequested) return;
            foreach (var h in r.Hits) Results.Add(new AddonRow(h));
            _offset += r.Hits.Count; _total = r.Total;
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Status = "Couldn't reach Modrinth: " + e.Message; }
        finally { if (_cts == cts) { Loading = false; Raise(nameof(NoResults)); Raise(nameof(CanLoadMore)); MoreCommand.RaiseCanExecuteChanged(); } }
    }

    void ReloadInstalled()
    {
        Installed.Clear();
        foreach (var e in ModrinthClient.Installed(R.Path)) Installed.Add(new InstalledRow(e));
        Raise(nameof(NoInstalled));
    }

    async Task InstallAsync(object? p)
    {
        if (p is not AddonRow row) return;
        row.Busy = true;
        try
        {
            if (_kind == "resourcepack")
            {
                var name = await ModrinthClient.InstallResourcepackAsync(R.Path, row.ProjectId, R.McVersion, false);
                ToastService.Shared.Show($"{row.Title} set as the server's resource pack", "Players get it when they join. Restart to apply.", "check-circle", "ok");
            }
            else
            {
                var res = await ModrinthClient.InstallAsync(R.Path, R.ServerType, row.ProjectId, _kind, R.McVersion);
                ToastService.Shared.Show($"Installed {string.Join(", ", res.Installed)}", _server.IsRunning ? "Restart the server to load it." : "", "check-circle", "ok");
            }
            row.Installed = true;
            ReloadInstalled();
        }
        catch (Exception e) { ToastService.Shared.Error($"{row.Title}: {e.Message}"); }
        finally { row.Busy = false; }
    }

    async Task CheckUpdatesAsync()
    {
        Status = "Checking for updates…";
        try
        {
            var list = await ModrinthClient.CheckUpdatesAsync(R.Path, R.ServerType, R.McVersion);
            var n = list.Count(e => e.Update is not null);
            Status = n == 0 ? "Everything is up to date." : $"{n} update{(n == 1 ? "" : "s")} available.";
            ReloadInstalled();
        }
        catch (Exception e) { Status = e.Message; }
    }

    async Task UpdateAsync(object? p)
    {
        if (p is not InstalledRow row) return;
        try { await ModrinthClient.UpdateOneAsync(R.Path, R.ServerType, row.ProjectId, R.McVersion); ToastService.Shared.Show($"{row.Title} updated", _server.IsRunning ? "Restart to apply." : "", "check-circle", "ok"); }
        catch (Exception e) { ToastService.Shared.Error($"{row.Title}: {e.Message}"); }
        ReloadInstalled();
    }

    async Task RemoveAsync(object? p)
    {
        if (p is not InstalledRow row) return;
        if (!await Dialogs.Current.ConfirmAsync($"Remove {row.Title}?", "The file is moved to a trash folder inside the server folder.", "Remove", true)) return;
        try { ModrinthClient.RemoveOne(R.Path, R.ServerType, row.ProjectId); } catch (Exception e) { ToastService.Shared.Error(e.Message); }
        ReloadInstalled();
        foreach (var r in Results.Where(r => r.ProjectId == row.ProjectId)) r.Installed = false;
    }
}
