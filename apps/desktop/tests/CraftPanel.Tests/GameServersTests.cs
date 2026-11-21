using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using Xunit;

namespace CraftPanel.Tests;

public class GameServersTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "cp-game-" + Guid.NewGuid().ToString("N"));
    public GameServersTests() => Directory.CreateDirectory(dir);
    public void Dispose() { try { Directory.Delete(dir, true); } catch { } }

    [Fact] public void DetectsFiveMByExe() { File.WriteAllText(Path.Combine(dir, "FXServer.exe"), ""); Assert.Equal(ServerType.FiveM, GameServers.Inspect(dir)!.Type); }
    [Fact] public void DetectsTerraria() { File.WriteAllText(Path.Combine(dir, "TerrariaServer.exe"), ""); var d = GameServers.Inspect(dir)!; Assert.Equal(ServerType.Terraria, d.Type); Assert.Equal("TerrariaServer.exe", d.LaunchTarget); }
    [Fact] public void LoneRunShIsNotFiveM() { File.WriteAllText(Path.Combine(dir, "run.sh"), ""); Assert.Null(GameServers.Inspect(dir)); }
    [Fact] public void RunShWithFiveMFilesIsFiveM() { File.WriteAllText(Path.Combine(dir, "run.sh"), ""); Directory.CreateDirectory(Path.Combine(dir, "alpine")); Assert.Equal(ServerType.FiveM, GameServers.Inspect(dir)!.Type); }
    [Fact] public async Task DetectorFindsGameServer() { File.WriteAllText(Path.Combine(dir, "FXServer.exe"), ""); var r = await ServerDetector.DetectAsync(dir); Assert.True(r.Detected); Assert.Equal(ServerType.FiveM, r.ServerType); }

    [Fact] public void FixCreatesFiveMConfigAndAsksForKey()
    {
        Directory.CreateDirectory(Path.Combine(dir, "resources", "chat"));
        var r = GameServers.Fix(ServerType.FiveM, dir, "My \"City\"");
        var cfg = File.ReadAllText(Path.Combine(dir, "server.cfg"));
        Assert.Contains("endpoint_add_udp", cfg); Assert.Contains("ensure chat", cfg); Assert.DoesNotContain("ensure spawnmanager", cfg);
        Assert.Contains("sv_hostname \"My City\"", cfg);
        Assert.Contains(r.ToDo, t => t.Contains("licence key"));
    }
    [Fact] public void FixKeepsRealKeyAndIsIdempotent()
    {
        Directory.CreateDirectory(Path.Combine(dir, "resources"));
        File.WriteAllText(Path.Combine(dir, "server.cfg"), "sv_licenseKeyToken \"abcdef1234567890\"\nendpoint_add_tcp \"0.0.0.0:30120\"\n");
        var r1 = GameServers.Fix(ServerType.FiveM, dir, "x");
        Assert.DoesNotContain(r1.ToDo, t => t.Contains("licence key"));
        var text = File.ReadAllText(Path.Combine(dir, "server.cfg"));
        Assert.Contains("endpoint_add_udp", text);
        var r2 = GameServers.Fix(ServerType.FiveM, dir, "x");
        Assert.Empty(r2.Done); Assert.Equal(text, File.ReadAllText(Path.Combine(dir, "server.cfg")));
    }
    [Fact] public void FixWithoutResourcesTellsWhat() => Assert.Contains(GameServers.Fix(ServerType.FiveM, dir, "x").ToDo, t => t.Contains("resources"));
    [Fact] public void FixCreatesTerrariaConfigWithAutocreate()
    {
        var r = GameServers.Fix(ServerType.Terraria, dir, "Cool World!");
        var cfg = File.ReadAllText(Path.Combine(dir, "serverconfig.txt"));
        Assert.Contains("autocreate=2", cfg); Assert.Contains("worldname=CoolWorld", cfg); Assert.Contains("port=7777", cfg);
        Assert.NotEmpty(r.Done); Assert.Empty(r.ToDo);
    }
    [Fact] public void TerrariaUsesExistingWorld()
    {
        Directory.CreateDirectory(Path.Combine(dir, "Worlds")); File.WriteAllText(Path.Combine(dir, "Worlds", "Home.wld"), "");
        GameServers.Fix(ServerType.Terraria, dir, "x");
        var cfg = File.ReadAllText(Path.Combine(dir, "serverconfig.txt"));
        Assert.Contains("Home.wld", cfg); Assert.DoesNotContain("autocreate", cfg);
    }
    [Fact] public void DetectsMacTerrariaAppBundle()
    {
        var d = Path.Combine(dir, "Terraria Server.app", "Contents", "MacOS"); Directory.CreateDirectory(d); File.WriteAllText(Path.Combine(d, "TerrariaServer"), "");
        var r = GameServers.Inspect(dir)!; Assert.Equal(ServerType.Terraria, r.Type); Assert.EndsWith("TerrariaServer", r.LaunchTarget);
    }
    [Fact] public void TerrariaConfigPathIsAbsolute()
    {
        var s = GameServers.StartCommand(new ServerConfig(dir, "TerrariaServer.exe", null, 0, ServerType.Terraria, null));
        Assert.Equal(Path.Combine(dir, "serverconfig.txt"), s.Args[1]);
    }
    [Fact] public void LaunchAndStopCommands()
    {
        var c = new ServerConfig(dir, "FXServer.exe", null, 0, ServerType.FiveM, null);
        var s = GameServers.StartCommand(c); Assert.Equal(["+exec", "server.cfg"], s.Args); Assert.Equal(dir, s.WorkingDirectory);
        Assert.Equal("quit", GameServers.StopCommand(ServerType.FiveM)); Assert.Equal("exit", GameServers.StopCommand(ServerType.Terraria)); Assert.Equal("stop", GameServers.StopCommand(ServerType.Paper));
    }
    [Fact] public void StatusParsing()
    {
        Assert.Equal(ServerStatus.Running, GameServers.ParseStatus(ServerType.Terraria, "Server started"));
        Assert.Equal(ServerStatus.Running, GameServers.ParseStatus(ServerType.FiveM, "Server thread is now running"));
        Assert.Equal(ServerStatus.Unknown, GameServers.ParseStatus(ServerType.FiveM, "hello"));
    }
    [Fact] public void BannerSaysMadeWithOmniservers() => Assert.Contains(GameServers.Banner("FiveM"), l => l.Contains("MADE WITH OMNISERVERS"));
    [Fact] public void TypeHelpers()
    {
        Assert.True(ServerType.FiveM.IsGame()); Assert.False(ServerType.FiveM.UsesJava()); Assert.True(ServerType.Paper.UsesJava()); Assert.False(ServerType.Bedrock.UsesJava());
    }
}
