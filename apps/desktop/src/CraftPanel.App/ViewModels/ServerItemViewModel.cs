using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

/// <summary>A server as the sidebar, overview and header see it: the saved record plus its live runtime state.</summary>
public sealed class ServerItemViewModel : ViewModelBase
{
    public ServerRecord Record { get; }
    public ServerRuntime Runtime { get; }

    public ServerItemViewModel(ServerRecord record)
    {
        Record = record;
        Runtime = AppServices.Processes.Runtime(record.Id);
        Runtime.StateChanged += () => Ui.Post(Refresh);
        Runtime.PlayersChanged += () => Ui.Post(Refresh);
        AppServices.Metrics.Sampled += () => Ui.Post(() => { Raise(nameof(RamUsedText)); Raise(nameof(CpuText)); Raise(nameof(HasMetrics)); });
    }

    public Guid Id => Record.Id;
    public string Name => Record.Name;
    public string Initial => Name.Length > 0 ? Name[..1].ToUpperInvariant() : "?";
    public string TypeLabel => Record.ServerType.Label();
    public string Subtitle => Record.McVersion is { Length: > 0 } v ? $"{TypeLabel} · {v}" : TypeLabel;
    public bool IsRunning => Runtime.IsRunning;
    public ServerStatus Status => Runtime.Status;
    public int OnlineCount => Runtime.Online().Count;
    public bool HasOnline => IsRunning && OnlineCount > 0;
    public string OnlineText => !IsRunning ? "" : OnlineCount == 0 ? "No one online" : OnlineCount == 1 ? "1 online" : $"{OnlineCount} online";

    public string StatusText => Status switch
    {
        ServerStatus.Starting => "Starting", ServerStatus.Running => Runtime.Reattached ? "Running (reattached)" : "Running", ServerStatus.Stopping => "Stopping",
        ServerStatus.Crashed => "Crashed", _ => "Stopped",
    };

    /// <summary>ok / warn / bad / idle — drives the status dot and badge colour.</summary>
    public string Tone => Status switch
    {
        ServerStatus.Running => "ok", ServerStatus.Starting or ServerStatus.Stopping => "warn", ServerStatus.Crashed => "bad", _ => "idle",
    };

    public bool HasMetrics => IsRunning && AppServices.Metrics.Latest(Id) is not null;
    public string RamUsedText => AppServices.Metrics.Latest(Id) is { } m && IsRunning ? $"{RamAdvisor.Gb(m.RamMB)} / {RamAdvisor.Gb((int)Record.RamMB)}" : MemoryText;
    public string CpuText => AppServices.Metrics.Latest(Id) is { } m && IsRunning ? $"{m.CpuPct:0}%" : "—";
    public string MemoryText => RamAdvisor.Gb((int)Record.RamMB);

    public void Refresh()
    {
        Raise(nameof(Name)); Raise(nameof(Subtitle)); Raise(nameof(IsRunning)); Raise(nameof(Status)); Raise(nameof(StatusText)); Raise(nameof(Tone));
        Raise(nameof(OnlineCount)); Raise(nameof(HasOnline)); Raise(nameof(OnlineText)); Raise(nameof(MemoryText)); Raise(nameof(CanStart)); Raise(nameof(CanStop));
    }

    public bool CanStart => !IsRunning;
    public bool CanStop => IsRunning && Status != ServerStatus.Stopping;
}
