using System.IO.Compression;
using System.Text.Json.Nodes;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Network;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class PumpkinEngineTests
{
    [Theory]
    [InlineData("windows", "x64", "pumpkin-X64-Windows.exe")]
    [InlineData("windows", "arm64", "pumpkin-ARM64-Windows.exe")]
    [InlineData("linux", "x64", "pumpkin-X64-Linux")]
    [InlineData("linux", "arm64", "pumpkin-ARM64-Linux")]
    [InlineData("macOS", "arm64", "pumpkin-ARM64-macOS")]
    public void ChoosesTheReleaseFileForEveryChip(string os, string arch, string expected) => Assert.Equal(expected, PumpkinEngine.AssetName(os, arch));

    [Fact]
    public void NoEngineForIntelMacOrUnknown()
    {
        Assert.Null(PumpkinEngine.AssetName("macOS", "x64"));
        Assert.Null(PumpkinEngine.AssetName("freebsd", "x64"));
    }

    [Fact]
    public void DownloadUrlEncodesThePlusInTheTag() =>
        Assert.Equal("https://github.com/Pumpkin-MC/Pumpkin/releases/download/0.2.2%2B26.3-26.60/pumpkin-X64-Linux", PumpkinEngine.DownloadUrl("0.2.2+26.3-26.60", "pumpkin-X64-Linux"));

    [Fact]
    public void ParsesTheChecksumList()
    {
        var h1 = new string('a', 64); var h2 = new string('B', 64);
        var m = PumpkinEngine.ParseChecksums($"{h1}  pumpkin-X64-Linux\n{h2} *pumpkin-X64-Windows.exe\nnot a line\n{new string('z', 64)}  bad\n");
        Assert.Equal(2, m.Count);
        Assert.Equal(h1, m["pumpkin-X64-Linux"]);
        Assert.Equal(new string('b', 64), m["pumpkin-X64-Windows.exe"]);
    }

    [Fact]
    public void PlacesAGoodDownloadAndRefusesABadOne()
    {
        using var t = new TempDir();
        var file = Path.Combine(t.Path, "dl"); File.WriteAllText(file, "engine bytes");
        var good = Http.Sha256Hex(file);
        var root = Path.Combine(t.Path, "engines");
        var placed = PumpkinEngine.Place(file, good, "1.0+x", root);
        Assert.True(File.Exists(placed));
        Assert.Equal(placed, PumpkinEngine.InstalledBinary(root));
        if (!OperatingSystem.IsWindows()) Assert.True(File.GetUnixFileMode(placed).HasFlag(UnixFileMode.UserExecute));

        var root2 = Path.Combine(t.Path, "engines2");
        Assert.Throws<ProvisionException>(() => PumpkinEngine.Place(file, new string('0', 64), "1.0+x", root2));
        Assert.Null(PumpkinEngine.InstalledBinary(root2));   // nothing was installed
    }

    [Fact]
    public void PrefersThePinnedEngineThenTheNewestInstalled()
    {
        using var t = new TempDir();
        var root = Path.Combine(t.Path, "e");
        foreach (var tag in new[] { "0.1.0", "0.3.0" }) { Directory.CreateDirectory(Path.Combine(root, tag)); File.WriteAllText(PumpkinEngine.BinaryPath(tag, root), "x"); }
        Assert.Equal(PumpkinEngine.BinaryPath("0.3.0", root), PumpkinEngine.InstalledBinary(root));
        Directory.CreateDirectory(Path.Combine(root, PumpkinEngine.PinnedTag)); File.WriteAllText(PumpkinEngine.BinaryPath(PumpkinEngine.PinnedTag, root), "x");
        Assert.Equal(PumpkinEngine.BinaryPath(PumpkinEngine.PinnedTag, root), PumpkinEngine.InstalledBinary(root));
    }
}

public class PumpkinConfigTests
{
    [Fact]
    public void RendersTheSafeDefaults()
    {
        var t = PumpkinConfig.Render(new() { Motd = "Hi", Port = 25570, MaxPlayers = 8, Gamemode = "creative", Difficulty = "hard", Seed = "abc" });
        Assert.Contains("seed = \"abc\"", t);
        Assert.Contains("default_gamemode = \"Creative\"", t);
        Assert.Contains("default_difficulty = \"Hard\"", t);
        Assert.Contains("[telemetry]\nenabled = false", t);
        Assert.Contains("[networking.bedrock]\nenabled = false", t);
        Assert.Contains("address = \"0.0.0.0:25570\"", t);
        Assert.Contains("online_mode = true", t);
        Assert.Contains("encryption = true", t);
        Assert.Contains("color = false", t);
        Assert.Contains("favicon_path = \"server-icon.png\"", t);
    }

    [Fact]
    public void OfflineModeTurnsOffEncryptionToo()
    {
        var t = PumpkinConfig.Render(new() { OnlineMode = false });
        Assert.Contains("online_mode = false", t);
        Assert.Contains("encryption = false", t);
    }

    [Fact]
    public void EscapesAndClamps()
    {
        var t = PumpkinConfig.Render(new() { Motd = "a \"quoted\" \\ line\nbreak", MaxPlayers = 99999, ViewDistance = 1, SimulationDistance = 99 });
        Assert.Contains("motd = \"a \\\"quoted\\\" \\\\ line break\"", t);
        Assert.Contains("max_players = 1000", t);
        Assert.Contains("view_distance = 2", t);
        Assert.Contains("simulation_distance = 32", t);
        Assert.Contains("max_players = 1", PumpkinConfig.Render(new() { MaxPlayers = -5 }));
    }

    [Fact]
    public void OptionalSectionsOnlyWhenAsked()
    {
        var plain = PumpkinConfig.Render(new());
        Assert.DoesNotContain("[pvp]", plain); Assert.DoesNotContain("[resource_pack.java]", plain); Assert.DoesNotContain("hardcore", plain);
        var t = PumpkinConfig.Render(new() { Pvp = false, Hardcore = true, ResourcePackUrl = "https://x/y.zip", ResourcePackSha1 = "abc", ResourcePackForce = true, LevelName = "My World" });
        Assert.Contains("[pvp]\nenabled = false", t); Assert.Contains("hardcore = true", t);
        Assert.Contains("url = \"https://x/y.zip\"", t); Assert.Contains("force = true", t);
        Assert.Contains("default_level_name = \"My World\"", t);
    }

    [Fact]
    public void ReadsThePortBack()
    {
        Assert.Equal(25577, PumpkinConfig.JavaPort(PumpkinConfig.Render(new() { Port = 25577 })));
        Assert.Null(PumpkinConfig.JavaPort("[networking.java]\naddress = \"0.0.0.0:0\"\n"));
        Assert.Null(PumpkinConfig.JavaPort("nothing here"));
        Assert.Equal(25599, PumpkinConfig.JavaPort("[networking.bedrock]\naddress = \"0.0.0.0:19132\"\n[networking.java]\naddress = \"[::]:25599\"\n"));
    }

    [Fact]
    public void ApplyChangesOnlyWhatSettingsOwnsAndKeepsEveryOtherLine()
    {
        using var t = new TempDir();
        var original = PumpkinConfig.Render(new() { Motd = "Old", Port = 25580, MaxPlayers = 10 }) + "\n# my own note\n[custom]\nkeep = \"me\"\n";
        File.WriteAllText(Path.Combine(t.Path, PumpkinConfig.FileName), original);
        PumpkinConfig.Apply(new(false, "New \"motd\"", 42, "adventure", "peaceful"), t.Path);
        var after = File.ReadAllText(Path.Combine(t.Path, PumpkinConfig.FileName));
        Assert.Contains("# my own note", after); Assert.Contains("keep = \"me\"", after);
        Assert.Contains("address = \"0.0.0.0:25580\"", after);
        var e = PumpkinConfig.Read(t.Path)!;
        Assert.Equal(new PumpkinConfig.Editable(false, "New \"motd\"", 42, "adventure", "peaceful"), e);
        Assert.Contains("encryption = false", after);
    }

    [Fact]
    public void SettingAddsMissingKeysAndSections()
    {
        Assert.Equal("a = 1\nb = 2\n[s]\nx = 1", PumpkinConfig.Setting("a = 1\n[s]\nx = 1", "", "b", "2"));
        Assert.Contains("[new]\nk = 5", PumpkinConfig.Setting("a = 1\n", "new", "k", "5"));
    }

    [Fact]
    public void OlderServersGetTheFavicon()
    {
        using var t = new TempDir();
        File.WriteAllText(Path.Combine(t.Path, PumpkinConfig.FileName), "default_gamemode = \"Survival\"\n[networking.java]\nmotd = \"x\"\n");
        PumpkinConfig.EnsureFavicon(t.Path);
        Assert.Equal("\"server-icon.png\"", PumpkinConfig.RawValue(File.ReadAllText(Path.Combine(t.Path, PumpkinConfig.FileName)), "", "favicon_path"));
    }
}

public class OmniHostAdapterTests
{
    [Fact]
    public void FindsTheEngineLikeAServerFolder()
    {
        using var t = new TempDir();
        Assert.False(OmniHostAdapter.IsServerFolder(t.Path));
        File.WriteAllText(Path.Combine(t.Path, "pumpkin.toml"), "");
        Assert.True(OmniHostAdapter.IsServerFolder(t.Path));
        var d = ServerDetector.DetectAsync(t.Path).GetAwaiter().GetResult();
        Assert.Equal(ServerType.OmniHost, d.ServerType);
        Assert.Null(d.Java);
    }

    [Fact]
    public void ResolvesTheBinaryStoredWithTheServerElseTheInstalledEngine()
    {
        using var t = new TempDir();
        var bin = Path.Combine(t.Path, "p"); File.WriteAllText(bin, "x");
        Assert.Equal(bin, OmniHostAdapter.ResolveBinary(bin, t.Path, "/engine"));
        Assert.Equal("/engine", OmniHostAdapter.ResolveBinary(Path.Combine(t.Path, "gone"), t.Path, "/engine"));
        Assert.Null(OmniHostAdapter.ResolveBinary("", t.Path, null));
        Assert.Equal(bin, OmniHostAdapter.ResolveBinary("p", t.Path, null));
    }

    [Fact]
    public void RunsInTheServerFolderWithNoArguments()
    {
        using var t = new TempDir();
        var spec = OmniHostAdapter.StartCommand(new ServerConfig(t.Path, "/x/pumpkin", "", 0, ServerType.OmniHost, null), "/x/pumpkin");
        Assert.NotNull(spec);
        Assert.Equal(t.Path, spec!.WorkingDirectory);
        Assert.Empty(spec.Args);
        Assert.Null(OmniHostAdapter.StartCommand(new ServerConfig(t.Path, "", "", 0, ServerType.OmniHost, null), null));
    }

    [Theory]
    [InlineData("INFO  Server is now running", ServerStatus.Running)]
    [InlineData("Received interrupt signal; stopping", ServerStatus.Stopping)]
    [InlineData("thread 'main' panicked at src/x.rs", ServerStatus.Crashed)]
    [InlineData("Loading world", ServerStatus.Unknown)]
    public void ReadsTheEnginesStatusLines(string line, ServerStatus expected) => Assert.Equal(expected, OmniHostAdapter.ParseStatus(line));

    [Fact]
    public void ConsoleIsShortAndNamesOmniHost()
    {
        Assert.Equal("[12:00:00] Ready. Join on port 25565", OmniHostLog.Simplify("12:00:00 INFO  Server is now running. | Java Edition: 0.0.0.0:25565 | Bedrock: off"));
        Assert.Equal("[12:00:00] Starting OMNIHost (Minecraft 26.3)", OmniHostLog.Simplify("12:00:00 INFO  Starting Pumpkin 0.2.2"));
        Assert.Equal("[12:00:01] Warning: OMNIHost is slow", OmniHostLog.Simplify("12:00:01 WARN  PumpkinMC is slow"));
        Assert.Null(OmniHostLog.Simplify("12:00:00 DEBUG  anything"));
        Assert.Null(OmniHostLog.Simplify("12:00:00 INFO  Please donate to the project"));
        Assert.Null(OmniHostLog.Simplify("   "));
        Assert.DoesNotContain("pumpkin", OmniHostLog.Simplify("plain Pumpkin line")!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("\u001b[0m", "\u001b[0m");   // ANSI is stripped before matching:
        Assert.Equal("[12:00:00] World saved", OmniHostLog.Simplify("\u001b[32m12:00:00 INFO  Completed save\u001b[0m"));
    }

    [Fact]
    public void PlayerLinesInTheShortFormatStillFeedTheOnlineList()
    {
        Assert.Equal(new LiveEvent.Join("Kiqa"), LiveEvent.Parse("[12:00:00] Kiqa joined the game"));
        Assert.Equal(new LiveEvent.Leave("Kiqa"), LiveEvent.Parse("[12:00:05] Kiqa left the game"));
        Assert.Equal(new LiveEvent.Chat("Kiqa", "hi"), LiveEvent.Parse("[12:00:06] <Kiqa> hi"));
    }

    [Fact]
    public void TheIconIsWrittenOnceAndNeverReplaced()
    {
        using var t = new TempDir();
        Assert.True(OmniHostAdapter.InstallIcon(t.Path));
        var bytes = File.ReadAllBytes(Path.Combine(t.Path, "server-icon.png"));
        Assert.Equal(0x89, bytes[0]);   // a PNG
        File.WriteAllText(Path.Combine(t.Path, "server-icon.png"), "mine");
        Assert.False(OmniHostAdapter.InstallIcon(t.Path));
        Assert.Equal("mine", File.ReadAllText(Path.Combine(t.Path, "server-icon.png")));
    }
}

public class OmniHostTransferTests
{
    static string MakeJavaServer(TempDir t, string props = "", bool withPlayers = true)
    {
        var dir = Path.Combine(t.Path, "java"); Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=world\nserver-port=25570\nmax-players=12\ngamemode=creative\ndifficulty=hard\nmotd=Hello\nonline-mode=false\n" + props);
        var world = Path.Combine(dir, "world"); Directory.CreateDirectory(Path.Combine(world, "region"));
        File.WriteAllText(Path.Combine(world, "level.dat"), "L"); File.WriteAllText(Path.Combine(world, "session.lock"), "lock");
        File.WriteAllText(Path.Combine(world, "region", "r.0.0.mca"), new string('r', 1000));
        File.WriteAllText(Path.Combine(dir, "ops.json"), "[{\"uuid\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"Betsmaens\",\"level\":4}]");
        File.WriteAllText(Path.Combine(dir, "usercache.json"), "[{\"uuid\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"Betsmaens\"}]");
        if (withPlayers)
        {
            foreach (var sub in new[] { "data", "stats", "advancements" }) Directory.CreateDirectory(Path.Combine(world, "players", sub));
            File.WriteAllText(Path.Combine(world, "players", "data", "11111111-1111-1111-1111-111111111111.dat"), "inv");
            File.WriteAllText(Path.Combine(world, "players", "stats", "11111111-1111-1111-1111-111111111111.json"), "{}");
            File.WriteAllText(Path.Combine(world, "players", "advancements", "11111111-1111-1111-1111-111111111111.json"),
                "{\"minecraft:story/root\":{\"criteria\":{\"c\":\"2026-08-29 17:40:46 +0200\"},\"done\":true}}");
            File.WriteAllText(Path.Combine(world, "players", "data", "00000000-0000-0000-0000-000000000009.dat"), "stranger");
        }
        return dir;
    }

    [Fact] public void OfflineIdMatchesWhatTheRealEngineAssigned() => Assert.Equal("fcb14d8a-f0cf-b45e-924e-055fb0d2055b", OmniHostTransfer.OfflineUuid("betsmaens"));

    [Fact]
    public void SettingsMapFromServerProperties()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t, "hardcore=true\npvp=false\nview-distance=8\nwhite-list=true\n");
        var s = OmniHostTransfer.SettingsFrom(Properties.Load(dir));
        Assert.Equal(25570, s.Port); Assert.Equal(12, s.MaxPlayers); Assert.Equal("creative", s.Gamemode); Assert.Equal("hard", s.Difficulty);
        Assert.False(s.OnlineMode); Assert.True(s.Hardcore); Assert.False(s.Pvp); Assert.Equal(8, s.ViewDistance); Assert.True(s.Whitelist);
    }

    [Fact]
    public void OddPropertiesFallBackToSafeDefaults()
    {
        using var t = new TempDir(); var dir = Path.Combine(t.Path, "x"); Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=../evil\nserver-port=0\nmax-players=abc\n");
        var s = OmniHostTransfer.SettingsFrom(Properties.Load(dir));
        Assert.Equal("world", s.LevelName); Assert.Equal(25565, s.Port); Assert.Equal(20, s.MaxPlayers); Assert.True(s.OnlineMode);
    }

    [Fact]
    public void AdvancementsConvertToTheEnginesLayout()
    {
        var o = JsonNode.Parse(OmniHostTransfer.ConvertAdvancements("{\"a\":{\"criteria\":{\"c\":\"2026-08-29 17:40:46 +0200\"},\"done\":true},\"b\":{\"x\":1}}")!)!;
        Assert.Equal(1788018046L, o["a"]!["c"]!["secs_since_epoch"]!.GetValue<long>());   // 15:40:46 UTC
        Assert.Equal(0, o["a"]!["c"]!["nanos_since_epoch"]!.GetValue<int>());
        Assert.Null(o["b"]);
        Assert.Null(OmniHostTransfer.ConvertAdvancements("not json"));
    }

    [Fact]
    public void RemapListRewritesIds()
    {
        var r = OmniHostTransfer.RemapList("[{\"uuid\":\"AAAA\",\"name\":\"x\"}]", new Dictionary<string, string> { ["aaaa"] = "new" })!;
        Assert.Equal("new", JsonNode.Parse(r)![0]!["uuid"]!.GetValue<string>());
    }

    [Fact]
    public void PlanDescribesWhatMovesAndWhatStaysBehind()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t);
        Directory.CreateDirectory(Path.Combine(dir, "mods")); Directory.CreateDirectory(Path.Combine(dir, "plugins"));
        File.WriteAllText(Path.Combine(dir, "plugins", "a.jar"), "x");
        var plan = OmniHostTransfer.MakePlan(dir, "My server");
        Assert.Equal(2, plan.PlayerCount); Assert.Equal(["ops.json"], plan.Lists); Assert.Equal(1, plan.PluginCount);
        Assert.True(plan.WorldBytes >= 1000 && plan.WorldBytes < 1100);   // session.lock is not counted
        Assert.Contains("1 plugin stays behind", OmniHostTransfer.LeftBehindSummary(plan));
    }

    [Fact]
    public void PlanFailsWithoutAWorld()
    {
        using var t = new TempDir(); var dir = Path.Combine(t.Path, "e"); Directory.CreateDirectory(dir);
        Assert.Throws<OmniHostTransfer.TransferException>(() => OmniHostTransfer.MakePlan(dir, "x"));
    }

    [Fact]
    public async Task OfflineMoveRenamesPlayerFilesAndListIdsAndLeavesTheSourceAlone()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t);
        var before = Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Order().ToList();
        var dest = Path.Combine(t.Path, "omni");
        await OmniHostTransfer.PerformAsync(OmniHostTransfer.MakePlan(dir, "J"), dest);

        var id = OmniHostTransfer.OfflineUuid("Betsmaens");
        var players = Path.Combine(dest, "world", "players");
        Assert.True(File.Exists(Path.Combine(players, "data", id + ".dat")));
        Assert.True(File.Exists(Path.Combine(players, "stats", id + ".json")));
        var adv = JsonNode.Parse(File.ReadAllText(Path.Combine(players, "advancements", id + ".json")))!;
        Assert.NotNull(adv["minecraft:story/root"]!["c"]!["secs_since_epoch"]);
        Assert.False(File.Exists(Path.Combine(players, "data", "11111111-1111-1111-1111-111111111111.dat")));
        Assert.Equal(id, JsonNode.Parse(File.ReadAllText(Path.Combine(dest, "data", "ops.json")))![0]!["uuid"]!.GetValue<string>());
        // a player with no known name can't be mapped to an offline id: counted out, and their stats/advancements are dropped
        Assert.False(File.Exists(Path.Combine(players, "stats", "00000000-0000-0000-0000-000000000009.json")));
        Assert.False(File.Exists(Path.Combine(dest, "world", "session.lock")));
        Assert.Contains("encryption = false", File.ReadAllText(Path.Combine(dest, "pumpkin.toml")));
        Assert.Contains("address = \"0.0.0.0:25570\"", File.ReadAllText(Path.Combine(dest, "pumpkin.toml")));
        Assert.True(File.Exists(Path.Combine(dest, "OMNIHost-transfer.txt")));
        Assert.True(File.Exists(Path.Combine(dest, "server-icon.png")));
        Assert.Equal(before, Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Order().ToList());   // source untouched
    }

    [Fact]
    public async Task OnlineMoveKeepsIdsAndStaysEncrypted()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t, "online-mode=true\n");
        var dest = Path.Combine(t.Path, "omni");
        await OmniHostTransfer.PerformAsync(OmniHostTransfer.MakePlan(dir, "J"), dest);
        Assert.True(File.Exists(Path.Combine(dest, "world", "players", "data", "11111111-1111-1111-1111-111111111111.dat")));
        Assert.Contains("encryption = true", File.ReadAllText(Path.Combine(dest, "pumpkin.toml")));
    }

    [Fact]
    public async Task NotEnoughSpaceStopsBeforeAnythingIsCreated()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t);
        var dest = Path.Combine(t.Path, "omni");
        var e = await Assert.ThrowsAsync<OmniHostTransfer.TransferException>(() => OmniHostTransfer.PerformAsync(OmniHostTransfer.MakePlan(dir, "J"), dest, free: 10));
        Assert.Contains("Not enough free space", e.Message);
        Assert.False(Directory.Exists(dest));
    }

    [Fact]
    public async Task AnExistingDestinationIsNeverTouched()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t);
        var dest = Path.Combine(t.Path, "omni"); Directory.CreateDirectory(dest); File.WriteAllText(Path.Combine(dest, "mine.txt"), "keep");
        await Assert.ThrowsAsync<OmniHostTransfer.TransferException>(() => OmniHostTransfer.PerformAsync(OmniHostTransfer.MakePlan(dir, "J"), dest));
        Assert.Equal("keep", File.ReadAllText(Path.Combine(dest, "mine.txt")));
    }

    [Fact]
    public async Task AFailedMoveRemovesTheHalfMadeFolder()
    {
        using var t = new TempDir(); var dir = MakeJavaServer(t);
        var plan = OmniHostTransfer.MakePlan(dir, "J");
        Directory.Delete(Path.Combine(dir, "world"), true);   // the world vanishes after planning
        var dest = Path.Combine(t.Path, "omni");
        await Assert.ThrowsAnyAsync<Exception>(() => OmniHostTransfer.PerformAsync(plan, dest));
        Assert.False(Directory.Exists(dest));
    }

    [Fact]
    public void OnlyJavaServersCanMove()
    {
        Assert.True(OmniHostTransfer.CanTransfer(ServerType.Paper)); Assert.True(OmniHostTransfer.CanTransfer(ServerType.Fabric));
        Assert.False(OmniHostTransfer.CanTransfer(ServerType.Bedrock)); Assert.False(OmniHostTransfer.CanTransfer(ServerType.OmniHost)); Assert.False(OmniHostTransfer.CanTransfer(ServerType.Terraria));
    }

    static void Jar(string path, string? fabricJson)
    {
        using var z = ZipFile.Open(path, ZipArchiveMode.Create);
        if (fabricJson is null) { z.CreateEntry("x.txt"); return; }
        using var w = new StreamWriter(z.CreateEntry("fabric.mod.json").Open()); w.Write(fabricJson);
    }

    [Fact]
    public void ModsAreSortedByWhatTheyAre()
    {
        using var t = new TempDir(); var mods = Path.Combine(t.Path, "mods"); Directory.CreateDirectory(mods);
        Jar(Path.Combine(mods, "a.jar"), "{\"id\":\"sodium\",\"name\":\"Sodium\",\"environment\":\"client\"}");
        Jar(Path.Combine(mods, "b.jar"), "{\"id\":\"lithium\",\"name\":\"Lithium\"}");
        Jar(Path.Combine(mods, "c.jar"), "{\"id\":\"create\",\"name\":\"Create\"}");
        Jar(Path.Combine(mods, "d.jar"), "{\"id\":\"fabric-api\",\"name\":\"Fabric API\"}");
        Jar(Path.Combine(mods, "e.jar"), null);
        var r = OmniHostTransfer.ClassifyMods(t.Path);
        Assert.Equal(["Sodium"], r.ClientOnly); Assert.Equal(["Lithium"], r.NotNeeded); Assert.Equal(["Create", "e"], r.Gameplay); Assert.Equal(4, r.Total);
    }
}

public class OmniLauncherLinkTests
{
    [Fact]
    public void RequestMatchesWhatTheLauncherReads()
    {
        var j = JsonNode.Parse(OmniLauncherLink.Encode(new("My server", "localhost:25565", "x.bore.pub:1234", "26.3", 1700000000)))!;
        Assert.Equal("My server", j["name"]!.GetValue<string>()); Assert.Equal("localhost:25565", j["address"]!.GetValue<string>());
        Assert.Equal("x.bore.pub:1234", j["public_address"]!.GetValue<string>()); Assert.Equal("26.3", j["minecraft"]!.GetValue<string>());
        Assert.Equal(1700000000L, j["created"]!.GetValue<long>());
        Assert.Null(JsonNode.Parse(OmniLauncherLink.Encode(new("a", "b", null, "1", 1)))!["public_address"]);
        Assert.Null(JsonNode.Parse(OmniLauncherLink.Encode(new("a", "b", "  ", "1", 1)))!["public_address"]);
    }

    [Fact]
    public void DataFolderFollowsTheLaunchersOwnRules()
    {
        Assert.Equal("/custom", OmniLauncherLink.DataDir(launcherHomeEnv: "/custom"));
        if (OperatingSystem.IsLinux())
        {
            Assert.Equal("/h/.local/share/omni-launcher", OmniLauncherLink.DataDir(home: "/h", xdgDataHome: "", launcherHomeEnv: ""));
            Assert.Equal("/xdg/omni-launcher", OmniLauncherLink.DataDir(home: "/h", xdgDataHome: "/xdg", launcherHomeEnv: ""));
        }
        if (OperatingSystem.IsWindows())
            Assert.Equal(@"C:\Users\k\AppData\Roaming\omni-launcher", OmniLauncherLink.DataDir(home: @"C:\Users\k", appData: @"C:\Users\k\AppData\Roaming", launcherHomeEnv: ""));
        if (OperatingSystem.IsMacOS())
            Assert.Equal("/Users/k/Library/Application Support/omni-launcher", OmniLauncherLink.DataDir(home: "/Users/k", launcherHomeEnv: ""));
    }

    [Fact]
    public void AlsoWritesWhereASourceBuiltLauncherWatches()
    {
        using var t = new TempDir();
        Assert.Null(OmniLauncherLink.DevDir(t.Path));
        Directory.CreateDirectory(Path.Combine(t.Path, ".omni-launcher-dev"));
        Assert.Equal(Path.Combine(t.Path, ".omni-launcher-dev"), OmniLauncherLink.DevDir(t.Path));
        Assert.Equal(2, OmniLauncherLink.RequestDirs(t.Path, launcherHomeEnv: "").Count);
    }

    [Fact]
    public void WritesTheRequestEverywhereAndOnlyThrowsIfNoneWorked()
    {
        using var t = new TempDir();
        var r = new OmniLauncherLink.JoinRequest("n", "a:1", null, "26.3", 5);
        var a = Path.Combine(t.Path, "a"); var b = Path.Combine(t.Path, "b");
        OmniLauncherLink.WriteEverywhere(r, [a, b]);
        Assert.True(File.Exists(Path.Combine(a, "join-request.json"))); Assert.True(File.Exists(Path.Combine(b, "join-request.json")));
        Assert.Empty(Directory.EnumerateFiles(a, "*.tmp-*"));
        var blocked = Path.Combine(t.Path, "file"); File.WriteAllText(blocked, "x");
        OmniLauncherLink.WriteEverywhere(r, [Path.Combine(blocked, "sub"), a]);   // one bad folder is fine
        Assert.ThrowsAny<Exception>(() => OmniLauncherLink.WriteEverywhere(r, [Path.Combine(blocked, "sub")]));
    }

    [Fact]
    public void PlayNeedsTheLauncherAndAVersion()
    {
        Assert.True(OmniLauncherLink.CanPlay("26.3", installed: true));
        Assert.False(OmniLauncherLink.CanPlay("26.3", installed: false));
        Assert.False(OmniLauncherLink.CanPlay("  ", installed: true));
        Assert.False(OmniLauncherLink.CanPlay(null, installed: true));
    }

    [Fact]
    public void FindsAnInstalledLauncher() =>
        Assert.Equal("/b/omni-launcher", OmniLauncherLink.InstalledPath(p => p == "/b/omni-launcher", ["/a/omni-launcher", "/b/omni-launcher"]));
}

/// <summary>Real download and a real server. Off unless <c>OMNI_LIVE=1</c> (needs network and about 100 MB).</summary>
public class OmniHostLiveTests
{
    [Fact]
    public async Task DownloadStartPingAndStopTheRealEngine()
    {
        if (Environment.GetEnvironmentVariable("OMNI_LIVE") != "1") return;
        using var t = new TempDir();
        var oldOverride = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            var dir = Path.Combine(t.Path, "srv");
            var port = 25688;
            var created = await OmniHostCreator.CreateAsync(dir, new() { Motd = "Live test", Port = port, MaxPlayers = 5, Gamemode = "creative", OnlineMode = false });
            Assert.True(File.Exists(created.LaunchTarget));
            var rec = new ServerRecord { Name = "Live", Path = dir, ServerType = ServerType.OmniHost, LaunchTarget = created.LaunchTarget, McVersion = created.McVersion };
            var rt = new ServerRuntime(rec.Id);
            rt.Start(rec);
            var end = DateTime.UtcNow.AddSeconds(40);
            while (rt.Status != ServerStatus.Running && DateTime.UtcNow < end) await Task.Delay(100);
            Assert.True(rt.Status == ServerStatus.Running, string.Join("\n", rt.Lines().Select(l => l.Text)));
            var shown = string.Join("\n", rt.Lines().Where(l => l.Stream != LogStream.System).Select(l => l.Text));
            Assert.Contains($"Ready. Join on port {port}", shown);
            Assert.DoesNotContain("pumpkin", shown, StringComparison.OrdinalIgnoreCase);

            using (var c = new System.Net.Sockets.TcpClient())
            {
                await c.ConnectAsync("127.0.0.1", port);
                var s = c.GetStream();
                static byte[] VarInt(int n) { var o = new List<byte>(); do { var b = (byte)(n & 0x7f); n >>= 7; o.Add((byte)(n != 0 ? b | 0x80 : b)); } while (n != 0); return [.. o]; }
                static byte[] Pkt(byte[] b) => [.. VarInt(b.Length), .. b];
                var host = System.Text.Encoding.ASCII.GetBytes("localhost");
                byte[] hs = [0, .. VarInt(777), .. VarInt(host.Length), .. host, (byte)(port >> 8), (byte)(port & 255), .. VarInt(1)];
                await s.WriteAsync(Pkt(hs).Concat(Pkt([0])).ToArray());
                var buf = new byte[65536]; var n = await s.ReadAsync(buf);
                var text = System.Text.Encoding.Latin1.GetString(buf, 0, n);
                Assert.Contains("Live test", text); Assert.Contains("26.3", text);
            }
            rt.Stop();
            end = DateTime.UtcNow.AddSeconds(30);
            while (rt.IsRunning && DateTime.UtcNow < end) await Task.Delay(100);
            Assert.False(rt.IsRunning);
            Assert.Equal(0, rt.ExitCode);
            Assert.True(File.Exists(Path.Combine(dir, "world", "level.dat")));
        }
        finally { AppPaths.DataOverride = oldOverride; }
    }
}
