using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Sharing;

namespace CraftPanel.App.ViewModels;

/// <summary>"Take turns with another PC": share a server folder so only one PC runs it at a time.</summary>
public sealed class ShareCardViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    ShareView _view = new(false, null, false, false, null, null);
    string _error = "";

    public ShareCardViewModel(ServerItemViewModel server)
    {
        _server = server;
        ShareCommand = new RelayCommand(Share);
        StopSharingCommand = new AsyncCommand(StopSharingAsync);
        CopyCodeCommand = new RelayCommand(() => { if (Code.Length > 0) { Dialogs.Current.CopyText(Code); ToastService.Shared.Show("Code copied", Code, "copy", "ok", null, 2); } });
        RefreshCommand = new RelayCommand(Refresh);
        server.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ServerItemViewModel.IsRunning)) Ui.Post(Refresh); };
        Refresh();
    }

    ServerRecord R => _server.Record;

    public bool IsShared => _view.Shared;
    public bool NotShared => !_view.Shared;
    public string Code => _view.Code ?? "";
    public string Error { get => _error; private set { Set(ref _error, value); Raise(nameof(HasError)); } }
    public bool HasError => _error.Length > 0;
    public string? LocationNote => ShareLease.LocationNote(R.Path);
    public bool HasLocationNote => LocationNote is not null;

    public string StatusText => !_view.Shared ? "" : !_view.Locked ? "Free — no PC is running it right now."
        : _view.HeldByUs ? "Running on this PC."
        : $"Running on {_view.HolderName} — about {Math.Max((_view.ExpiresIn ?? 0) / 60, 0)} min left on its claim.";

    public RelayCommand ShareCommand { get; }
    public AsyncCommand StopSharingCommand { get; }
    public RelayCommand CopyCodeCommand { get; }
    public RelayCommand RefreshCommand { get; }

    public void Refresh()
    {
        _view = ShareLease.View(R.Path, ShareLease.ThisDeviceId);
        foreach (var n in new[] { nameof(IsShared), nameof(NotShared), nameof(Code), nameof(StatusText), nameof(LocationNote), nameof(HasLocationNote) }) Raise(n);
    }

    void Share()
    {
        if (_server.IsRunning) { Error = "Stop the server first, then share it."; return; }
        try { ShareLease.CreateShare(R.Path, R.Name); Error = ""; }
        catch (Exception e) { Error = e.Message; }
        Refresh();
    }

    async Task StopSharingAsync()
    {
        if (!await Dialogs.Current.ConfirmAsync("Stop sharing this server?", "The server stays exactly where it is; OMNIServers just stops taking turns with other PCs.", "Stop sharing", true)) return;
        try { ShareLease.Unshare(R.Path, ShareLease.ThisDeviceId); Error = ""; }
        catch (Exception e) { Error = e.Message; }
        Refresh();
    }
}
