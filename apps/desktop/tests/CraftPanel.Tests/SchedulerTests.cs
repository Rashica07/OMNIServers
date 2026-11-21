using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class SchedulerTests
{
    static async Task WaitFor(Func<bool> cond, int ms = 10000) { var end = DateTime.UtcNow.AddMilliseconds(ms); while (!cond() && DateTime.UtcNow < end) await Task.Delay(25); Assert.True(cond(), "condition not met in time"); }

    (TempDir t, ServerStore store, ProcessManager pm, ServerRecord rec, Scheduler sched) Setup(Action<ScheduleConfig> cfg)
    {
        var t = new TempDir(); t.Write("server.properties", "");
        var store = new ServerStore(Path.Combine(t.Path, "servers.json"));
        var rec = new ServerRecord { Name = "Fake", Path = Path.Combine(t.Path, "srv"), LaunchTarget = "server.jar", McVersion = "1.21", JavaPath = "" };
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.properties"), "a=1\n");
        rec.JavaPath = ProcessTests.FakeJava(t);
        cfg(rec.Schedule);
        store.Add(rec);
        var pm = new ProcessManager();
        var sched = new Scheduler(store, pm, AppSettings.Load(Path.Combine(t.Path, "settings.json")), startTimer: false) { CrashRestartDelay = TimeSpan.FromMilliseconds(150) };
        return (t, store, pm, rec, sched);
    }

    [Fact]
    public async Task CrashRestartsThenGivesUpAfterTheLimit()
    {
        if (OperatingSystem.IsWindows()) return;
        var (t, _, pm, rec, sched) = Setup(c => { c.RestartOnCrash = true; c.MaxCrashRestarts = 2; });
        using (t) using (sched)
        {
            var notices = new List<string>(); sched.Notice += (a, _) => notices.Add(a);
            var rt = pm.Runtime(rec.Id);
            pm.Start(rec);
            await WaitFor(() => rt.Status == ServerStatus.Running);
            rt.SendCommand("crash");                                    // crash #1 → restarted
            await WaitFor(() => rt.Lines().Any(l => l.Text.Contains("attempt 1/2")));
            await WaitFor(() => rt.Status == ServerStatus.Running && rt.ExitCode is null);
            rt.SendCommand("crash");                                    // crash #2 → restarted
            await WaitFor(() => rt.Lines().Any(l => l.Text.Contains("attempt 2/2")));
            await WaitFor(() => rt.Status == ServerStatus.Running && rt.ExitCode is null);
            rt.SendCommand("crash");                                    // crash #3 → paused
            await WaitFor(() => rt.Lines().Any(l => l.Text.Contains("not restarting again")));
            await Task.Delay(400);
            Assert.False(rt.IsRunning);
            Assert.Contains(notices, n => n.Contains("keeps crashing"));
        }
    }

    [Fact]
    public async Task CleanStopIsNotRestartedButIsBackedUp()
    {
        if (OperatingSystem.IsWindows()) return;
        var (t, _, pm, rec, sched) = Setup(c => { c.RestartOnCrash = true; c.BackupOnStop = true; });
        using (t) using (sched)
        {
            var rt = pm.Runtime(rec.Id);
            pm.Start(rec);
            await WaitFor(() => rt.Status == ServerStatus.Running);
            rt.Stop();
            await WaitFor(() => rt.Status == ServerStatus.Stopped);
            await WaitFor(() => BackupManager.List(rec.Path).Any(b => b.Trigger == "auto"));
            await Task.Delay(500);
            Assert.False(rt.IsRunning);
        }
    }

    [Fact]
    public async Task DailyRestartWarnsThenRestarts()
    {
        if (OperatingSystem.IsWindows()) return;
        var (t, _, pm, rec, sched) = Setup(c => c.DailyRestart = "04:00");
        using (t) using (sched)
        {
            var rt = pm.Runtime(rec.Id);
            pm.Start(rec);
            await WaitFor(() => rt.Status == ServerStatus.Running);
            var pid = rt.Pid;
            sched.Now = () => DateTime.Today.AddHours(3).AddMinutes(59).AddSeconds(30);
            sched.Tick();
            await WaitFor(() => rt.Lines().Any(l => l.Text.Contains("got:say Server restarting in 1 minute")));
            sched.Tick();   // still the warning window: no second warning
            Assert.Single(rt.Lines().Where(l => l.Text.Contains("got:say Server restarting")));
            sched.Now = () => DateTime.Today.AddHours(4).AddSeconds(5);
            sched.Tick();
            await WaitFor(() => rt.Lines().Any(l => l.Text.Contains("Scheduled daily restart")));
            await WaitFor(() => rt.Status == ServerStatus.Running && rt.Pid != pid);
            sched.Tick();   // same day: no second restart
            await Task.Delay(300);
            Assert.Equal(ServerStatus.Running, rt.Status);
            pm.StopAll();
            await WaitFor(() => !rt.IsRunning);
            Assert.DoesNotContain(BackupManager.List(rec.Path), b => b.Trigger == "auto");   // restart stops don't trigger backup-on-stop
        }
    }

    [Fact]
    public async Task AutoStartWithApp()
    {
        if (OperatingSystem.IsWindows()) return;
        var (t, _, pm, rec, sched) = Setup(c => c.AutoStartWithApp = true);
        using (t) using (sched)
        {
            sched.StartAutoStartServers();
            var rt = pm.Runtime(rec.Id);
            await WaitFor(() => rt.Status == ServerStatus.Running);
            rt.Kill(); await WaitFor(() => !rt.IsRunning);
        }
    }

    [Fact]
    public async Task OnStartCommandsRunOncePerRun()
    {
        if (OperatingSystem.IsWindows()) return;
        var (t, _, pm, rec, sched) = Setup(c => c.OnStartCommands = ["say hello from start"]);
        using (t) using (sched)
        {
            var rt = pm.Runtime(rec.Id);
            pm.Start(rec);
            await WaitFor(() => rt.Status == ServerStatus.Running);
            sched.Tick(); sched.Tick();
            await WaitFor(() => rt.Lines().Count(l => l.Text.Contains("Ran start command")) == 1);
            await Task.Delay(200);
            Assert.Equal(1, rt.Lines().Count(l => l.Text.Contains("Ran start command")));
            rt.Stop();
        }
    }
}
