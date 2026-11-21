namespace CraftPanel.Core.Runtime;

/// <summary>One <see cref="ServerRuntime"/> per server; start/stop helpers and app-quit handling.</summary>
public sealed class ProcessManager
{
    readonly Dictionary<Guid, ServerRuntime> _runtimes = [];
    readonly object _lock = new();

    /// <summary>Raised when any runtime's player event fires (server name in <see cref="ServerRuntime.DisplayName"/>).</summary>
    public event Action<ServerRuntime, LiveEvent, int>? PlayerEvent;
    public event Action<ServerRuntime>? StateChanged;
    /// <summary>A server process ended: (runtime, record, crashed).</summary>
    public event Action<ServerRuntime, ServerRecord, bool>? Exited;

    public ServerRuntime Runtime(Guid id)
    {
        lock (_lock)
        {
            if (_runtimes.TryGetValue(id, out var r)) return r;
            r = new ServerRuntime(id);
            r.PlayerEvent += (ev, n) => PlayerEvent?.Invoke(r, ev, n);
            r.StateChanged += () => StateChanged?.Invoke(r);
            r.Exited += (rec, crashed) => Exited?.Invoke(r, rec, crashed);
            return _runtimes[id] = r;
        }
    }

    public bool IsRunning(Guid id) { lock (_lock) return _runtimes.TryGetValue(id, out var r) && r.IsRunning; }
    public bool AnyRunning { get { lock (_lock) return _runtimes.Values.Any(r => r.IsRunning); } }
    public int RunningCount { get { lock (_lock) return _runtimes.Values.Count(r => r.IsRunning); } }
    public List<Guid> RunningIds() { lock (_lock) return _runtimes.Where(kv => kv.Value.IsRunning).Select(kv => kv.Key).ToList(); }
    public int TotalOnline { get { lock (_lock) return _runtimes.Values.Where(r => r.IsRunning).Sum(r => r.Online().Count); } }

    public void Start(ServerRecord record) => Runtime(record.Id).Start(record);
    public void Stop(Guid id) => Runtime(id).Stop();
    public void Kill(Guid id) => Runtime(id).Kill();

    /// <summary>On launch: re-adopt every server that has a live session file.</summary>
    public int AdoptRunning(IEnumerable<ServerRecord> servers) => servers.Count(s => Runtime(s.Id).Adopt(s));

    public void StopAll() { List<ServerRuntime> rs; lock (_lock) rs = [.. _runtimes.Values]; foreach (var r in rs.Where(r => r.IsRunning)) r.Stop(); }
    public void ForceKillAll() { List<ServerRuntime> rs; lock (_lock) rs = [.. _runtimes.Values]; foreach (var r in rs.Where(r => r.IsRunning)) r.Kill(); }

    /// <summary>Stops every server and waits (bounded) for them; force-kills stragglers. Used on app quit.</summary>
    public async Task ShutdownAllAsync()
    {
        StopAll();
        var deadline = DateTime.UtcNow + ServerRuntime.GracefulStop + TimeSpan.FromSeconds(5);
        while (AnyRunning && DateTime.UtcNow < deadline) await Task.Delay(250);
        ForceKillAll();
    }
}
