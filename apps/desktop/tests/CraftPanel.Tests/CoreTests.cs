using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Java;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class JavaTests
{
    [Theory]
    [InlineData("openjdk version \"1.8.0_361\" 2023", 8u)]
    [InlineData("openjdk version \"17.0.8\" 2023-07-18", 17u)]
    [InlineData("java version \"21\" 2023-09-19", 21u)]
    [InlineData("openjdk version \"25.0.4.1\" 2026-04-21", 25u)]
    public void ParsesMajor(string banner, uint major) => Assert.Equal(major, JavaProbe.ParseMajor(banner));

    [Fact] public void ParseMajorRejectsGarbage() => Assert.Null(JavaProbe.ParseMajor("no quotes here"));

    [Theory]
    [InlineData("1.16.5", 8u)] [InlineData("1.17.1", 16u)] [InlineData("1.19.4", 17u)] [InlineData("1.20.4", 17u)]
    [InlineData("1.20.5", 21u)] [InlineData("1.21.1", 21u)] [InlineData("26.1", 25u)] [InlineData("26.2.1", 25u)]
    public void RequiredJava(string mc, uint need) => Assert.Equal(need, JavaProbe.RequiredJava(mc));

    [Fact]
    public void CompatibilityWarning()
    {
        Assert.NotNull(JavaProbe.CompatibilityWarning(new("java", "", 17, true), "26.2"));
        Assert.Null(JavaProbe.CompatibilityWarning(new("java", "", 25, true), "26.2"));
        Assert.Null(JavaProbe.CompatibilityWarning(new("java", "", 21, true), null));
    }

    [Fact]
    public void AutoResolveLeavesExplicitPathsAlone()
    {
        using var t = new TempDir();
        var real = t.Write("bin/java" + Platform.ExeSuffix);
        Assert.Null(JavaProbe.AutoResolve(real, "1.21"));
        Assert.Null(JavaProbe.AutoResolve("java", null));
    }

    [Fact]
    public void ManagedRuntimeIsFoundAndPreferred()
    {
        using var t = new TempDir();
        var prevData = AppPaths.DataOverride; AppPaths.DataOverride = t.Path;
        try
        {
            var dir = Path.Combine(JavaInstaller.InstallDir(25), "jdk-25.0.1+9-jre", "bin");
            Directory.CreateDirectory(dir);
            var exe = Path.Combine(dir, "java" + Platform.ExeSuffix);
            File.WriteAllText(exe, "");
            Assert.Equal(exe, JavaInstaller.InstalledPath(25));
            Assert.Equal(exe, JavaProbe.AutoResolve("java", "26.2"));
            Assert.Equal(exe, JavaProbe.AutoResolve(Path.Combine(t.Path, "gone", "java"), "1.21.1"));   // 25 satisfies 21
            Assert.Null(JavaInstaller.InstalledPath(21));
        }
        finally { AppPaths.DataOverride = prevData; }
    }

    [Fact] public void OfferableFeature()
    {
        Assert.Equal(17u, JavaInstaller.OfferableFeature(17));
        Assert.Equal(17u, JavaInstaller.OfferableFeature(16));
        Assert.Equal(25u, JavaInstaller.OfferableFeature(25));
        Assert.Null(JavaInstaller.OfferableFeature(26));
    }
}

public class DetectionTests
{
    [Fact]
    public void FabricWinsOverBareServerJar()
    {
        using var t = new TempDir();
        t.Write("server.jar"); t.Write("fabric-server-launch.jar"); t.Write("fabric-server-launcher.properties", "serverJar=server-1.21.1.jar");
        var d = MinecraftAdapter.Inspect(t.Path)!;
        Assert.Equal(ServerType.Fabric, d.ServerType);
        Assert.Equal("fabric-server-launch.jar", d.LaunchTarget);
        Assert.Equal("1.21.1", d.McVersion);
    }

    [Fact]
    public void NeoForgeIsNotForge()
    {
        using var t = new TempDir();
        t.Write("run.sh"); Directory.CreateDirectory(Path.Combine(t.Path, "libraries/net/neoforged"));
        Assert.Equal(ServerType.NeoForge, MinecraftAdapter.Detect(t.Path));
        using var f = new TempDir();
        f.Write("run.sh"); Directory.CreateDirectory(Path.Combine(f.Path, "libraries/net/minecraftforge"));
        Assert.Equal(ServerType.Forge, MinecraftAdapter.Detect(f.Path));
    }

    [Fact]
    public void PaperSpigotVanillaAndEmpty()
    {
        using var p = new TempDir(); p.Write("paper-1.21.1-100.jar");
        Assert.Equal(ServerType.Paper, MinecraftAdapter.Detect(p.Path));
        using var s = new TempDir(); s.Write("spigot-1.20.4.jar");
        Assert.Equal(ServerType.Spigot, MinecraftAdapter.Detect(s.Path));
        using var v = new TempDir(); v.Write("server.jar");
        Assert.Equal(ServerType.Vanilla, MinecraftAdapter.Detect(v.Path));
        using var e = new TempDir();
        Assert.Null(MinecraftAdapter.Inspect(e.Path));
        using var m = new TempDir(); m.Write("a.jar"); m.Write("b.jar");
        Assert.Null(MinecraftAdapter.Inspect(m.Path));
    }

    [Fact]
    public void VersionTokens()
    {
        Assert.Equal("1.20.4", MinecraftAdapter.ExtractVersionToken("minecraft_server.1.20.4.jar"));
        Assert.Equal("26.2", MinecraftAdapter.ExtractVersionToken("server-26.2.jar"));
        Assert.Null(MinecraftAdapter.ExtractVersionToken("server.jar"));
        Assert.False(MinecraftAdapter.IsMcVersion("5.28"));
    }

    [Fact]
    public void BedrockDetection()
    {
        using var t = new TempDir(); t.Write(BedrockAdapter.BinaryName);
        Assert.Equal(BedrockAdapter.BinaryName, BedrockAdapter.Inspect(t.Path));
    }
}

public class LaunchTests
{
    [Fact]
    public void JarLaunchStartsSmallAndCapsAtRam()
    {
        var spec = MinecraftAdapter.StartCommand(new("/srv", "paper.jar", "java", 8192, ServerType.Paper, "-XX:+UseG1GC bogus -Dx=1"));
        Assert.Equal(["-Xms1024M", "-Xmx8192M", "-XX:+UseG1GC", "-Dx=1", "-jar", "paper.jar", "nogui"], spec.Args);
        Assert.Equal(768u, MinecraftAdapter.InitialHeapMB(768));
    }

    [Fact]
    public void ForgeUsesArgsFileAndUserJvmArgs()
    {
        using var t = new TempDir();
        var argName = Platform.IsWindows ? "win_args.txt" : "unix_args.txt";
        t.Write($"libraries/net/minecraftforge/forge/1.20.1-47.2.0/{argName}");
        t.Write("user_jvm_args.txt", "# keep me\n-Xmx1G\n-Dkeep=1\n");
        var cfg = new ServerConfig(t.Path, "run.bat", "java", 6144, ServerType.Forge, "-Dextra=2");
        var spec = MinecraftAdapter.StartCommand(cfg);
        Assert.Equal(["@user_jvm_args.txt", $"@libraries/net/minecraftforge/forge/1.20.1-47.2.0/{argName}", "nogui"], spec.Args);
        MinecraftAdapter.EnsureUserJvmArgs(cfg);
        var text = File.ReadAllText(Path.Combine(t.Path, "user_jvm_args.txt"));
        Assert.Contains("# keep me", text); Assert.Contains("-Dkeep=1", text); Assert.Contains("-Xms1024M", text); Assert.Contains("-Xmx6144M", text);
        Assert.DoesNotContain("-Xmx1G", text); Assert.Contains("-Dextra=2", text);
        MinecraftAdapter.EnsureUserJvmArgs(cfg);   // idempotent
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(File.ReadAllText(Path.Combine(t.Path, "user_jvm_args.txt")), "-Xmx6144M"));
    }

    [Fact]
    public void LegacyForgeWithoutArgsFileFallsBackToJar()
    {
        using var t = new TempDir(); t.Write("forge-1.12.2-14.23.5.2860.jar"); t.Write("forge-1.12.2-installer.jar");
        var spec = MinecraftAdapter.StartCommand(new(t.Path, "run.sh", "java", 2048, ServerType.Forge, null));
        Assert.Contains("forge-1.12.2-14.23.5.2860.jar", spec.Args);
    }

    [Fact]
    public void AikarFlagsHaveNoPreTouch()
    {
        Assert.DoesNotContain("AlwaysPreTouch", JvmArgs.AikarFlags(4096));
        Assert.Contains("G1HeapRegionSize=16M", JvmArgs.AikarFlags(16384));
    }

    [Theory]
    [InlineData("[12:00:00] [Server thread/INFO]: Done (3.2s)! For help, type \"help\"", ServerStatus.Running)]
    [InlineData("[12:00:00] [main/INFO]: Starting minecraft server version 1.21", ServerStatus.Starting)]
    [InlineData("[12:00:00] [main/INFO]: Stopping the server", ServerStatus.Stopping)]
    [InlineData("hello", ServerStatus.Unknown)]
    public void ParsesStatus(string line, ServerStatus s) => Assert.Equal(s, MinecraftAdapter.ParseStatus(line));

    [Fact]
    public void DeriveMcVersion()
    {
        Assert.Equal("1.20.1", Provisioner.DeriveMcVersion(Loader.Forge, "1.20.1-47.2.0"));
        Assert.Equal("1.21.1", Provisioner.DeriveMcVersion(Loader.NeoForge, "21.1.172"));
        Assert.Equal("26.2", Provisioner.DeriveMcVersion(Loader.NeoForge, "26.2.5"));
        Assert.Equal("1.21", Provisioner.DeriveMcVersion(Loader.NeoForge, "21.0.5"));
        Assert.Equal("1.20.4", Provisioner.DeriveMcVersion(Loader.NeoForge, "20.4.237"));
        Assert.Equal("26.3", Provisioner.DeriveMcVersion(Loader.NeoForge, "26.3.0.34-beta"));
        Assert.Equal("1.21", Provisioner.DeriveMcVersion(Loader.Paper, "1.21"));
    }
}

public class PropertiesTests
{
    [Fact]
    public void PreservesCommentsOrderAndOnlineMode()
    {
        using var t = new TempDir();
        var original = "#Minecraft server properties\n#Mon\nmotd=Hi there\nonline-mode=true\n\nserver-port=25565\n";
        t.Write("server.properties", original);
        var p = Properties.Load(t.Path);
        Assert.True(p.Set("server-port", "25570"));
        Assert.False(p.Set("motd", "Hi there"));
        p.Save();
        Assert.Equal(original.Replace("25565", "25570"), File.ReadAllText(Path.Combine(t.Path, "server.properties")));
        Assert.Equal("true", Properties.Load(t.Path).Get("online-mode"));
    }

    [Fact]
    public void StartingSettingsSetPortsAndNeverTouchOnlineMode()
    {
        using var t = new TempDir();
        t.Write("server.properties", "online-mode=false\nserver-port=25565\n");
        Provisioner.ApplyStartingSettings(t.Path, false, 25570, "seed42", "creative", "hard", "My server", 12);
        var p = Properties.Load(t.Path);
        Assert.Equal("25570", p.Get("server-port")); Assert.Equal("25570", p.Get("query.port")); Assert.Equal("25580", p.Get("rcon.port"));
        Assert.Equal("creative", p.Get("gamemode")); Assert.Equal("12", p.Get("max-players")); Assert.Equal("false", p.Get("online-mode"));
        Provisioner.ApplyStartingSettings(t.Path, false, null, null, "bogus", null, "bad\nmotd", 5000);
        Assert.Equal("creative", Properties.Load(t.Path).Get("gamemode"));
    }

    [Fact]
    public void ValuesCannotInjectLines()
    {
        using var t = new TempDir(); t.Write("server.properties", "a=1\n");
        var p = Properties.Load(t.Path); p.Set("motd", "x\nonline-mode=false"); p.Save();
        Assert.Null(Properties.Load(t.Path).Get("online-mode"));
    }
}

public class PathSafetyTests
{
    [Fact]
    public void SafeFileNameRejectsTraversal()
    {
        Assert.Equal("mod.jar", FileOps.SafeFileName("mod.jar"));
        foreach (var bad in new[] { "../evil.jar", "a/b.jar", "..", "", "a\\b.jar" }) Assert.Throws<ProvisionException>(() => FileOps.SafeFileName(bad));
    }

    [Fact]
    public void ConfineStaysInsideRoot()
    {
        using var t = new TempDir();
        Assert.StartsWith(t.Path, FileOps.Confine(t.Path, "world/level.dat"));
        Assert.Throws<ProvisionException>(() => FileOps.Confine(t.Path, "../outside"));
        Assert.Throws<ProvisionException>(() => FileOps.Confine(t.Path, "a/../../outside"));
    }

    [Fact]
    public void MoveToTrashNeverDeletes()
    {
        using var t = new TempDir(); var f = t.Write("old.jar");
        var dest = FileOps.MoveToTrash(f, Path.Combine(t.Path, ".craftpanel-trash"));
        Assert.False(File.Exists(f)); Assert.True(File.Exists(dest));
    }
}

public class StoreTests
{
    [Fact]
    public void ServersRoundTripAndBrokenFileIsKeptAside()
    {
        using var t = new TempDir(); var file = Path.Combine(t.Path, "servers.json");
        var s = new ServerStore(file);
        s.Add(new ServerRecord { Name = "A", Path = "/x", ServerType = ServerType.NeoForge, RamMB = 3072 });
        var again = new ServerStore(file);
        Assert.Equal("A", again.All.Single().Name); Assert.Equal(ServerType.NeoForge, again.All.Single().ServerType);
        File.WriteAllText(file, "{ not json");
        Assert.Empty(new ServerStore(file).All);
        Assert.Single(Directory.GetFiles(t.Path, "servers.json.broken-*"));
    }

    [Fact]
    public void SettingsPersist()
    {
        using var t = new TempDir(); var file = Path.Combine(t.Path, "settings.json");
        var s = AppSettings.Load(file); s.DefaultRamMB = 8192; s.Theme = "midnight"; s.Save();
        var r = AppSettings.Load(file);
        Assert.Equal(8192u, r.DefaultRamMB); Assert.Equal("midnight", r.Theme); Assert.Equal(s.InstallId, r.InstallId); Assert.NotEmpty(r.InstallId);
    }
}
