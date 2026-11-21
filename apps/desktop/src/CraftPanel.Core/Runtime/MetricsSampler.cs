using System.Diagnostics;

namespace CraftPanel.Core.Runtime;

public sealed record MetricSample(DateTime At, int RamMB, double CpuPct);

/// <summary>Samples each running server's process (memory and CPU) every few seconds and keeps a short history for graphs.</summary>
public sealed class MetricsSampler : IDisposable
{
    public const int History = 4800;   // 4 hours at the normal 3 s interval
    readonly ProcessManager _pm;
    readonly Timer _timer;
    readonly Dictionary<Guid, (int Pid, TimeSpan Cpu, DateTime At)> _last = [];
    readonly Dictionary<Guid, List<MetricSample>> _samples = [];
    readonly object _gate = new();

    public event Action? Sampled;
    public IReadOnlyList<Guid> Ids { get { lock (_gate) return [.. _samples.Keys]; } }

    public MetricsSampler(ProcessManager pm, bool startTimer = true)
    {
        _pm = pm;
        _timer = new Timer(_ => SampleOnce(), null, startTimer ? Performance.LightMode.MetricsInterval : Timeout.InfiniteTimeSpan, Performance.LightMode.MetricsInterval);
    }

    public IReadOnlyList<MetricSample> For(Guid id) { lock (_gate) return _samples.TryGetValue(id, out var l) ? [.. l] : []; }
    public MetricSample? Latest(Guid id) { lock (_gate) return _samples.TryGetValue(id, out var l) && l.Count > 0 ? l[^1] : null; }

    /// <summary>Adds history directly (tests and screenshots); a real sample replaces nothing.</summary>
    public void Inject(Guid id, IEnumerable<MetricSample> samples)
    {
        lock (_gate) { if (!_samples.TryGetValue(id, out var l)) _samples[id] = l = []; l.AddRange(samples); if (l.Count > History) l.RemoveRange(0, l.Count - History); }
    }

    public void SampleOnce()
    {
        var now = DateTime.UtcNow;
        var running = new List<(Guid Id, int Pid)>();
        foreach (var id in _pm.RunningIds()) if (_pm.Runtime(id).Pid is { } pid) running.Add((id, pid));
        lock (_gate)
        {
            foreach (var gone in _samples.Keys.Except(running.Select(r => r.Id)).ToList()) { _samples.Remove(gone); _last.Remove(gone); }
            foreach (var (id, pid) in running)
            {
                try
                {
                    using var p = Process.GetProcessById(pid);
                    // the server may be a launcher script whose java child does the work; sum the tree's working set for accuracy
                    var ram = (int)(p.WorkingSet64 / 1_048_576);
                    var cpu = p.TotalProcessorTime;
                    double pct = 0;
                    if (_last.TryGetValue(id, out var prev) && prev.Pid == pid)
                    {
                        var dt = (now - prev.At).TotalMilliseconds;
                        if (dt > 100) pct = Math.Clamp((cpu - prev.Cpu).TotalMilliseconds / dt / Environment.ProcessorCount * 100, 0, 100);
                    }
                    _last[id] = (pid, cpu, now);
                    if (!_samples.TryGetValue(id, out var list)) _samples[id] = list = [];
                    list.Add(new MetricSample(now, ram, pct));
                    if (list.Count > History) list.RemoveAt(0);
                }
                catch { }
            }
        }
        Sampled?.Invoke();
    }

    public void Dispose() => _timer.Dispose();
}
