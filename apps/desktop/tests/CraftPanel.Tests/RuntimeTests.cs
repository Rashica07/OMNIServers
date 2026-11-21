using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using CraftPanel.Core;
using CraftPanel.Core.Addons;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class LiveEventTests
{
    [Fact]
    public void ParsesAllLogFormats()
    {
        Assert.Equal(new LiveEvent.Join("Steve"), LiveEvent.Parse("[12:00:01] [Server thread/INFO]: Steve joined the game"));
        Assert.Equal(new LiveEvent.Leave("Alex"), LiveEvent.Parse("[12:00:01 INFO]: Alex left the game"));
        Assert.Equal(new LiveEvent.Join("Steve"), LiveEvent.Parse("[12:00:01] [Server thread/INFO] [minecraft/MinecraftServer]: Steve joined the game"));
        Assert.Equal(new LiveEvent.Chat("Steve", "hello there"), LiveEvent.Parse("[12:00:02] [Server thread/INFO]: <Steve> hello there"));
        Assert.Equal(new LiveEvent.Chat("Steve", "hi"), LiveEvent.Parse("[12:00:02] [Server thread/INFO]: [Not Secure] <Steve> hi"));
        Assert.Equal(new LiveEvent.Chat("Alex", "yo"), LiveEvent.Parse("[12:00:02 INFO]: \u001b[33m<Alex> yo\u001b[0m"));
        Assert.Equal(new LiveEvent.Broadcast("Server", "restarting soon"), LiveEvent.Parse("[12:00:03] [Server thread/INFO]: [Server] restarting soon"));
        Assert.Equal(new LiveEvent.Advancement("Steve", "Stone Age"), LiveEvent.Parse("[12:00:04] [Server thread/INFO]: Steve has made the advancement [Stone Age]"));
        Assert.Equal(new LiveEvent.Join(".BedrockGuy"), LiveEvent.Parse("[12:00:04] [Server thread/INFO]: .BedrockGuy joined the game"));
    }

    [Fact]
    public void ChatCantForgeEvents()
    {
        Assert.Equal(new LiveEvent.Chat("Eve", "Bob joined the game"), LiveEvent.Parse("[12:00:02] [Server thread/INFO]: <Eve> Bob joined the game"));
        Assert.Null(LiveEvent.Parse("[12:00:02] [Server thread/INFO]: Some thing joined the game"));
        Assert.Null(LiveEvent.Parse("[12:00:02] [Server thread/INFO]: Done (3.2s)! For help, type \"help\""));
        Assert.Null(LiveEvent.Parse("[12:00:02] [Server thread/INFO]: [Steve: Gave 1 [Stone] to Steve]"));
    }

    [Fact]
    public void RuntimeTracksOnlineAndChat()
    {
        var rt = new ServerRuntime(Guid.NewGuid());
        rt.Push(LogStream.Stdout, "[12:00:01] [Server thread/INFO]: Steve joined the game");
        rt.Push(LogStream.Stdout, "[12:00:01] [Server thread/INFO]: Alex joined the game");
        rt.Push(LogStream.Stdout, "[12:00:02] [Server thread/INFO]: <Steve> hi");
        rt.Push(LogStream.System, "[12:00:02] [Server thread/INFO]: Mallory joined the game");   // our own lines don't count
        rt.Push(LogStream.Stdout, "[12:00:03] [Server thread/INFO]: Steve left the game");
        Assert.Equal(["Alex"], rt.Online());
        Assert.Equal([ChatKind.Join, ChatKind.Join, ChatKind.Chat, ChatKind.Leave], rt.Chat().Select(c => c.Kind));
    }

    [Fact]
    public void TellrawJsonEscapes()
    {
        var json = ChatHistory.TellrawJson("Host", "say \"hi\" \\ ]}\nnext");
        var arr = System.Text.Json.JsonDocument.Parse(json).RootElement;
        Assert.Equal("say \"hi\" \\ ]} next", arr[2].GetProperty("text").GetString());
        Assert.DoesNotContain('\n', json);
    }

    [Fact]
    public void LogTailerFollowsAppendsAndRotation()
    {
        using var t = new TempDir(); var log = t.Write("logs/latest.log", "old line\n");
        var tail = new LogTailer(t.Path);
        Assert.Empty(tail.Poll());
        File.AppendAllText(log, "new one\npart");
        Assert.Equal(["new one"], tail.Poll());
        File.AppendAllText(log, "ial\n");
        Assert.Equal(["partial"], tail.Poll());
        File.WriteAllText(log, "fresh\n");   // rotated: shorter file
        Assert.Equal(["fresh"], tail.Poll());
    }

    [Fact]
    public void ChatHistoryFromLatestLog()
    {
        using var t = new TempDir();
        t.Write("logs/latest.log", "[09:00:00] [Server thread/INFO]: Starting minecraft server\n[09:01:00] [Server thread/INFO]: Steve joined the game\n[09:02:30] [Server thread/INFO]: <Steve> morning\n");
        var past = ChatHistory.Load(t.Path);
        Assert.Equal([ChatKind.Join, ChatKind.Chat], past.Select(p => p.Kind));
        Assert.Equal("morning", past[^1].Text);
        Assert.Equal(2, past[^1].Date.Minute);
    }
}

public class RamAdvisorTests
{
    static SystemMemory Mac(int gb, int cores = 11) => new(gb * 1024, gb * 512, "DDR5", "Test CPU", cores);

    [Fact]
    public void SafeLimit()
    {
        Assert.Equal(13824, Mac(18).SafeMaxMB);
        Assert.Equal(2048, Mac(4).SafeMaxMB);
        Assert.Equal(1024, Mac(2).SafeMaxMB);
    }

    [Fact]
    public void RecommendationScalesWithPlayersAndKind()
    {
        var safe = Mac(18).SafeMaxMB;
        Assert.Equal(2560, RamAdvisor.Recommend(RamKind.Minigame, 2, safe));
        Assert.Equal(4608, RamAdvisor.Recommend(RamKind.VanillaLike, 20, safe));
        Assert.Equal(5120, RamAdvisor.Recommend(RamKind.Modpack, 4, safe));
        Assert.True(RamAdvisor.Recommend(RamKind.Minigame, 2, safe) < RamAdvisor.Recommend(RamKind.Modded, 2, safe));
        Assert.Equal(6144, RamAdvisor.Recommend(RamKind.Modpack, 50, Mac(8).SafeMaxMB));
    }

    [Fact]
    public void Warnings()
    {
        var big = Mac(18);
        Assert.Empty(RamAdvisor.Warnings(2560, RamKind.Minigame, 2, big));
        Assert.Contains(RamAdvisor.Warnings(16384, RamKind.Minigame, 2, big), w => w.Serious);
        Assert.NotEmpty(RamAdvisor.Warnings(1024, RamKind.Modpack, 10, big));
        Assert.NotEmpty(RamAdvisor.Warnings(2048, RamKind.VanillaLike, 2, Mac(6)));   // weak PC
        Assert.Contains(RamAdvisor.Warnings(8192, RamKind.VanillaLike, 2, big, 8192), w => w.Serious);
        Assert.Empty(RamAdvisor.Warnings(99999, RamKind.Bedrock, 2, big));
    }

    [Fact]
    public void MemoryTypeParsing()
    {
        Assert.Equal("DDR4-3200", SystemMemory.ParseWindowsMemory("[{\"SMBIOSMemoryType\":26,\"ConfiguredClockSpeed\":3200},{\"SMBIOSMemoryType\":26,\"ConfiguredClockSpeed\":3200}]"));
        Assert.Equal("DDR5", SystemMemory.ParseWindowsMemory("{\"SMBIOSMemoryType\":34,\"ConfiguredClockSpeed\":0}"));
        Assert.Null(SystemMemory.ParseWindowsMemory("{\"SMBIOSMemoryType\":0}"));
        Assert.Equal("LPDDR5", SystemMemory.ParseMacMemory("{\"SPMemoryDataType\":[{\"dimm_type\":\"LPDDR5\"}]}"));
    }

    [Fact]
    public async Task LiveSystemFacts()
    {
        var m = await SystemMemory.DetailedAsync();
        Assert.True(m.TotalMB > 1024); Assert.True(m.AvailableMB > 0); Assert.False(string.IsNullOrEmpty(m.Chip));
    }
}

public class RconTests
{
    /// <summary>A tiny fake RCON server: auth with "pw", echoes "ran:&lt;cmd&gt;", splits long replies, answers the sentinel.</summary>
    internal sealed class FakeRcon : IDisposable
    {
        readonly TcpListener _l = new(IPAddress.Loopback, 0);
        public int Port => ((IPEndPoint)_l.LocalEndpoint).Port;
        public int Connections;
        public int Open;
        public FakeRcon() { _l.Start(); _ = Task.Run(Loop); }
        async Task Loop()
        {
            while (true)
            {
                TcpClient c;
                try { c = await _l.AcceptTcpClientAsync(); } catch { return; }
                Interlocked.Increment(ref Connections); Interlocked.Increment(ref Open);
                _ = Task.Run(async () => { try { await Serve(c); } catch { } finally { Interlocked.Decrement(ref Open); } });
            }
        }
        async Task Serve(TcpClient c)
        {
            using var s = c.GetStream();
            var buf = new byte[4096 + 64];
            while (true)
            {
                // Like the real server: one socket read == exactly one packet, otherwise it hangs up.
                var n = await s.ReadAsync(buf);
                if (n < 14) return;
                var len = BinaryPrimitives.ReadInt32LittleEndian(buf);
                if (len != n - 4) return;
                var id = BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(4)); var type = BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(8));
                var text = Encoding.UTF8.GetString(buf, 12, n - 14);
                if (type == 3) await Send(s, text == "pw" ? id : -1, 2, "");
                else if (type == 2)
                {
                    var reply = text == "biglist" ? new string('x', 5000) : text == "exact" ? new string('y', 4096) : "ran:" + text;
                    foreach (var chunk in reply.Chunk(4096)) await Send(s, id, 0, new string(chunk));
                    if (reply.Length == 4096) await Send(s, id, 0, "");   // the real server ends an exact-multiple reply with an empty packet
                }
                else await Send(s, id, 0, "Unknown request " + type.ToString("x"));
            }
        }
        static async Task<bool> Fill(NetworkStream s, byte[] b) { var g = 0; while (g < b.Length) { var n = await s.ReadAsync(b.AsMemory(g)); if (n == 0) return false; g += n; } return true; }
        static async Task Send(NetworkStream s, int id, int type, string body)
        {
            var b = Encoding.UTF8.GetBytes(body); var buf = new byte[14 + b.Length];
            BinaryPrimitives.WriteInt32LittleEndian(buf, 10 + b.Length); BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(4), id); BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(8), type);
            b.CopyTo(buf, 12); await s.WriteAsync(buf);
        }
        public void Dispose() => _l.Stop();
    }

    [Fact]
    public async Task AuthCommandAndFragmentedReply()
    {
        using var srv = new FakeRcon();
        using var c = await RconClient.ConnectAsync("127.0.0.1", srv.Port, "pw");
        Assert.Equal("ran:list", await c.CommandAsync("list"));
        Assert.Equal(5000, (await c.CommandAsync("biglist")).Length);
        Assert.Equal(4096, (await c.CommandAsync("exact")).Length);
        Assert.Equal("ran:again", await c.CommandAsync("again"));
    }

    [Fact]
    public async Task WrongPasswordIsRejected()
    {
        using var srv = new FakeRcon();
        var e = await Assert.ThrowsAsync<RconException>(() => RconClient.ConnectAsync("127.0.0.1", srv.Port, "nope"));
        Assert.Contains("rejected", e.Message);
    }

    [Fact]
    public async Task ClosedPortFailsFast()
    {
        var l = new TcpListener(IPAddress.Loopback, 0); l.Start(); var port = ((IPEndPoint)l.LocalEndpoint).Port; l.Stop();
        await Assert.ThrowsAsync<RconException>(() => RconClient.ConnectAsync("127.0.0.1", port, "pw"));
    }

    [Fact]
    public async Task ServicePoolsConnectionAndValidatesPlayerNames()
    {
        using var srv = new FakeRcon(); using var t = new TempDir();
        t.Write("server.properties", $"enable-rcon=true\nrcon.port={srv.Port}\nrcon.password=pw\n");
        var rec = new ServerRecord { Path = t.Path };
        Assert.Equal("ran:say a", await RconService.Shared.RunAsync(rec, "say a"));
        Assert.Equal("ran:say b", await RconService.Shared.RunAsync(rec, "say b"));
        Assert.Equal(1, srv.Connections);
        Assert.Equal("ran:kick Steve bad word", await RconService.Shared.PlayerActionAsync(rec, "kick", "Steve", "bad word"));
        await Assert.ThrowsAsync<RconException>(() => RconService.Shared.PlayerActionAsync(rec, "op", "x; stop"));
        await Assert.ThrowsAsync<RconException>(() => RconService.Shared.PlayerActionAsync(rec, "kick", "Steve", "x\nstop"));
        RconService.Shared.Drop(rec.Id);
    }

    [Fact]
    public void ParsesPlayerListAndSetup()
    {
        var (n, max, players) = RconClient.ParsePlayerList("There are 2 of a max of 20 players online: Alice, Bob");
        Assert.Equal((2, 20), (n, max)); Assert.Equal(["Alice", "Bob"], players);
        Assert.Empty(RconClient.ParsePlayerList("There are 0 of a max of 20 players online: ").Players);
        using var t = new TempDir(); t.Write("server.properties", "online-mode=false\nenable-rcon=false\n");
        var rec = new ServerRecord { Path = t.Path };
        var (changed, port) = RconService.Setup(rec);
        Assert.Equal(25575, port); Assert.Contains("enable-rcon=true", changed);
        var p = Properties.Load(t.Path);
        Assert.Equal(24, p.Get("rcon.password")!.Length); Assert.Equal("false", p.Get("online-mode"));
        Assert.Empty(RconService.Setup(rec).Changed);   // idempotent
    }
}

public class ProcessTests
{
    internal static string FakeJava(TempDir t)
    {
        var path = t.Write("fakejava", """
            #!/bin/sh
            echo "[12:00:00] [main/INFO]: Starting minecraft server version 1.21"
            echo "[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type \"help\""
            while read line; do
              case "$line" in
                stop) echo "[12:00:09] [Server thread/INFO]: Stopping the server"; exit 0;;
                join*) echo "[12:00:05] [Server thread/INFO]: ${line#join } joined the game";;
                crash) exit 3;;
                *) echo "[12:00:06] [Server thread/INFO]: got:$line";;
              esac
            done
            """.Replace("\r", ""));
        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return path;
    }

    static async Task WaitFor(Func<bool> cond, int ms = 8000) { var end = DateTime.UtcNow.AddMilliseconds(ms); while (!cond() && DateTime.UtcNow < end) await Task.Delay(25); Assert.True(cond(), "condition not met in time"); }

    [Fact]
    public async Task StartsReportsRunningTracksPlayersAndStopsGracefully()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); t.Write("server.properties", "server-port=25999\n");
        var rec = new ServerRecord { Name = "Fake", Path = t.Path, LaunchTarget = "server.jar", JavaPath = FakeJava(t), McVersion = "1.21", RamMB = 2048 };
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
        var rt = new ServerRuntime(rec.Id);
        var exited = new TaskCompletionSource<bool>();
        rt.Exited += (_, crashed) => exited.TrySetResult(crashed);
        rt.Start(rec);
        await WaitFor(() => rt.Status == Core.Adapters.ServerStatus.Running);
        Assert.True(File.Exists(Path.Combine(t.Path, ".craftpanel-session.json")));
        Assert.Equal("true", Properties.Load(t.Path).Get("enable-rcon"));   // RCON set up before launch

        rt.SendCommand("join Steve");
        await WaitFor(() => rt.Online().Contains("Steve"));
        rt.SendChat("hello \"world\"", "Host");
        await WaitFor(() => rt.Lines().Any(l => l.Text.Contains("got:tellraw @a")));
        Assert.Equal(ChatKind.Mine, rt.Chat().Last().Kind);

        rt.Stop();
        Assert.False(await exited.Task.WaitAsync(TimeSpan.FromSeconds(10)));   // not a crash
        Assert.Equal(Core.Adapters.ServerStatus.Stopped, rt.Status);
        Assert.Empty(rt.Online());
        Assert.False(File.Exists(Path.Combine(t.Path, ".craftpanel-session.json")));
    }

    [Fact]
    public async Task UnexpectedExitIsACrash()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); t.Write("server.properties", "");
        var rec = new ServerRecord { Name = "Fake", Path = t.Path, LaunchTarget = "server.jar", JavaPath = FakeJava(t), McVersion = "1.21" };
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
        var rt = new ServerRuntime(rec.Id);
        var exited = new TaskCompletionSource<bool>();
        rt.Exited += (_, crashed) => exited.TrySetResult(crashed);
        rt.Start(rec);
        await WaitFor(() => rt.Status == Core.Adapters.ServerStatus.Running);
        rt.SendCommand("crash");
        Assert.True(await exited.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(Core.Adapters.ServerStatus.Crashed, rt.Status); Assert.Equal(3, rt.ExitCode);
    }

    [Fact]
    public async Task KillStopsAStuckServerAndMissingJavaIsAClearError()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); t.Write("server.properties", "");
        var rec = new ServerRecord { Name = "Fake", Path = t.Path, LaunchTarget = "server.jar", JavaPath = FakeJava(t), McVersion = "1.21" };
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
        var rt = new ServerRuntime(rec.Id); rt.Start(rec);
        await WaitFor(() => rt.Status == Core.Adapters.ServerStatus.Running);
        rt.Kill();
        await WaitFor(() => !rt.IsRunning);
        File.WriteAllText(Path.Combine(t.Path, "x.jar"), "x");
        var bad = new ServerRuntime(Guid.NewGuid());
        var e = Assert.Throws<ProvisionException>(() => bad.Start(new ServerRecord { Path = t.Path, JavaPath = "/nonexistent/java", LaunchTarget = "x.jar", McVersion = null }));
        Assert.Contains("Java", e.Message);
        Assert.Equal(Core.Adapters.ServerStatus.Crashed, bad.Status);
    }

    [Fact]
    public async Task ManagerAdoptsAServerAfterRestartAndFollowsItsLog()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); t.Write("server.properties", ""); t.Write("logs/latest.log", "");
        var rec = new ServerRecord { Name = "Fake", Path = t.Path, LaunchTarget = "server.jar", JavaPath = FakeJava(t), McVersion = "1.21" };
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
        var first = new ServerRuntime(rec.Id); first.Start(rec);
        await WaitFor(() => first.Status == Core.Adapters.ServerStatus.Running);
        // a "restarted" CraftPanel: new manager, same folder
        var pm = new ProcessManager();
        Assert.Equal(1, pm.AdoptRunning([rec]));
        var adopted = pm.Runtime(rec.Id);
        Assert.True(adopted.Reattached); Assert.True(pm.AnyRunning);
        File.AppendAllText(Path.Combine(t.Path, "logs/latest.log"), "[12:00:05] [Server thread/INFO]: Zed joined the game\n");
        await WaitFor(() => adopted.Online().Contains("Zed"), 5000);
        first.Kill();
        await WaitFor(() => !adopted.IsRunning, 8000);
    }
}

public class BackupTests
{
    static string MakeServer(TempDir t)
    {
        t.Write("server.properties", "a=1\n"); t.Write("world/level.dat", "LEVEL"); t.Write("world/region/r.0.0.mca", "REGION");
        t.Write("logs/latest.log", "log"); t.Write("world/session.lock", "lock"); t.Write("craftpanel-backups/old.zip", "no");
        return t.Path;
    }

    [Fact]
    public void BackupExcludesInfraAndRestoresExactly()
    {
        using var t = new TempDir(); var dir = MakeServer(t);
        var b = BackupManager.BackupNow(dir, "first", "manual");
        using (var z = System.IO.Compression.ZipFile.OpenRead(Path.Combine(dir, "craftpanel-backups", b.Id + ".zip")))
            Assert.Equal(["server.properties", "world/level.dat", "world/region/r.0.0.mca"], z.Entries.Select(e => e.FullName).Order());
        Assert.True(BackupManager.VerifyAndRecord(dir, b.Id));
        Assert.True(BackupManager.List(dir).Single(x => x.Id == b.Id).Verified);

        File.WriteAllText(Path.Combine(dir, "world/level.dat"), "CHANGED"); File.Delete(Path.Combine(dir, "server.properties"));
        BackupManager.Restore(dir, b.Id);
        Assert.Equal("LEVEL", File.ReadAllText(Path.Combine(dir, "world/level.dat")));
        Assert.True(File.Exists(Path.Combine(dir, "server.properties")));
        Assert.Contains(BackupManager.List(dir), x => x.Trigger == "pre-restore");
        Assert.Contains(Directory.GetDirectories(dir), d => Path.GetFileName(d).StartsWith(BackupManager.PreRestorePrefix));
    }

    [Fact]
    public void CorruptBackupFailsRestoreAndRollsBack()
    {
        using var t = new TempDir(); var dir = MakeServer(t);
        var b = BackupManager.BackupNow(dir, null, "manual");
        File.WriteAllText(Path.Combine(dir, "craftpanel-backups", b.Id + ".zip"), "not a zip");
        File.WriteAllText(Path.Combine(dir, "world/level.dat"), "CURRENT");
        var e = Assert.Throws<ProvisionException>(() => BackupManager.Restore(dir, b.Id));
        Assert.Contains("put back", e.Message);
        Assert.Equal("CURRENT", File.ReadAllText(Path.Combine(dir, "world/level.dat")));
        Assert.False(BackupManager.VerifyAndRecord(dir, b.Id));
    }

    [Fact]
    public void PruneKeepsNewestAndNeverPreRestore()
    {
        using var t = new TempDir(); var dir = MakeServer(t);
        var ids = Enumerable.Range(0, 4).Select(i => BackupManager.BackupNow(dir, $"b{i}", i == 0 ? "pre-restore" : "manual").Id).ToList();
        // stamp distinct times
        for (var i = 0; i < ids.Count; i++)
        {
            var sc = Path.Combine(dir, "craftpanel-backups", ids[i] + ".json");
            File.WriteAllText(sc, File.ReadAllText(sc).Replace(System.Text.RegularExpressions.Regex.Match(File.ReadAllText(sc), "\"created_at\":\\d+").Value, $"\"created_at\":{1000 + i}"));
        }
        BackupManager.Prune(dir, 2);
        var left = BackupManager.List(dir).Select(b => b.Id).ToHashSet();
        Assert.Contains(ids[0], left);          // pre-restore is never pruned
        Assert.Contains(ids[3], left); Assert.Contains(ids[2], left); Assert.DoesNotContain(ids[1], left);
        Assert.Throws<ProvisionException>(() => BackupManager.Delete(dir, "../evil"));
    }

    [Fact]
    public void TieredRetention()
    {
        const long now = 1_000_000_000; const long day = 86400;
        var items = new (string, long)[] { ("recent", now - 3600), ("d1a", now - day - 100), ("d1b", now - day - 5000), ("d2", now - 2 * day), ("old", now - 30 * day) };
        var keep = Retention.TieredKeepIds(items, now, 24, 7);
        Assert.Contains("recent", keep); Assert.Contains("d1a", keep); Assert.DoesNotContain("d1b", keep); Assert.Contains("d2", keep); Assert.DoesNotContain("old", keep);
    }

    [Fact]
    public void LockedFilesAreSkippedNotFatal()
    {
        using var t = new TempDir(); var dir = MakeServer(t);
        var b = BackupManager.BackupNow(dir, null, "manual");
        Assert.True(b.SizeBytes > 0);
    }
}

public class AddonTests
{
    [Fact]
    public void BlueMapConfigEditsInPlace()
    {
        using var t = new TempDir(); var cfg = BlueMap.ConfigDir(t.Path, ServerType.Fabric);
        Directory.CreateDirectory(cfg);
        File.WriteAllText(Path.Combine(cfg, "core.conf"), "# accept-download: docs\naccept-download: false\nrender-thread-count: 1\n");
        File.WriteAllText(Path.Combine(cfg, "webserver.conf"), "enabled: true\nport: 8100\nsse-enabled: true\n");
        Assert.False(BlueMap.ConsentGiven(t.Path, ServerType.Fabric));
        BlueMap.Configure(t.Path, ServerType.Fabric, 8102);
        var core = File.ReadAllText(Path.Combine(cfg, "core.conf"));
        Assert.Contains("accept-download: true", core); Assert.Contains("# accept-download: docs", core); Assert.Contains("render-thread-count: 1", core);
        Assert.True(BlueMap.ConsentGiven(t.Path, ServerType.Fabric)); Assert.Equal(8102, BlueMap.Port(t.Path, ServerType.Fabric));
        Assert.Contains("sse-enabled: true", File.ReadAllText(Path.Combine(cfg, "webserver.conf")));
    }

    [Fact]
    public void BlueMapMinimalConfigAndPortPicking()
    {
        using var a = new TempDir();
        BlueMap.Configure(a.Path, ServerType.Paper, 8100);
        Assert.True(BlueMap.ConsentGiven(a.Path, ServerType.Paper));
        Directory.CreateDirectory(Path.Combine(a.Path, "plugins")); File.WriteAllText(Path.Combine(a.Path, "plugins", "bluemap-5.28-paper.jar"), "");
        Assert.True(BlueMap.IsInstalled(a.Path, ServerType.Paper));
        Assert.True(BlueMap.PickPort([(a.Path, ServerType.Paper)]) > 8100);
        Assert.False(BlueMap.Supported(ServerType.Vanilla)); Assert.False(BlueMap.Supported(ServerType.Bedrock)); Assert.True(BlueMap.Supported(ServerType.Fabric));
    }

    [Fact]
    public async Task LocalMapPageDetection()
    {
        var l = new TcpListener(IPAddress.Loopback, 0); l.Start(); var port = ((IPEndPoint)l.LocalEndpoint).Port;
        _ = Task.Run(async () => { while (true) { TcpClient c; try { c = await l.AcceptTcpClientAsync(); } catch { return; }
            var s = c.GetStream(); await s.ReadAsync(new byte[4096]); await s.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")); c.Close(); } });
        Assert.True(await BlueMap.IsUpAsync(port));
        l.Stop();
        Assert.False(await BlueMap.IsUpAsync(port));
    }

    [Fact]
    public void ManifestIsReadableAndSharedWithTheMacApp()
    {
        using var t = new TempDir();
        t.Write(".craftpanel-modrinth.json", "[{\"project_id\":\"P1\",\"slug\":\"lithium\",\"title\":\"Lithium\",\"filename\":\"lithium.jar\",\"version_id\":\"v1\",\"version_number\":\"0.1\",\"dependency\":false}]");
        var e = ModrinthClient.Installed(t.Path).Single();
        Assert.Equal("Lithium", e.Title); Assert.Equal("lithium.jar", e.Filename);
        t.Write("mods/lithium.jar");
        ModrinthClient.RemoveOne(t.Path, ServerType.Fabric, "P1");
        Assert.Empty(ModrinthClient.Installed(t.Path)); Assert.False(File.Exists(Path.Combine(t.Path, "mods", "lithium.jar")));
        Assert.Single(Directory.GetFiles(Path.Combine(t.Path, ".craftpanel-trash")));   // trashed, not deleted
    }

    [Fact]
    public void ContentDirsPerType()
    {
        Assert.EndsWith("plugins", ModrinthClient.ContentDir("/s", ServerType.Paper, "mod"));
        Assert.EndsWith("mods", ModrinthClient.ContentDir("/s", ServerType.Fabric, "mod"));
        Assert.Contains("datapacks", ModrinthClient.ContentDir("/s", ServerType.Fabric, "datapack"));
    }
}

public class AnalyticsTests
{
    [Fact]
    public void PlaytimeFromLatestAndRotatedLogs()
    {
        using var t = new TempDir();
        var day1 = new DateTime(2026, 9, 28);
        var gz = Path.Combine(t.Sub("logs/x"), "..", "2026-09-28-1.log.gz");
        using (var fs = File.Create(gz)) using (var z = new System.IO.Compression.GZipStream(fs, System.IO.Compression.CompressionLevel.Optimal)) using (var w = new StreamWriter(z))
        {
            w.WriteLine("[10:00:00] [Server thread/INFO]: Steve[/192.168.1.5:5555] logged in with entity id 1 at (0, 0, 0)");
            w.WriteLine("[10:00:01] [Server thread/INFO]: Steve joined the game");
            w.WriteLine("[10:30:01] [Server thread/INFO]: Steve left the game");
            w.WriteLine("[23:50:00] [Server thread/INFO]: Night_Owl joined the game");
            w.WriteLine("[00:20:00] [Server thread/INFO]: Night_Owl left the game");   // past midnight: still that file's next day
        }
        File.SetLastWriteTime(gz, day1);
        var latest = t.Write("logs/latest.log", "[09:00:00] [Server thread/INFO]: Steve joined the game\n[09:10:00] [Server thread/INFO]: Alex joined the game\n[09:20:00] [Server thread/INFO]: Alex left the game\n");
        File.SetLastWriteTime(latest, new DateTime(2026, 9, 29, 12, 0, 0));
        var stats = PlayerAnalytics.Load(t.Path, serverOnline: true);
        var steve = stats.Single(s => s.Name == "Steve");
        Assert.True(steve.TotalTime > TimeSpan.FromMinutes(30));      // 30 min earlier + the session still open in latest.log
        Assert.Equal(2, steve.Sessions); Assert.True(steve.Online); Assert.Equal("192.168.1.5", steve.LastIp);
        Assert.Equal(TimeSpan.FromMinutes(30), stats.Single(s => s.Name == "Night_Owl").TotalTime);
        Assert.Equal(TimeSpan.FromMinutes(10), stats.Single(s => s.Name == "Alex").TotalTime);
        Assert.False(stats.Single(s => s.Name == "Alex").Online);
        Assert.Equal("Steve", stats[0].Name);   // most recently seen first
        Assert.Equal("1 h 5 min", PlayerAnalytics.FormatDuration(TimeSpan.FromMinutes(65)));
    }
}
