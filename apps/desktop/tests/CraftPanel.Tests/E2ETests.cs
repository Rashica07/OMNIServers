using CraftPanel.Core;
using CraftPanel.Core.Addons;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Java;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

/// <summary>Real downloads, a real JVM and a real Fabric server. Takes minutes; only runs when CP_E2E is set.</summary>
public class E2ETests
{
    [Fact]
    public async Task InstallJavaCreateFabricServerWithBlueMapChatAndBackup()
    {
        if (Environment.GetEnvironmentVariable("CP_E2E") is null) return;
        using var t = new TempDir();
        var prev = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            var log = new List<string>();
            var progress = new Progress<ProvisionProgress>(p => log.Add(p.Message));

            // 1. Java: nothing managed yet → the installer downloads, verifies and extracts Temurin 25.
            Assert.Null(JavaInstaller.InstalledPath(25));
            var java = await JavaInstaller.InstallAsync(25, progress);
            Assert.Equal(25u, java.Major);
            Assert.Equal(JavaInstaller.InstalledPath(25), java.Path);

            // 2. Fabric 26.2 server: download launcher, EULA, first boot generates server.properties.
            var dir = Path.Combine(t.Path, "srv");
            var created = await Provisioner.CreateAsync(new CreateSpec(Loader.Fabric, "26.2", null, dir, "E2E", 2048, "java"), progress);
            Assert.Equal(java.Path, created.JavaPath);   // "java" resolved to the managed runtime
            Assert.True(File.Exists(Path.Combine(dir, "server.properties")));
            Provisioner.ApplyStartingSettings(dir, false, Provisioner.PickFreePort(new HashSet<int>()), null, "survival", "easy", "CraftPanel E2E", 5);

            // 3. BlueMap
            var mapPort = BlueMap.PickPort([]);
            await BlueMap.InstallAsync(dir, ServerType.Fabric, "26.2", mapPort);
            Assert.True(BlueMap.IsInstalled(dir, ServerType.Fabric) && BlueMap.ConsentGiven(dir, ServerType.Fabric));

            // 4. Start it for real.
            var rec = new ServerRecord { Name = "E2E", Path = dir, ServerType = created.ServerType, LaunchTarget = created.LaunchTarget, McVersion = "26.2", JavaPath = created.JavaPath, RamMB = 2048 };
            var rt = new ServerRuntime(rec.Id);
            rt.Start(rec);
            for (var i = 0; i < 400 && rt.Status != ServerStatus.Running; i++) await Task.Delay(500);
            Assert.True(rt.Status == ServerStatus.Running, string.Join("\n", rt.Lines().TakeLast(30).Select(l => l.Text)));

            // 5. Map served, RCON answers, chat goes out.
            var up = false;
            for (var i = 0; i < 120 && !up; i++) { await Task.Delay(1000); up = await BlueMap.IsUpAsync(mapPort); }
            Assert.True(up, "BlueMap never answered");
            var list = await RconService.Shared.PlayersAsync(rec);
            Assert.Equal(0, list.Online);
            Assert.Equal(5, list.Max);
            rt.SendChat("hello from \"CraftPanel\"", "Host");
            await Task.Delay(1500);
            Assert.DoesNotContain(rt.Lines().TakeLast(10), l => l.Text.Contains("Unknown or incomplete") || l.Text.Contains("<--[HERE]"));

            // 6. Backup a running server, verify, and stop gracefully.
            var paused = await rt.PauseSavesAsync();
            var backup = BackupManager.BackupNow(dir, "e2e", "manual");
            if (paused) rt.ResumeSaves();
            Assert.True(BackupManager.VerifyAndRecord(dir, backup.Id));
            rt.Stop();
            for (var i = 0; i < 90 && rt.IsRunning; i++) await Task.Delay(500);
            Assert.Equal(ServerStatus.Stopped, rt.Status);
            Assert.Equal(0, rt.ExitCode);

            // 7. Restore round-trip on the stopped server.
            File.WriteAllText(Path.Combine(dir, "server.properties"), "broken=true\n");
            BackupManager.Restore(dir, backup.Id);
            Assert.Equal("CraftPanel E2E", Properties.Load(dir).Get("motd"));
            Console.WriteLine("E2E ok — steps: " + string.Join(" | ", log.Distinct().Take(12)));
        }
        finally { AppPaths.DataOverride = prev; }
    }
}
