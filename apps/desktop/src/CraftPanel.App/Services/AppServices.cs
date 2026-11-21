using CraftPanel.Core;
using CraftPanel.Core.Runtime;
using CraftPanel.Core.Security;

namespace CraftPanel.App.Services;

/// <summary>The app's long-lived singletons.</summary>
public static class AppServices
{
    public static ServerStore Store { get; private set; } = null!;
    public static AppSettings Settings { get; private set; } = null!;
    public static ProcessManager Processes { get; private set; } = null!;
    public static AppLock Lock { get; private set; } = null!;
    public static Scheduler Scheduler { get; private set; } = null!;
    public static MetricsSampler Metrics { get; private set; } = null!;
    public static bool Ready { get; private set; }

    public static void Init()
    {
        if (Ready) return;
        Settings = AppSettings.Load();
        Store = new ServerStore();
        Processes = new ProcessManager();
        Lock = new AppLock();
        Scheduler = new Scheduler(Store, Processes, Settings);
        Scheduler.Notice += (t, d) => ToastService.Shared.Show(t, d, "info", "warn");
        Metrics = new MetricsSampler(Processes);
        Ready = true;
    }

    /// <summary>For tests: fresh, isolated services.</summary>
    public static void InitForTests(ServerStore store, AppSettings settings, ProcessManager processes)
    {
        Store = store; Settings = settings; Processes = processes;
        Lock = new AppLock(Path.Combine(AppPaths.DataDir, "lock.json"));
        Scheduler = new Scheduler(store, processes, settings, startTimer: false); Metrics = new MetricsSampler(processes, startTimer: false); Ready = true;
    }
}
