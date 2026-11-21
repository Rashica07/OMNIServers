using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Performance;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

public sealed class RangeChip : ViewModelBase
{
    bool _active;
    public RangeChip(string label, TimeSpan span, Action<RangeChip> select) { Label = label; Span = span; SelectCommand = new RelayCommand(() => select(this)); }
    public string Label { get; }
    public TimeSpan Span { get; }
    public bool IsActive { get => _active; set => Set(ref _active, value); }
    public RelayCommand SelectCommand { get; }
}

/// <summary>Performance tab: CPU, memory and uptime of the running server, with a graph over the last minute to four hours.</summary>
public sealed class PerformanceViewModel : ViewModelBase, IDisposable
{
    readonly ServerItemViewModel _server;
    readonly Action _onSampled;
    TimeSpan _span = PerformanceChart.Ranges[1].Span;
    IReadOnlyList<double> _cpu = [], _ram = [];
    string _cpuText = "—", _ramText = "—", _uptime = "—", _peakText = "";
    double _cpuBar, _ramBar;

    public PerformanceViewModel(ServerItemViewModel server)
    {
        _server = server;
        foreach (var (label, span) in PerformanceChart.Ranges) Ranges.Add(new RangeChip(label, span, Pick));
        Ranges[1].IsActive = true;
        _onSampled = () => Ui.Post(Refresh);
        AppServices.Metrics.Sampled += _onSampled;
        _server.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ServerItemViewModel.IsRunning)) Ui.Post(Refresh); };
        Refresh();
    }

    public ObservableCollection<RangeChip> Ranges { get; } = [];
    public bool IsRunning => _server.IsRunning;
    public bool NoData => Cpu.Count < 2;
    public bool HasData => !NoData;
    public string EmptyText => _server.IsRunning ? "Collecting data… the graph appears after a few seconds." : "Start the server to see its performance.";

    public IReadOnlyList<double> Cpu { get => _cpu; private set { _cpu = value; Raise(); Raise(nameof(NoData)); Raise(nameof(HasData)); } }
    public IReadOnlyList<double> Ram { get => _ram; private set { _ram = value; Raise(); } }
    public string CpuText { get => _cpuText; private set => Set(ref _cpuText, value); }
    public string RamText { get => _ramText; private set => Set(ref _ramText, value); }
    public string Uptime { get => _uptime; private set => Set(ref _uptime, value); }
    public string PeakText { get => _peakText; private set => Set(ref _peakText, value); }
    public double CpuBar { get => _cpuBar; private set => Set(ref _cpuBar, value); }
    public double RamBar { get => _ramBar; private set => Set(ref _ramBar, value); }

    void Pick(RangeChip c)
    {
        _span = c.Span;
        foreach (var r in Ranges) r.IsActive = r == c;
        Refresh();
    }

    public void Refresh()
    {
        Raise(nameof(IsRunning)); Raise(nameof(EmptyText));
        var all = AppServices.Metrics.For(_server.Id);
        var win = PerformanceChart.Window(all, _span, DateTime.UtcNow);
        var allocMb = Math.Max(1, (double)_server.Record.RamMB);
        Cpu = PerformanceChart.Downsample(win.Select(s => s.CpuPct).ToList(), 240);
        Ram = PerformanceChart.Downsample(win.Select(s => s.RamMB / allocMb * 100).ToList(), 240);
        if (AppServices.Metrics.Latest(_server.Id) is { } m && _server.IsRunning)
        {
            CpuText = $"{m.CpuPct:0.0}%"; CpuBar = m.CpuPct;
            RamText = $"{RamAdvisor.Gb(m.RamMB)} of {RamAdvisor.Gb((int)_server.Record.RamMB)}"; RamBar = Math.Min(100, m.RamMB / allocMb * 100);
            PeakText = win.Count > 0 ? $"Peak in this window: CPU {win.Max(s => s.CpuPct):0}% · memory {RamAdvisor.Gb(win.Max(s => s.RamMB))}" : "";
        }
        else { CpuText = "—"; RamText = "—"; CpuBar = 0; RamBar = 0; PeakText = ""; }
        Uptime = _server.IsRunning ? PerformanceChart.Uptime(_server.Runtime.StartedAt, DateTime.Now) : "—";
    }

    public void Dispose() => AppServices.Metrics.Sampled -= _onSampled;
}
