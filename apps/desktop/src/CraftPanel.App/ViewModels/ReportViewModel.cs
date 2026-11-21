using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Diagnostics;

namespace CraftPanel.App.ViewModels;

/// <summary>"Report a problem": says what's wrong, picks the server involved, saves a redacted .zip to send.</summary>
public sealed class ReportViewModel : ViewModelBase
{
    const string NoServer = "(no particular server)";
    string _description = "", _server = NoServer, _status = "", _savedPath = "", _preview = "";
    readonly string? _error;
    bool _busy;

    public ObservableCollection<string> Servers { get; } = [NoServer];

    public ReportViewModel(string? error = null)
    {
        _error = error;
        foreach (var s in AppServices.Ready ? AppServices.Store.All : []) Servers.Add(s.Name);
        SaveCommand = new AsyncCommand(SaveAsync, () => !_busy);
        OpenFolderCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(Path.GetDirectoryName(_savedPath)!), () => _savedPath.Length > 0);
        CopyCommand = new AsyncCommand(CopyAsync);
        IssueCommand = new AsyncCommand(IssueAsync);
        CloseCommand = new RelayCommand(() => RequestClose?.Invoke());
    }

    public event Action? RequestClose;
    public string Description { get => _description; set => Set(ref _description, value); }
    public string SelectedServer { get => _server; set => Set(ref _server, value); }
    public string Status { get => _status; private set { Set(ref _status, value); Raise(nameof(HasStatus)); } }
    public bool HasStatus => _status.Length > 0;
    public bool HasSaved => _savedPath.Length > 0;
    public string SavedPath => _savedPath;
    public bool HasError => _error is not null;
    public string ErrorText => _error ?? "";
    public string PrivacyNote => "Removed before saving: your Windows user name, this PC's name, IP addresses, and anything that looks like a password or key. The server console can still contain player names — look at console.txt inside the zip if that matters.";

    public AsyncCommand SaveCommand { get; }
    public RelayCommand OpenFolderCommand { get; }
    public AsyncCommand CopyCommand { get; }
    public AsyncCommand IssueCommand { get; }
    public RelayCommand CloseCommand { get; }

    async Task<ReportInput> BuildAsync()
    {
        var i = new ReportInput
        {
            Description = Description, Error = _error, IsWine = Program.IsWine(), RenderMode = Program.RenderMode,
            AppVersion = typeof(ReportViewModel).Assembly.GetName().Version?.ToString(3) ?? "?",
            ConsoleOf = _server == NoServer ? null : _server,
        };
        if (AppServices.Ready)
        {
            foreach (var s in AppServices.Store.All)
            {
                var rt = AppServices.Processes.Runtime(s.Id);
                var lines = s.Name == _server ? rt.Lines().Select(l => l.Text).ToList() : [];
                i.Servers.Add(new ReportServer(s.Name, s.ServerType.Label(), s.McVersion, s.RamMB, rt.IsRunning, lines));
            }
            try { i.Checks.AddRange(await Doctor.RunAsync(AppPaths.DefaultServersDir)); } catch { }
        }
        return i;
    }

    async Task SaveAsync()
    {
        _busy = true; Status = "Collecting…";
        try
        {
            var input = await BuildAsync();
            _savedPath = await Task.Run(() => ReportBuilder.Save(input));
            Raise(nameof(HasSaved)); Raise(nameof(SavedPath)); OpenFolderCommand.RaiseCanExecuteChanged();
            Status = $"Saved {Path.GetFileName(_savedPath)}. Send that file to whoever is helping you.";
        }
        catch (Exception e) { Status = "Couldn't save the report: " + e.Message; }
        finally { _busy = false; }
    }

    async Task CopyAsync()
    {
        var text = ReportBuilder.BuildSummary(await BuildAsync());
        Dialogs.Current.CopyText(text);
        Status = "Copied. Paste it into a message.";
    }

    async Task IssueAsync()
    {
        var summary = ReportBuilder.BuildSummary(await BuildAsync());
        Dialogs.Current.OpenUrl(ReportBuilder.IssueUrl("Problem report", summary));
        Status = "Opened GitHub in your browser. If it's blocked on this PC, use Copy summary or send the saved .zip instead.";
    }
}
