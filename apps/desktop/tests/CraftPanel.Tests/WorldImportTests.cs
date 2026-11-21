using System.IO.Compression;
using CraftPanel.Core;
using CraftPanel.Core.Nbt;
using CraftPanel.Core.Worlds;
using Xunit;

namespace CraftPanel.Tests;

public class WorldImportTests
{
    static byte[] LevelDat(string levelName = "My World", string? version = "1.21.4", long played = 1_700_000_000_000)
    {
        var data = new List<KeyValuePair<string, NbtTag>> { new("LevelName", new NbtString(levelName)), new("LastPlayed", new NbtLong(played)) };
        if (version is not null) data.Add(new("Version", new NbtCompound([new("Name", new NbtString(version)), new("Id", new NbtInt(4189))])));
        var root = new NbtCompound([new("Data", new NbtCompound(data))]);
        var raw = Nbt.Encode("", root);
        using var ms = new MemoryStream();
        using (var gz = new GZipStream(ms, CompressionLevel.Optimal, true)) gz.Write(raw);
        return ms.ToArray();
    }

    /// <summary>A world folder like Minecraft makes: level.dat, a region file, playerdata, a lock file.</summary>
    static string MakeWorld(string parent, string name, string? version = "1.21.4", long played = 1_700_000_000_000)
    {
        var w = Path.Combine(parent, name);
        Directory.CreateDirectory(Path.Combine(w, "region")); Directory.CreateDirectory(Path.Combine(w, "playerdata"));
        File.WriteAllBytes(Path.Combine(w, "level.dat"), LevelDat(name, version, played));
        File.WriteAllText(Path.Combine(w, "region", "r.0.0.mca"), "REGION:" + name);
        File.WriteAllText(Path.Combine(w, "playerdata", "abc.dat"), "PLAYER");
        File.WriteAllText(Path.Combine(w, "session.lock"), "lock");
        return w;
    }

    static string Zip(TempDir t, string zipName, params (string entry, byte[] data)[] files)
    {
        var path = Path.Combine(t.Path, zipName);
        using var z = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (entry, data) in files) { var e = z.CreateEntry(entry); using var s = e.Open(); s.Write(data); }
        return path;
    }

    static string ServerDir(TempDir t, string levelName = "world")
    {
        var d = Path.Combine(t.Path, "server"); Directory.CreateDirectory(d);
        File.WriteAllText(Path.Combine(d, "server.properties"), $"level-name={levelName}\n");
        return d;
    }

    [Fact]
    public void AWorldFolderIsFoundAndCopiedWithoutTouchingTheOriginal()
    {
        using var t = new TempDir();
        var src = MakeWorld(Path.Combine(t.Path, "friend"), "Our Survival");
        var server = ServerDir(t);
        var w = WorldImporter.Inspect(src);
        Assert.Equal("Our Survival", w.Name); Assert.Equal("1.21.4", w.McVersion); Assert.False(w.IsZip);

        var name = WorldImporter.Import(server, w);
        Assert.Equal("Our Survival", name);
        Assert.Equal("REGION:Our Survival", File.ReadAllText(Path.Combine(server, name, "region", "r.0.0.mca")));
        Assert.True(File.Exists(Path.Combine(server, name, "playerdata", "abc.dat")));
        Assert.False(File.Exists(Path.Combine(server, name, "session.lock")));            // the lock file is not copied
        Assert.True(File.Exists(Path.Combine(src, "region", "r.0.0.mca")));              // the original is untouched
    }

    [Fact]
    public void AWorldOneOrTwoFoldersDownIsFoundToo()
    {
        using var t = new TempDir();
        MakeWorld(Path.Combine(t.Path, "pick-me", "saves"), "Deep World");
        Assert.Equal("Deep World", WorldImporter.Inspect(Path.Combine(t.Path, "pick-me")).Name);
        Assert.Equal("Deep World", WorldImporter.Inspect(Path.Combine(t.Path, "pick-me", "saves")).Name);
    }

    [Fact]
    public void SeveralWorldsOrNoWorldGetAPlainExplanation()
    {
        using var t = new TempDir();
        MakeWorld(Path.Combine(t.Path, "saves"), "A"); MakeWorld(Path.Combine(t.Path, "saves"), "B");
        Assert.Contains("holds 2 worlds", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(Path.Combine(t.Path, "saves"))).Message);
        Directory.CreateDirectory(Path.Combine(t.Path, "empty"));
        Assert.Contains("no level.dat", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(Path.Combine(t.Path, "empty"))).Message);
        var notWorld = t.Write("notes.txt");
        Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(notWorld));
        Assert.Contains("Bedrock", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(t.Write("x.mcworld"))).Message);
    }

    [Fact]
    public void ADamagedLevelDatIsReportedNotCrashed()
    {
        using var t = new TempDir();
        var w = Path.Combine(t.Path, "bad"); Directory.CreateDirectory(w);
        File.WriteAllText(Path.Combine(w, "level.dat"), "this is not nbt");
        Assert.Contains("may be damaged", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(w)).Message);
    }

    [Theory]
    [InlineData("", "level.dat")]                          // level.dat at the top of the zip
    [InlineData("Our World/", "Our World/level.dat")]      // a top folder
    [InlineData("saves/Our World/", "saves/Our World/level.dat")]
    public void ZipsWithTheWorldAtAnyUsualDepthWork(string prefix, string levelEntry)
    {
        using var t = new TempDir();
        var zip = Zip(t, "Our World.zip", (levelEntry, LevelDat("Our World")), (prefix + "region/r.0.0.mca", "ZIPREGION"u8.ToArray()), (prefix + "session.lock", "x"u8.ToArray()));
        var w = WorldImporter.Inspect(zip);
        Assert.True(w.IsZip); Assert.Equal("Our World", w.Name);
        var server = ServerDir(t);
        var name = WorldImporter.Import(server, w);
        Assert.Equal("ZIPREGION", File.ReadAllText(Path.Combine(server, name, "region", "r.0.0.mca")));
        Assert.True(File.Exists(Path.Combine(server, name, "level.dat")));
        Assert.False(File.Exists(Path.Combine(server, name, "session.lock")));
    }

    [Fact]
    public void ZipsThatReachOutOrHoldSeveralWorldsAreRefused()
    {
        using var t = new TempDir();
        var evil = Zip(t, "evil.zip", ("World/level.dat", LevelDat()), ("../escape.txt", "x"u8.ToArray()));
        Assert.Contains("outside the server folder", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(evil)).Message);
        var two = Zip(t, "two.zip", ("A/level.dat", LevelDat()), ("B/level.dat", LevelDat()));
        Assert.Contains("holds 2 worlds", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(two)).Message);
        Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(Zip(t, "none.zip", ("readme.txt", "hi"u8.ToArray()))));
        Assert.Contains("valid .zip", Assert.Throws<ProvisionException>(() => WorldImporter.Inspect(t.Write("fake.zip", "not a zip"))).Message);
    }

    [Fact]
    public void PaperStyleNetherAndEndFoldersComeAlongAndAreRenamedTogether()
    {
        using var t = new TempDir();
        var parent = Path.Combine(t.Path, "paper-server");
        MakeWorld(parent, "world"); MakeWorld(parent, "world_nether"); MakeWorld(parent, "world_the_end");
        var w = WorldImporter.Inspect(Path.Combine(parent, "world"));
        Assert.True(w.HasNether && w.HasEnd);
        var server = ServerDir(t);
        Directory.CreateDirectory(Path.Combine(server, "world"));                      // "world" is taken → numbered
        var name = WorldImporter.Import(server, w);
        Assert.Equal("world-2", name);
        Assert.True(Directory.Exists(Path.Combine(server, "world-2_nether"))); Assert.True(Directory.Exists(Path.Combine(server, "world-2_the_end")));
        Assert.Empty(Directory.GetFiles(Path.Combine(server, "world")));                // the existing world wasn't merged into
        // picking the whole Paper server folder is not "3 worlds"
        Assert.Equal("world", WorldImporter.Inspect(parent).Name);

        var zip = Path.Combine(t.Path, "p.zip");
        ZipFile.CreateFromDirectory(parent, zip, CompressionLevel.Fastest, false);
        var zw = WorldImporter.Inspect(zip);
        Assert.Equal("world", zw.Name);
    }

    [Fact]
    public void NamesAreSafeUniqueAndNeverClashWithServerFolders()
    {
        using var t = new TempDir(); var server = ServerDir(t);
        Assert.Equal("mods-world", WorldImporter.UniqueName(server, "mods"));
        Assert.Equal("a_b_c", WorldImporter.UniqueName(server, "a/b\\c"));
        Assert.Equal("imported-world", WorldImporter.UniqueName(server, "..."));
        Directory.CreateDirectory(Path.Combine(server, "Base")); Directory.CreateDirectory(Path.Combine(server, "Base-2"));
        Assert.Equal("Base-3", WorldImporter.UniqueName(server, "Base"));
        Assert.True(WorldImporter.UniqueName(server, new string('x', 200)).Length <= 64);
    }

    [Theory]
    [InlineData("1.21.4", "1.21.1", true)]
    [InlineData("26.2", "1.21.4", true)]
    [InlineData("1.21", "1.21.0", false)]
    [InlineData("1.20.4", "1.21.1", false)]
    [InlineData("1.21.1", "1.21.1", false)]
    [InlineData("24w14a", "1.21.1", false)]            // snapshots can't be compared: no warning
    [InlineData(null, "1.21.1", false)]
    public void ANewerWorldThanTheServerIsWarnedAbout(string? world, string server, bool warns)
    {
        var msg = WorldImporter.VersionWarning(world, server);
        Assert.Equal(warns, msg is not null);
        if (warns) Assert.Contains("Change version", msg);
    }

    [Fact]
    public void SingleplayerWorldsAreListedNewestFirstAndOthersAreIgnored()
    {
        using var t = new TempDir(); var saves = Path.Combine(t.Path, "saves");
        MakeWorld(saves, "Old", played: 1_600_000_000_000); MakeWorld(saves, "New", played: 1_800_000_000_000);
        Directory.CreateDirectory(Path.Combine(saves, "not-a-world"));
        Assert.Equal(["New", "Old"], WorldImporter.FindSingleplayerWorlds(saves).Select(w => w.Name));
        Assert.Empty(WorldImporter.FindSingleplayerWorlds(Path.Combine(t.Path, "missing")));
    }

    [Fact]
    public void ExportMakesAZipThatAddsBackToAnotherServerAsIs()
    {
        using var t = new TempDir();
        var server = ServerDir(t, "Survival");
        MakeWorld(server, "Survival"); MakeWorld(server, "Survival_nether");
        File.WriteAllText(Path.Combine(server, "ops.json"), "[]");
        var zip = WorldImporter.Export(server, Path.Combine(t.Path, "out"));
        Assert.StartsWith("Survival-", Path.GetFileName(zip));
        using (var z = ZipFile.OpenRead(zip))
        {
            Assert.DoesNotContain(z.Entries, e => e.FullName.Contains("ops.json"));            // only the world
            Assert.DoesNotContain(z.Entries, e => e.FullName.Contains("session.lock"));
            Assert.Contains(z.Entries, e => e.FullName == "Survival/level.dat");
        }
        var other = Path.Combine(t.Path, "other-pc"); Directory.CreateDirectory(other);
        var name = WorldImporter.Import(other, WorldImporter.Inspect(zip));
        Assert.Equal("Survival", name);
        Assert.Equal("REGION:Survival", File.ReadAllText(Path.Combine(other, "Survival", "region", "r.0.0.mca")));
        Assert.True(Directory.Exists(Path.Combine(other, "Survival_nether")));
    }

    [Fact]
    public void ExportWithNoWorldExplainsWhy()
    {
        using var t = new TempDir();
        Assert.Contains("no world to export", Assert.Throws<ProvisionException>(() => WorldImporter.Export(ServerDir(t), t.Path)).Message);
    }

    [Fact]
    public void AFailedCopyLeavesNoHalfWorldBehind()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        var src = MakeWorld(Path.Combine(t.Path, "f"), "Locked");
        File.SetUnixFileMode(Path.Combine(src, "region", "r.0.0.mca"), UnixFileMode.None);   // can't be read
        var server = ServerDir(t);
        try
        {
            Assert.ThrowsAny<Exception>(() => WorldImporter.Import(server, WorldImporter.Inspect(src)));
            Assert.False(Directory.Exists(Path.Combine(server, "Locked")));
        }
        finally { File.SetUnixFileMode(Path.Combine(src, "region", "r.0.0.mca"), UnixFileMode.UserRead | UnixFileMode.UserWrite); }
    }

    [Fact]
    public void LinksInsideAWorldFolderAreNotFollowed()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        var src = MakeWorld(Path.Combine(t.Path, "f"), "Linky");
        var outside = Path.Combine(t.Path, "private"); Directory.CreateDirectory(outside); File.WriteAllText(Path.Combine(outside, "secret.txt"), "SECRET");
        Directory.CreateSymbolicLink(Path.Combine(src, "evil-link"), outside);
        var server = ServerDir(t);
        var name = WorldImporter.Import(server, WorldImporter.Inspect(src));
        Assert.False(File.Exists(Path.Combine(server, name, "evil-link", "secret.txt")));
    }
}
