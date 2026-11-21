using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

public sealed class ConsoleViewModel : ViewModelBase, IDisposable
{
    readonly ServerItemViewModel _server;
    readonly List<string> _history = [];
    int _historyIndex = -1;
    string _command = "", _filter = "";
    bool _logMode;
    string _logText = "";

    public ServerRuntime Runtime => _server.Runtime;
    public ServerItemViewModel Server => _server;

    /// <summary>Raised on the UI thread for every new console line.</summary>
    public event Action<LogLine>? LineAdded;
    /// <summary>Raised when the whole view should be rebuilt (filter changed, cleared, mode switched).</summary>
    public event Action? Reset;

    public ConsoleViewModel(ServerItemViewModel server)
    {
        _server = server;
        Runtime.LineAdded += OnLine;
        Runtime.StateChanged += OnState;
        SendCommand = new RelayCommand(Send, () => Runtime.IsRunning);
        ClearCommand = new RelayCommand(() => { Cleared = Runtime.Lines().LastOrDefault()?.Id ?? 0; Reset?.Invoke(); });
        AcceptEulaCommand = new AsyncCommand(AcceptEulaAsync);
        CopyCommand = new RelayCommand(() => { Dialogs.Current.CopyText(string.Join("\n", Visible().Select(l => l.Text))); ToastService.Shared.Show("Console copied", "Paste it where you need help.", "copy", "ok", null, 2); });
        OpenLogsCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(Path.Combine(_server.Record.Path, "logs")));
    }

    public long Cleared { get; private set; }

    public bool LogMode
    {
        get => _logMode;
        set { if (Set(ref _logMode, value)) { Raise(nameof(LiveMode)); if (value) LoadLog(); Reset?.Invoke(); } }
    }
    public bool LiveMode { get => !_logMode; set { if (value) LogMode = false; } }
    public string LogText => _logText;
    public IReadOnlyList<LogFinding> Findings
    {
        get
        {
            var text = _logMode ? _logText : string.Join("\n", Runtime.Lines().TakeLast(500).Select(l => l.Text));
            return LogAnalyzer.Analyze(text).Where(f => f.Id != "eula").ToList();
        }
    }
    public bool HasFindings => Findings.Count > 0;

    public string Command { get => _command; set => Set(ref _command, value); }
    public string Filter { get => _filter; set { if (Set(ref _filter, value)) Reset?.Invoke(); } }
    public bool IsRunning => Runtime.IsRunning;
    public bool NeedsEula => Runtime.NeedsEula && !Runtime.IsRunning;
    public string Placeholder => Runtime.IsRunning ? "Type a command — say hi, op Steve, whitelist add…" : "Start the server to send commands";

    public RelayCommand SendCommand { get; }
    public RelayCommand ClearCommand { get; }
    public RelayCommand CopyCommand { get; }
    public RelayCommand OpenLogsCommand { get; }
    public AsyncCommand AcceptEulaCommand { get; }

    public IEnumerable<LogLine> Visible()
    {
        var f = _filter.Trim();
        return Runtime.Lines().Where(l => l.Id > Cleared && (f.Length == 0 || l.Text.Contains(f, StringComparison.OrdinalIgnoreCase)));
    }

    public bool Matches(LogLine l) => l.Id > Cleared && (_filter.Trim().Length == 0 || l.Text.Contains(_filter.Trim(), StringComparison.OrdinalIgnoreCase));

    void OnLine(LogLine l) => Ui.Post(() => { if (!_logMode && Matches(l)) LineAdded?.Invoke(l); });

    void OnState() => Ui.Post(() =>
    {
        Raise(nameof(IsRunning)); Raise(nameof(Findings)); Raise(nameof(HasFindings)); Raise(nameof(NeedsEula)); Raise(nameof(Placeholder)); SendCommand.RaiseCanExecuteChanged();
        if (_logMode) LoadLog();
    });

    void Send()
    {
        var text = Command.Trim();
        if (text.Length == 0 || !Runtime.IsRunning) return;
        try
        {
            Runtime.SendCommand(text);
            Runtime.Push(LogStream.System, "> " + text);
            if (_history.Count == 0 || _history[^1] != text) _history.Add(text);
            if (_history.Count > 200) _history.RemoveAt(0);
            _historyIndex = -1;
            Command = "";
        }
        catch (Exception e) { Runtime.Push(LogStream.System, e.Message); }
    }

    /// <summary>Up (-1) / Down (+1) through previously sent commands.</summary>
    public void RecallHistory(int direction)
    {
        if (_history.Count == 0) return;
        var next = _historyIndex switch { -1 => direction < 0 ? _history.Count - 1 : -1, var i => i + direction };
        if (next < 0 && _historyIndex >= 0) { _historyIndex = -1; Command = ""; return; }
        if (next < 0 || next >= _history.Count) { if (next >= _history.Count) { _historyIndex = -1; Command = ""; } return; }
        _historyIndex = next;
        Command = _history[next];
    }

    public void LoadLog()
    {
        var file = Path.Combine(_server.Record.Path, "logs", "latest.log");
        try
        {
            if (!File.Exists(file)) { _logText = ""; Raise(nameof(LogText)); return; }
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            const int max = 400 * 1024;
            if (fs.Length > max) fs.Seek(-max, SeekOrigin.End);
            _logText = new StreamReader(fs).ReadToEnd();
        }
        catch (IOException e) { _logText = "Couldn't read the log: " + e.Message; }
        Raise(nameof(LogText)); Raise(nameof(Findings)); Raise(nameof(HasFindings));
    }

    async Task AcceptEulaAsync()
    {
        await File.WriteAllTextAsync(Path.Combine(_server.Record.Path, "eula.txt"), "# Accepted via OMNIServers — https://aka.ms/MinecraftEULA\neula=true\n");
        Runtime.Push(LogStream.System, "EULA accepted. Starting…");
        try { Runtime.Start(_server.Record); } catch (Exception e) { Runtime.Push(LogStream.System, e.Message); }
    }

    public void Dispose()
    {
        Runtime.LineAdded -= OnLine;
        Runtime.StateChanged -= OnState;
    }
}
