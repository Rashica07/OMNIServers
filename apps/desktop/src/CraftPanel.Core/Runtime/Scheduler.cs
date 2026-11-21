using CraftPanel.Core.Backups;

namespace CraftPanel.Core.Runtime;

/// <summary>Per-server automation: restart after a crash (bounded), a daily restart with a heads-up in chat, a backup after every stop, start with OMNIServers.</summary>
public sealed class Scheduler : IDisposable
{
    readonly ServerStore _store;
    readonly ProcessManager _pm;
    readonly AppSettings _settings;
    readonly Dictionary<Guid, List<DateTime>> _crashes = [];
    readonly Dictionary<Guid, DateOnly> _restartedOn = [];
    readonly HashSet<Guid> _warned = [];
    readonly HashSet<Guid> _startRan = [];
    readonly Dictionary<Guid, DateTime> _lastSnapshot = [];
    readonly HashSet<Guid> _snapshotting = [];
    readonly Timer _timer;

    /// <summary>Delay before restarting after a crash (tests shorten it).</summary>
    public TimeSpan CrashRestartDelay { get; set; } = TimeSpan.FromSeconds(5);
    public TimeSpan CrashWindow { get; set; } = TimeSpan.FromMinutes(10);
    /// <summary>Told about anything worth showing (title, detail).</summary>
    public event Action<string, string>? Notice;
    public Func<DateTime> Now { get; set; } = () => DateTime.Now;

    public Scheduler(ServerStore store, ProcessManager pm, AppSettings settings, bool startTimer = true)
    {
        _store = store; _pm = pm; _settings = settings;
        _pm.Exited += OnExited;
        _timer = new Timer(_ => Tick(), null, startTimer ? TimeSpan.FromSeconds(15) : Timeout.InfiniteTimeSpan, TimeSpan.FromSeconds(15));
    }

    /// <summary>Starts every server that's set to start with OMNIServers and isn't already running (re-adopted).</summary>
    public void StartAutoStartServers()
    {
        foreach (var s in _store.All.Where(s => s.Schedule.AutoStartWithApp && !_pm.IsRunning(s.Id)))
            try { _pm.Start(s); Notice?.Invoke($"Starting {s.Name}", "It's set to start with OMNIServers."); }
            catch (Exception e) { Notice?.Invoke($"Couldn't start {s.Name}", e.Message); }
    }

    void OnExited(ServerRuntime rt, ServerRecord rec, bool crashed)
    {
        var sched = _store.Find(rec.Id)?.Schedule ?? rec.Schedule;
        if (!crashed && sched.BackupOnStop && !rt.StopRequestedForRestart)
            _ = Task.Run(() =>
            {
                try { BackupManager.BackupNow(rec.Path, "after stop", "auto"); BackupManager.ApplyRetention(rec.Path, _settings); }
                catch (Exception e) { Notice?.Invoke($"Backup of {rec.Name} failed", e.Message); }
            });
        if (crashed && sched.RestartOnCrash) _ = RestartAfterCrashAsync(rt, rec, sched);
    }

    async Task RestartAfterCrashAsync(ServerRuntime rt, ServerRecord rec, ScheduleConfig sched)
    {
        var now = Now();
        if (!_crashes.TryGetValue(rec.Id, out var list)) _crashes[rec.Id] = list = [];
        list.RemoveAll(t => now - t > CrashWindow);
        if (list.Count >= Math.Max(1, sched.MaxCrashRestarts))
        {
            rt.Push(LogStream.System, $"[OMNIServers] {rec.Name} crashed {list.Count + 1} times in {CrashWindow.TotalMinutes:0} minutes — not restarting again.");
            Notice?.Invoke($"{rec.Name} keeps crashing", "Automatic restarts were paused. Check the console.");
            return;
        }
        list.Add(now);
        rt.Push(LogStream.System, $"[OMNIServers] Crash detected — restarting in {CrashRestartDelay.TotalSeconds:0}s (attempt {list.Count}/{sched.MaxCrashRestarts})");
        Notice?.Invoke($"{rec.Name} crashed", "Restarting it automatically.");
        await Task.Delay(CrashRestartDelay);
        try { if (!rt.IsRunning) rt.Start(rec); }
        catch (Exception e) { rt.Push(LogStream.System, "[OMNIServers] Couldn't restart: " + e.Message); }
    }

    /// <summary>Called every 15 s: daily restarts.</summary>
    public void Tick()
    {
        var now = Now();
        foreach (var s in _store.All)
        {
            TickSnapshot(s, now);
            TickOnStart(s);
            if (s.Schedule.DailyRestart is not { Length: > 0 } hhmm || !TimeOnly.TryParse(hhmm, out var at)) continue;
            var rt = _pm.Runtime(s.Id);
            if (!rt.IsRunning || rt.Status != Adapters.ServerStatus.Running) continue;
            var today = DateOnly.FromDateTime(now);
            var target = at.ToTimeSpan();
            var t = now.TimeOfDay;
            // one-minute heads-up in chat
            if (t >= target - TimeSpan.FromMinutes(1) && t < target && _warned.Add(s.Id))
                try { rt.SendCommand("say Server restarting in 1 minute"); } catch { }
            if (t >= target && t < target + TimeSpan.FromMinutes(5) && _restartedOn.GetValueOrDefault(s.Id) != today)
            {
                _restartedOn[s.Id] = today; _warned.Remove(s.Id);
                _ = RestartAsync(rt, s);
            }
        }
    }

    /// <summary>Sends the "when the server starts" commands once per run, as soon as it is up.</summary>
    void TickOnStart(ServerRecord s)
    {
        var rt = _pm.Runtime(s.Id);
        var up = rt.IsRunning && rt.Status == Adapters.ServerStatus.Running;
        if (!up) { _startRan.Remove(s.Id); return; }
        if (s.Schedule.OnStartCommands.Count == 0 || !_startRan.Add(s.Id)) return;
        foreach (var c in s.Schedule.OnStartCommands.Where(c => !string.IsNullOrWhiteSpace(c)))
        {
            try { rt.SendCommand(c.Trim()); rt.Push(LogStream.System, "[OMNIServers] Ran start command: " + c.Trim()); } catch { }
        }
    }

    /// <summary>Time Machine: a hard-linked snapshot every N minutes while the server runs, thinned by the retention settings.</summary>
    void TickSnapshot(ServerRecord s, DateTime now)
    {
        if (s.Schedule.SnapshotIntervalMins is not > 0) return;
        var rt = _pm.Runtime(s.Id);
        if (!rt.IsRunning || rt.Status != Adapters.ServerStatus.Running) return;
        var every = TimeSpan.FromMinutes(Math.Max(5, s.Schedule.SnapshotIntervalMins!.Value));
        if (_lastSnapshot.TryGetValue(s.Id, out var last) && now - last < every) return;
        lock (_snapshotting) if (!_snapshotting.Add(s.Id)) return;
        _lastSnapshot[s.Id] = now;
        _ = Task.Run(async () =>
        {
            var paused = false;
            try
            {
                paused = await rt.PauseSavesAsync();
                Backups.SnapshotManager.SnapshotNow(s.Path, "scheduled");
                Backups.SnapshotManager.Prune(s.Path, s.Schedule.SnapshotRecentHours, s.Schedule.SnapshotDailyDays);
            }
            catch (Exception e) { Notice?.Invoke($"Snapshot of {s.Name} failed", e.Message); }
            finally { if (paused) rt.ResumeSaves(); lock (_snapshotting) _snapshotting.Remove(s.Id); }
        });
    }

    async Task RestartAsync(ServerRuntime rt, ServerRecord rec)
    {
        rt.Push(LogStream.System, "[OMNIServers] Scheduled daily restart");
        Notice?.Invoke($"Restarting {rec.Name}", "Scheduled daily restart.");
        rt.StopRequestedForRestart = true;
        rt.Stop();
        for (var i = 0; i < 180 && rt.IsRunning; i++) await Task.Delay(500);
        rt.StopRequestedForRestart = false;
        try { rt.Start(rec); } catch (Exception e) { rt.Push(LogStream.System, "[OMNIServers] Couldn't restart: " + e.Message); }
    }

    public void Dispose() { _pm.Exited -= OnExited; _timer.Dispose(); }
}
