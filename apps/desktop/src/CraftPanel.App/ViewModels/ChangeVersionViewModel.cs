using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Java;

namespace CraftPanel.App.ViewModels;

public sealed class LoaderOption(Loader loader) { public Loader Loader { get; } = loader; public string Label { get; } = loader.Label(); }

/// <summary>Swap a server's jar/loader in place — world, mods and configs untouched. Vanilla, Paper and Fabric only.</summary>
public sealed class ChangeVersionViewModel : ViewModelBase
{
    readonly ServerRecord _rec;
    LoaderOption _loader;
    string _query = "", _message = "", _error = "";
    bool _unstable, _loading, _busy;
    VersionRow? _selected;
    List<VersionRow> _all = [];

    public ObservableCollection<VersionRow> Versions { get; } = [];
    public LoaderOption[] Loaders { get; } = [new(Loader.Vanilla), new(Loader.Paper), new(Loader.Fabric)];
    public event Action? RequestClose;

    public ChangeVersionViewModel(ServerRecord rec)
    {
        _rec = rec;
        _loader = Loaders.FirstOrDefault(l => l.Loader.ServerType() == rec.ServerType) ?? Loaders[1];
        ApplyCommand = new AsyncCommand(ApplyAsync, () => Selected is not null && !_busy);
        CancelCommand = new RelayCommand(() => RequestClose?.Invoke());
        _ = LoadAsync();
    }

    public string ServerName => _rec.Name;
    public string Current => $"{_rec.ServerType.Label()} {_rec.McVersion}";
    public LoaderOption SelectedLoader { get => _loader; set { if (Set(ref _loader, value)) _ = LoadAsync(); } }
    public string Query { get => _query; set { if (Set(ref _query, value)) Filter(); } }
    public bool ShowUnstable { get => _unstable; set { if (Set(ref _unstable, value)) Filter(); } }
    public VersionRow? Selected { get => _selected; set { Set(ref _selected, value); ApplyCommand.RaiseCanExecuteChanged(); } }
    public bool Loading { get => _loading; private set => Set(ref _loading, value); }
    public bool Busy { get => _busy; private set { Set(ref _busy, value); ApplyCommand.RaiseCanExecuteChanged(); } }
    public string Message { get => _message; private set => Set(ref _message, value); }
    public string Error { get => _error; private set { Set(ref _error, value); Raise(nameof(HasError)); } }
    public bool HasError => _error.Length > 0;
    public AsyncCommand ApplyCommand { get; }
    public RelayCommand CancelCommand { get; }

    async Task LoadAsync()
    {
        Loading = true; Error = ""; Versions.Clear();
        try { _all = (await Provisioner.ListVersionsAsync(_loader.Loader)).Select(v => new VersionRow(v)).ToList(); Filter(); }
        catch (Exception e) { Error = "Couldn't load versions: " + e.Message; }
        finally { Loading = false; }
    }

    void Filter()
    {
        Versions.Clear();
        foreach (var v in _all.Where(v => (ShowUnstable || v.IsStable) && (Query.Trim().Length == 0 || v.Id.Contains(Query.Trim(), StringComparison.OrdinalIgnoreCase))).Take(200)) Versions.Add(v);
    }

    async Task ApplyAsync()
    {
        if (Selected is not { } v) return;
        if (!await Dialogs.Current.ConfirmAsync($"Switch {_rec.Name} to {_loader.Label} {v.Id}?", "Your world, mods and configs stay as they are, but going to an older version can break a world made on a newer one — back up first (Backups tab) if it matters.", "Switch version")) return;
        Busy = true; Error = "";
        var progress = new Progress<ProvisionProgress>(p => Message = p.Message);
        try
        {
            var java = await Provisioner.EnsureJavaAsync(_rec.JavaPath, JavaProbe.RequiredJava(v.Id), v.Id, progress);
            var created = await Provisioner.ChangeVersionAsync(_rec.Path, _rec.LaunchTarget, _loader.Loader, v.Id, null, java, progress);
            _rec.ServerType = created.ServerType; _rec.LaunchTarget = created.LaunchTarget; _rec.McVersion = created.McVersion; _rec.JavaPath = java;
            AppServices.Store.Update(_rec);
            ToastService.Shared.Show($"Switched to {_loader.Label} {v.Id}", "", "check-circle", "ok");
            RequestClose?.Invoke();
        }
        catch (Exception e) { Error = e.Message; }
        finally { Busy = false; }
    }
}
