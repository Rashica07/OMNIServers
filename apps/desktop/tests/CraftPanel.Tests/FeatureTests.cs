using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CraftPanel.Core;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Network;
using CraftPanel.Core.Nbt;
using Xunit;

namespace CraftPanel.Tests;

public class SnapshotTests
{
    static string Server(TempDir t)
    {
        var dir = t.Sub("srv/x"); dir = Path.GetDirectoryName(dir)!;
        File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=world\n");
        Directory.CreateDirectory(Path.Combine(dir, "world"));
        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), "LEVEL-ONE");
        File.WriteAllText(Path.Combine(dir, "world", "big.bin"), new string('b', 50_000));
        File.WriteAllText(Path.Combine(dir, "ops.json"), "[]");
        File.WriteAllText(Path.Combine(dir, "server.jar"), "JAR");
        Directory.CreateDirectory(Path.Combine(dir, "mods")); File.WriteAllText(Path.Combine(dir, "mods", "a.jar"), "MOD");
        Directory.CreateDirectory(Path.Combine(dir, "logs")); File.WriteAllText(Path.Combine(dir, "logs", "latest.log"), "noise");
        return dir;
    }

    [Fact]
    public void ASnapshotIsJustTheWorldNotTheWholeServer()
    {
        using var t = new TempDir(); var dir = Server(t);
        var s = SnapshotManager.SnapshotNow(dir, "manual");
        Assert.Equal(2, s.FileCount);                              // world/level.dat + world/big.bin
        Assert.True(s.IsWorld);
        var snap = Path.Combine(SnapshotManager.Root(dir), s.Id);
        Assert.Equal(["world"], Directory.GetDirectories(snap).Select(Path.GetFileName));
        Assert.Empty(Directory.GetFiles(snap));                    // no server.jar, ops.json, properties at the top
        Assert.False(Directory.Exists(Path.Combine(snap, "mods")));
    }

    [Fact]
    public void UnchangedFilesAreLinkedAndOnlyChangesCostSpace()
    {
        using var t = new TempDir(); var dir = Server(t);
        var s1 = SnapshotManager.SnapshotNow(dir, "manual");
        Assert.True(s1.NewBytes > 50_000);

        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), "LEVEL-ONE-AND-A-BIT");   // the only change
        var s2 = SnapshotManager.SnapshotNow(dir, "scheduled");
        Assert.Equal(2, s2.FileCount);
        Assert.Equal(new FileInfo(Path.Combine(dir, "world", "level.dat")).Length, s2.NewBytes);   // the 50 KB file wasn't copied again

        // proof they share one file on disk: a write through snapshot 1 shows up in snapshot 2
        var a = Path.Combine(SnapshotManager.Root(dir), s1.Id, "world", "big.bin");
        var b = Path.Combine(SnapshotManager.Root(dir), s2.Id, "world", "big.bin");
        using (var fs = new FileStream(a, FileMode.Append)) fs.WriteByte((byte)'!');
        Assert.Equal(new FileInfo(a).Length, new FileInfo(b).Length);

        Assert.Equal(["scheduled", "manual"], SnapshotManager.List(dir).Select(s => s.Trigger));
    }

    [Fact]
    public void DeletingOneSnapshotLeavesTheOthersIntact()
    {
        using var t = new TempDir(); var dir = Server(t);
        var s1 = SnapshotManager.SnapshotNow(dir, "manual");
        var s2 = SnapshotManager.SnapshotNow(dir, "manual");
        SnapshotManager.Delete(dir, s1.Id);
        Assert.Single(SnapshotManager.List(dir));
        Assert.Equal("LEVEL-ONE", File.ReadAllText(Path.Combine(SnapshotManager.Root(dir), s2.Id, "world", "level.dat")));
        Assert.Throws<ProvisionException>(() => SnapshotManager.Delete(dir, s1.Id));
        Assert.Throws<ProvisionException>(() => SnapshotManager.Delete(dir, "../evil"));
    }

    [Fact]
    public void RestoreSwapsOnlyTheWorldAndKeepsTheOldOneAside()
    {
        using var t = new TempDir(); var dir = Server(t);
        var snap = SnapshotManager.SnapshotNow(dir, "manual");
        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), "LEVEL-TWO-RUINED");
        File.WriteAllText(Path.Combine(dir, "ops.json"), "[{\"name\":\"edited since\"}]");      // server settings changed after the snapshot…
        File.WriteAllText(Path.Combine(dir, "mods", "b.jar"), "NEW-MOD");                           // …and a mod was added

        SnapshotManager.Restore(dir, snap.Id);
        Assert.Equal("LEVEL-ONE", File.ReadAllText(Path.Combine(dir, "world", "level.dat")));
        Assert.Contains("edited since", File.ReadAllText(Path.Combine(dir, "ops.json")));           // untouched by a world restore
        Assert.True(File.Exists(Path.Combine(dir, "mods", "b.jar")));
        // the ruined world was kept (moved aside, not deleted); no whole-server zip was made
        var aside = Directory.EnumerateDirectories(dir, ".craftpanel-pre-restore-*").Single();
        Assert.Equal("LEVEL-TWO-RUINED", File.ReadAllText(Path.Combine(aside, "world", "level.dat")));
        Assert.Empty(BackupManager.List(dir));
        Assert.Single(SnapshotManager.List(dir));                                                    // snapshots survive a restore
    }

    [Fact]
    public void PaperStyleSeparateDimensionFoldersAndCustomLevelNamesAreIncluded()
    {
        using var t = new TempDir();
        var dir = t.Sub("srv/x"); dir = Path.GetDirectoryName(dir)!;
        File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=Survival\n");
        foreach (var f in new[] { "Survival", "Survival_nether", "Survival_the_end", "world", "plugins" })
        { Directory.CreateDirectory(Path.Combine(dir, f)); File.WriteAllText(Path.Combine(dir, f, "level.dat"), f); }
        var s = SnapshotManager.SnapshotNow(dir, "manual");
        Assert.Equal(3, s.FileCount);                              // not "world" (another save) and not plugins
        File.WriteAllText(Path.Combine(dir, "Survival_nether", "level.dat"), "ruined");
        SnapshotManager.Restore(dir, s.Id);
        Assert.Equal("Survival_nether", File.ReadAllText(Path.Combine(dir, "Survival_nether", "level.dat")));
        Assert.Equal("world", File.ReadAllText(Path.Combine(dir, "world", "level.dat")));          // other worlds are left alone
    }

    [Fact]
    public void BedrockWorldsRestoreOnlyTheActiveWorld()
    {
        using var t = new TempDir();
        var dir = t.Sub("srv/x"); dir = Path.GetDirectoryName(dir)!;
        File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=Bedrock level\n");
        foreach (var w in new[] { "Bedrock level", "Other" })
        { Directory.CreateDirectory(Path.Combine(dir, "worlds", w, "db")); File.WriteAllText(Path.Combine(dir, "worlds", w, "db", "000001.ldb"), w); }
        var s = SnapshotManager.SnapshotNow(dir, "manual");
        Assert.Equal(1, s.FileCount);
        File.WriteAllText(Path.Combine(dir, "worlds", "Bedrock level", "db", "000001.ldb"), "ruined");
        File.WriteAllText(Path.Combine(dir, "worlds", "Other", "db", "000001.ldb"), "other-changed");
        SnapshotManager.Restore(dir, s.Id);
        Assert.Equal("Bedrock level", File.ReadAllText(Path.Combine(dir, "worlds", "Bedrock level", "db", "000001.ldb")));
        Assert.Equal("other-changed", File.ReadAllText(Path.Combine(dir, "worlds", "Other", "db", "000001.ldb")));
    }

    [Fact]
    public void NoWorldYetIsExplainedNotSnapshotted()
    {
        using var t = new TempDir();
        var dir = t.Sub("srv/x"); dir = Path.GetDirectoryName(dir)!;
        File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=world\n");
        var e = Assert.Throws<ProvisionException>(() => SnapshotManager.SnapshotNow(dir, "manual"));
        Assert.Contains("no world", e.Message);
        Assert.Empty(SnapshotManager.List(dir));
        Assert.Empty(Directory.GetDirectories(SnapshotManager.Root(dir)));      // nothing half-made left behind
    }

    [Fact]
    public void AFailedRestoreLeavesTheCurrentWorldAsItWas()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); var dir = Server(t);
        var s = SnapshotManager.SnapshotNow(dir, "manual");
        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), "CURRENT-STATE");
        var unreadable = Path.Combine(SnapshotManager.Root(dir), s.Id, "world", "big.bin");
        File.SetUnixFileMode(unreadable, UnixFileMode.None);                     // the copy back will fail part-way
        try
        {
            Assert.Throws<ProvisionException>(() => SnapshotManager.Restore(dir, s.Id));
            Assert.Equal("CURRENT-STATE", File.ReadAllText(Path.Combine(dir, "world", "level.dat")));
            Assert.Equal(50_000, new FileInfo(Path.Combine(dir, "world", "big.bin")).Length);
            Assert.Empty(Directory.EnumerateDirectories(dir, ".craftpanel-pre-restore-*"));
        }
        finally { File.SetUnixFileMode(unreadable, UnixFileMode.UserRead | UnixFileMode.UserWrite); }
    }

    [Fact]
    public void OlderWholeServerSnapshotsStillListAndRestoreTheWholeServer()
    {
        using var t = new TempDir(); var dir = Server(t);
        // what the previous version made: a mirror of the whole folder, no "scope" in its JSON
        var id = "1700000000-abc123";
        var snap = Path.Combine(SnapshotManager.Root(dir), id);
        foreach (var rel in BackupManager.Collect(dir))
        {
            var to = Path.Combine(snap, rel); Directory.CreateDirectory(Path.GetDirectoryName(to)!); File.Copy(Path.Combine(dir, rel), to);
        }
        File.WriteAllText(Path.Combine(SnapshotManager.Root(dir), id + ".json"), JsonSerializer.Serialize(new Snapshot { Id = id, CreatedAt = 1700000000, FileCount = 5 }));
        var listed = Assert.Single(SnapshotManager.List(dir));
        Assert.False(listed.IsWorld);

        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), "RUINED");
        File.WriteAllText(Path.Combine(dir, "ops.json"), "CHANGED");
        SnapshotManager.Restore(dir, id);
        Assert.Equal("LEVEL-ONE", File.ReadAllText(Path.Combine(dir, "world", "level.dat")));
        Assert.Equal("[]", File.ReadAllText(Path.Combine(dir, "ops.json")));                        // the whole server went back
        Assert.Contains(BackupManager.List(dir), b => b.Trigger == "pre-restore");                  // with the zip safety net
    }

    [Fact]
    public void ZipBackupRestoreNoLongerMovesSnapshotsAside()
    {
        using var t = new TempDir(); var dir = Server(t);
        SnapshotManager.SnapshotNow(dir, "manual");
        var bk = BackupManager.BackupNow(dir, null, "manual");
        BackupManager.Restore(dir, bk.Id);
        Assert.Single(SnapshotManager.List(dir));
    }

    [Fact]
    public void PruneKeepsRecentThenOnePerDay()
    {
        using var t = new TempDir(); var dir = Server(t);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        void Fake(string id, long age)
        {
            Directory.CreateDirectory(Path.Combine(SnapshotManager.Root(dir), id));
            File.WriteAllText(Path.Combine(SnapshotManager.Root(dir), id + ".json"), JsonSerializer.Serialize(new Snapshot { Id = id, CreatedAt = now - age }));
        }
        Fake("recent-1", 600); Fake("recent-2", 3600);                      // within 24 h: kept
        Fake("day2-a", 2 * 86400 + 100); Fake("day2-b", 2 * 86400 + 5000);   // same day: only the newer survives
        Fake("ancient", 90L * 86400);                                        // beyond 30 days: gone
        SnapshotManager.Prune(dir, 24, 30);
        var left = SnapshotManager.List(dir).Select(s => s.Id).ToHashSet();
        Assert.Contains("recent-1", left); Assert.Contains("recent-2", left);
        Assert.Contains("day2-a", left); Assert.DoesNotContain("day2-b", left);
        Assert.DoesNotContain("ancient", left);
    }

    [Fact]
    public void ListIgnoresASnapshotWhoseFolderIsGone()
    {
        using var t = new TempDir(); var dir = Server(t);
        var s = SnapshotManager.SnapshotNow(dir, "manual");
        Directory.Delete(Path.Combine(SnapshotManager.Root(dir), s.Id), true);
        Assert.Empty(SnapshotManager.List(dir));
    }

    [Fact]
    public void FileLockedBySomeoneElseIsStillSnapshotted()
    {
        using var t = new TempDir(); var dir = Server(t);
        using var held = new FileStream(Path.Combine(dir, "world", "level.dat"), FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);   // what a running server does
        var s = SnapshotManager.SnapshotNow(dir, "manual");
        Assert.Equal(2, s.FileCount);
    }

    [Fact]
    public void SchedulerTakesSnapshotsOnlyWhileRunning()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        var store = new ServerStore(Path.Combine(t.Path, "servers.json"));
        var rec = new ServerRecord { Name = "S", Path = Server(t), LaunchTarget = "server.jar", McVersion = "1.21" };
        Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
        rec.JavaPath = ProcessTests.FakeJava(t);
        rec.Schedule.SnapshotIntervalMins = 5;
        store.Add(rec);
        var pm = new CraftPanel.Core.Runtime.ProcessManager();
        using var sched = new CraftPanel.Core.Runtime.Scheduler(store, pm, AppSettings.Load(Path.Combine(t.Path, "settings.json")), startTimer: false);

        sched.Tick();                                       // not running → nothing
        Assert.Empty(SnapshotManager.List(rec.Path));
        pm.Start(rec);
        try
        {
            var rt = pm.Runtime(rec.Id);
            for (var i = 0; i < 400 && rt.Status != CraftPanel.Core.Adapters.ServerStatus.Running; i++) Thread.Sleep(25);
            sched.Tick();
            for (var i = 0; i < 200 && SnapshotManager.List(rec.Path).Count == 0; i++) Thread.Sleep(50);
            Assert.Single(SnapshotManager.List(rec.Path));
            sched.Tick();                                   // inside the interval → no second one
            Thread.Sleep(300);
            Assert.Single(SnapshotManager.List(rec.Path));
        }
        finally { pm.Runtime(rec.Id).Kill(); }
    }
}

public class NbtTests
{
    static NbtCompound Sample() => new([
        new("byte", new NbtByte(-5)), new("short", new NbtShort(-300)), new("int", new NbtInt(int.MinValue)), new("long", new NbtLong(long.MaxValue)),
        new("float", new NbtFloat(3.25f)), new("double", new NbtDouble(Math.PI)),
        new("bytes", new NbtByteArray([1, -2, 3])), new("ints", new NbtIntArray([1, -1, 1 << 20])), new("longs", new NbtLongArray([long.MinValue, 7])),
        new("name", new NbtString("Wörld ✓ 🌍 \0 end")),
        new("list", new NbtList(TagType.Int, [new NbtInt(1), new NbtInt(2)])),
        new("empty", new NbtList(TagType.Compound, [])),
        new("nested", new NbtCompound([new("deep", new NbtCompound([new("x", new NbtString("y"))]))])),
    ]);

    [Fact]
    public void EveryTagTypeSurvivesARoundTrip()
    {
        var bytes = Nbt.Encode("Data", Sample());
        var back = Nbt.Decode(bytes);
        Assert.Equal("Data", back.Name);
        Assert.Equal(bytes, Nbt.Encode(back.Name, back.Root));        // byte-for-byte identical
        var root = back.Root.Entries.ToDictionary(e => e.Key, e => e.Value);
        Assert.Equal(long.MaxValue, ((NbtLong)root["long"]).Value);
        Assert.Equal("Wörld ✓ 🌍 \0 end", ((NbtString)root["name"]).Value);
        Assert.Equal(TagType.Compound, ((NbtList)root["empty"]).ElementType);
        Assert.Equal(13, back.Root.Entries.Count);
    }

    [Fact]
    public void GzipAndPlainFilesAreWrittenBackAsTheyWereRead()
    {
        using var t = new TempDir();
        foreach (var gz in new[] { true, false })
        {
            var p = Path.Combine(t.Path, gz ? "a.dat" : "b.dat");
            Nbt.Write(p, new NbtFile("", Sample(), gz));
            var first = File.ReadAllBytes(p);
            Assert.Equal(gz, first[0] == 0x1f && first[1] == 0x8b);
            var f = Nbt.Read(p);
            Assert.Equal(gz, f.Gzip);
            ((NbtString)f.Root.Entries.First(e => e.Key == "name").Value).Value = "edited";
            Nbt.Write(p, f);
            Assert.Equal("edited", ((NbtString)Nbt.Read(p).Root.Entries.First(e => e.Key == "name").Value).Value);
            Assert.True(File.Exists(p + ".craftpanel-bak"));            // the previous file is kept
            Assert.Equal(first, File.ReadAllBytes(p + ".craftpanel-bak"));
        }
    }

    [Fact]
    public void ModifiedUtf8MatchesJava()
    {
        Assert.Equal([0xC0, 0x80], ModifiedUtf8.Encode("\0"));
        Assert.Equal([0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80], ModifiedUtf8.Encode("😀"));   // a surrogate pair, 3 bytes each
        Assert.Equal("😀", ModifiedUtf8.Decode([0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80]));
        Assert.Equal("😀", ModifiedUtf8.Decode(Encoding.UTF8.GetBytes("😀")));         // plain UTF-8 is tolerated
        Assert.Equal("é", ModifiedUtf8.Decode(ModifiedUtf8.Encode("é")));
    }

    [Fact]
    public void RealLevelDatRoundTripsExactly()
    {
        var real = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "MCServ", "world", "level.dat");
        if (!File.Exists(real)) return;                                // only on the dev Mac that has a real world
        var raw = File.ReadAllBytes(real);
        using var z = new GZipStream(new MemoryStream(raw), CompressionMode.Decompress);
        using var ms = new MemoryStream(); z.CopyTo(ms);
        var f = Nbt.Read(real);
        Assert.True(f.Gzip);
        Assert.Equal(ms.ToArray(), Nbt.Encode(f.Name, f.Root));       // decompressed bytes identical after decode+encode
        var data = (NbtCompound)f.Root.Entries.First(e => e.Key == "Data").Value;
        Assert.Contains(data.Entries, e => e.Key == "LevelName");
        Assert.Contains(data.Entries, e => e.Key == "LastPlayed");
    }

    [Fact]
    public void BrokenFilesAreRejectedNotCrashed()
    {
        var good = Nbt.Encode("", Sample());
        Assert.Throws<NbtException>(() => Nbt.Decode(good[..(good.Length / 2)]));                 // truncated
        Assert.Throws<NbtException>(() => Nbt.Decode([1, 0, 0, 5]));                               // root isn't a compound
        Assert.Throws<NbtException>(() => Nbt.Decode([10, 0, 0, 7, 0, 1, 0x61, 0x7f, 0xff, 0xff, 0xff])); // byte array claiming 2 GB
        Assert.Throws<NbtException>(() => Nbt.Decode([10, 0, 0, 9, 0, 1, 0x61, 0, 0, 0, 0, 5]));  // list of End with items
        var deep = new List<byte> { 10, 0, 0 };
        for (var i = 0; i < 700; i++) deep.AddRange([10, 0, 1, 0x61]);
        Assert.Throws<NbtException>(() => Nbt.Decode([.. deep]));                                  // nested too deep
        using var t = new TempDir();
        var p = t.Write("junk.dat", "this is not nbt");
        Assert.Throws<NbtException>(() => Nbt.Read(p));
        File.WriteAllBytes(p, [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff, 1, 2, 3]);
        Assert.Throws<NbtException>(() => Nbt.Read(p));                                            // gzip header, garbage body
    }

    [Fact]
    public void TooLongStringIsRefusedRatherThanTruncated()
    {
        var c = new NbtCompound([new("s", new NbtString(new string('a', 70_000)))]);
        Assert.Throws<NbtException>(() => Nbt.Encode("", c));
    }
}

public class TunnelTests
{
    static string FakeBore(TempDir t, string body)
    {
        var p = t.Write("bore.sh", "#!/bin/sh\n" + body + "\n");
        File.SetUnixFileMode(p, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return p;
    }

    static async Task WaitFor(Func<bool> cond, int ms = 8000) { var end = DateTime.UtcNow.AddMilliseconds(ms); while (!cond() && DateTime.UtcNow < end) await Task.Delay(25); Assert.True(cond(), "condition not met in time"); }

    [Fact]
    public async Task ShowsTheAddressBoreReportsAndStopsCleanly()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        // bore logs to stderr with colour codes when it thinks it's on a terminal
        var script = FakeBore(t, "echo \"$@\" > \"" + t.Path + "/args.txt\"\nprintf '\\033[2m2026\\033[0m \\033[32m INFO\\033[0m bore_cli::client: listening at bore.pub:40123\\n' >&2\nsleep 30");
        var tm = new TunnelManager { ExecutableOverride = script };
        var id = Guid.NewGuid();
        var changes = 0; tm.Changed += _ => Interlocked.Increment(ref changes);

        await tm.StartAsync(id, 25565);
        await WaitFor(() => tm.Status(id).Address is not null);
        Assert.Equal("bore.pub:40123", tm.Status(id).Address);
        Assert.True(tm.Status(id).Running);
        Assert.Equal("local 25565 --to bore.pub", (await File.ReadAllTextAsync(Path.Combine(t.Path, "args.txt"))).Trim());

        tm.Stop(id);
        Assert.False(tm.Status(id).Running);
        Assert.Null(tm.Status(id).Address);
        Assert.True(changes >= 3);
    }

    [Fact]
    public async Task NotesWhenTheTunnelDiesAndReportsErrors()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        var tm = new TunnelManager { ExecutableOverride = FakeBore(t, "echo 'Error: connection refused' >&2\nexit 1") };
        var id = Guid.NewGuid();
        await tm.StartAsync(id, 25565);
        await WaitFor(() => !tm.Status(id).Running && tm.Status(id).Error is not null);
        Assert.Contains("refused", tm.Status(id).Error);
    }

    [Fact]
    public async Task AMissingClientIsReportedNotThrown()
    {
        using var t = new TempDir();
        var tm = new TunnelManager { ExecutableOverride = Path.Combine(t.Path, "nope") };
        var id = Guid.NewGuid();
        await tm.StartAsync(id, 25565);
        Assert.False(tm.Status(id).Running);
        Assert.False(string.IsNullOrEmpty(tm.Status(id).Error));
    }

    [Fact]
    public async Task StartTwiceDoesNotSpawnTwoAndStopAllCleansUp()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        var tm = new TunnelManager { ExecutableOverride = FakeBore(t, "echo x >> \"" + t.Path + "/count.txt\"\nsleep 30") };
        var id = Guid.NewGuid();
        await tm.StartAsync(id, 1); await tm.StartAsync(id, 1);
        await WaitFor(() => File.Exists(Path.Combine(t.Path, "count.txt")));
        await Task.Delay(300);
        Assert.Single(File.ReadAllLines(Path.Combine(t.Path, "count.txt")));
        tm.StopAll();
        Assert.False(tm.Status(id).Running);
    }
}

public class CrossplayTests : IDisposable
{
    sealed class Stub(Func<HttpRequestMessage, HttpResponseMessage> f) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) => Task.FromResult(f(r));
    }

    readonly HttpClient _old = Http.Client;
    public void Dispose() => Http.Client = _old;

    static readonly byte[] GeyserJar = Enumerable.Range(0, 150_000).Select(i => (byte)(i * 7)).ToArray();
    static string Sha(byte[] b) => Convert.ToHexStringLower(SHA256.HashData(b));

    static HttpResponseMessage Json(string s) => new(HttpStatusCode.OK) { Content = new StringContent(s, Encoding.UTF8, "application/json") };

    /// <summary>A GeyserMC build API: both projects have a spigot build; only Geyser has fabric/neoforge (as in real life).</summary>
    static void Serve(string? geyserSha = null, bool floodgateSpigot = true, int build = 77, bool geyserDownloadFails = false)
    {
        Http.Client = new HttpClient(new Stub(r =>
        {
            var p = r.RequestUri!.AbsolutePath;
            if (r.RequestUri.Host == "download.geysermc.org")
            {
                var project = p.Contains("/floodgate/") ? "floodgate" : "geyser";
                if (p.EndsWith("/builds/latest"))
                {
                    if (project == "floodgate" && !floodgateSpigot) return new(HttpStatusCode.NotFound);
                    string Art(string a, string n) => $"\"{a}\":{{\"name\":\"{n}\",\"sha256\":\"{(project == "geyser" && geyserSha is not null ? geyserSha : Sha(GeyserJar))}\"}}";
                    return Json($"{{\"project_id\":\"{project}\",\"version\":\"2.0.0\",\"build\":{build},\"downloads\":{{{Art("spigot", project + "-Spigot.jar")},{Art("fabric", project + "-Fabric.jar")},{Art("neoforge", project + "-NeoForge.jar")}}}}}");
                }
                if (p.Contains("/downloads/") && geyserDownloadFails && project == "geyser") return new(HttpStatusCode.InternalServerError);
                if (p.Contains("/downloads/")) return new(HttpStatusCode.OK) { Content = new ByteArrayContent(GeyserJar) };
            }
            return new(HttpStatusCode.NotFound);   // Modrinth etc.: unavailable in this test
        }));
    }

    [Fact]
    public async Task PaperGetsGeyserAndFloodgateFromGeyserMc()
    {
        Serve();
        using var t = new TempDir();
        var before = CrossplayManager.Status(t.Path, ServerType.Paper);
        Assert.True(before.Compatible); Assert.False(before.Geyser); Assert.Equal(19132, before.BedrockPort);

        var st = await CrossplayManager.EnableAsync(t.Path, ServerType.Paper);
        Assert.True(st.Geyser && st.Floodgate);
        Assert.True(File.Exists(Path.Combine(t.Path, "plugins", "geyser-Spigot.jar")) || File.Exists(Path.Combine(t.Path, "plugins", "Geyser-Spigot.jar")));
        Assert.Equal(GeyserJar, await File.ReadAllBytesAsync(Directory.GetFiles(Path.Combine(t.Path, "plugins"), "*eyser*").Single()));
        Assert.Empty(Directory.GetFiles(Path.Combine(t.Path, "plugins"), "*.part"));
    }

    [Fact]
    public async Task AChecksumMismatchLeavesNothingBehind()
    {
        Serve(geyserSha: new string('0', 64));
        using var t = new TempDir();
        var e = await Assert.ThrowsAsync<ProvisionException>(() => CrossplayManager.EnableAsync(t.Path, ServerType.Paper));
        Assert.Contains("checksum", e.Message);
        Assert.False(CrossplayManager.Status(t.Path, ServerType.Paper).Geyser);
    }

    [Fact]
    public async Task IfFloodgateCantBeFetchedGeyserStaysAndYouAreTold()
    {
        Serve(floodgateSpigot: false);
        using var t = new TempDir();
        var e = await Assert.ThrowsAsync<ProvisionException>(() => CrossplayManager.EnableAsync(t.Path, ServerType.Paper));
        Assert.Contains("Floodgate couldn't be fetched", e.Message);
        var st = CrossplayManager.Status(t.Path, ServerType.Paper);
        Assert.True(st.Geyser); Assert.False(st.Floodgate);
    }

    [Theory]
    [InlineData(ServerType.Vanilla)] [InlineData(ServerType.Forge)] [InlineData(ServerType.Bedrock)]
    public async Task UnsupportedServerTypesAreRefused(ServerType type)
    {
        using var t = new TempDir();
        Assert.False(CrossplayManager.Status(t.Path, type).Compatible);
        await Assert.ThrowsAsync<ProvisionException>(() => CrossplayManager.EnableAsync(t.Path, type));
    }

    [Fact]
    public void ReadsTheBedrockPortFromGeysersConfigAndRemovalGoesToTrash()
    {
        using var t = new TempDir();
        Directory.CreateDirectory(Path.Combine(t.Path, "plugins", "Geyser-Spigot"));
        File.WriteAllText(Path.Combine(t.Path, "plugins", "Geyser-Spigot", "config.yml"), "java:\n  port: 25565\nbedrock:\n  address: 0.0.0.0\n  port: 19999\n  clone-remote-port: false\n");
        File.WriteAllText(Path.Combine(t.Path, "plugins", "Geyser-Spigot.jar"), "x");
        File.WriteAllText(Path.Combine(t.Path, "plugins", "floodgate-spigot.jar"), "x");
        File.WriteAllText(Path.Combine(t.Path, "plugins", "EssentialsX.jar"), "x");
        var st = CrossplayManager.Status(t.Path, ServerType.Paper);
        Assert.Equal(19999, st.BedrockPort); Assert.True(st.Geyser && st.Floodgate);

        CrossplayManager.Disable(t.Path, ServerType.Paper);
        Assert.False(CrossplayManager.Status(t.Path, ServerType.Paper).Geyser);
        Assert.True(File.Exists(Path.Combine(t.Path, "plugins", "EssentialsX.jar")));            // other plugins untouched
        Assert.Equal(2, Directory.GetFiles(Path.Combine(t.Path, ".craftpanel-trash")).Length);   // moved, not deleted
    }
}
