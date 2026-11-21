using System.Net;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class StopAndStartupTests
{
    static async Task WaitFor(Func<bool> cond, int ms = 8000) { var end = DateTime.UtcNow.AddMilliseconds(ms); while (!cond() && DateTime.UtcNow < end) await Task.Delay(25); Assert.True(cond(), "condition not met in time"); }

    static ServerRecord Rec(TempDir t, int rconPort = 25575)
    {
        var dir = Path.Combine(t.Path, "srv"); Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "server.properties"), $"enable-rcon=true\nrcon.port={rconPort}\nrcon.password=pw\n");
        File.WriteAllText(Path.Combine(dir, "server.jar"), "x");
        return new ServerRecord { Name = "S", Path = dir, LaunchTarget = "server.jar", McVersion = "1.21", JavaPath = ProcessTests.FakeJava(t) };
    }

    [Fact]
    public async Task ShuttingDownClosesOurRconConnectionAndRefusesNewOnes()
    {
        using var t = new TempDir(); using var srv = new RconTests.FakeRcon();
        var rec = Rec(t, srv.Port);
        var rcon = new RconService();
        Assert.Equal("ran:list", await rcon.RunAsync(rec, "list"));
        Assert.Equal(1, srv.Open);                                                   // our pooled connection is open

        rcon.BeginShutdown(rec.Id);
        await WaitFor(() => srv.Open == 0);                                          // hung up, so the server's shutdown isn't held waiting for it
        var e = await Assert.ThrowsAsync<RconException>(() => rcon.RunAsync(rec, "list"));
        Assert.Contains("shutting down", e.Message);
        Assert.Equal(1, srv.Connections);                                            // and it did not quietly reconnect

        rcon.EndShutdown(rec.Id);                                                    // a restart clears it
        Assert.Equal("ran:list", await rcon.RunAsync(rec, "list"));
    }

    [Fact]
    public void TheShutdownGateExpires()
    {
        var rcon = new RconService(); var id = Guid.NewGuid();
        Assert.False(rcon.IsShuttingDown(id));
        rcon.BeginShutdown(id); Assert.True(rcon.IsShuttingDown(id));
        rcon.EndShutdown(id); Assert.False(rcon.IsShuttingDown(id));
    }

    [Fact]
    public async Task StopHangsUpRconBeforeAskingTheServerToStopAndStartClearsTheGate()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); using var srv = new RconTests.FakeRcon();
        var rec = Rec(t, srv.Port);
        var rt = new ServerRuntime(rec.Id);
        rt.Start(rec);
        await WaitFor(() => rt.Status == ServerStatus.Running);
        Assert.Equal("ran:list", await RconService.Shared.RunAsync(rec, "list"));
        Assert.Equal(1, srv.Open);

        rt.Stop();
        Assert.True(RconService.Shared.IsShuttingDown(rec.Id));
        await WaitFor(() => srv.Open == 0);
        await WaitFor(() => !rt.IsRunning);
        Assert.Equal(ServerStatus.Stopped, rt.Status);

        rt.Start(rec);                                                               // starting again lets RCON back in
        Assert.False(RconService.Shared.IsShuttingDown(rec.Id));
        await WaitFor(() => rt.Status == ServerStatus.Running);
        rt.SendCommand("stop"); await WaitFor(() => !rt.IsRunning);
    }

    [Fact]
    public void AMissingLaunchFileGetsAClearMessageNotJavasCryptic()
    {
        using var t = new TempDir(); var rec = Rec(t);
        File.Delete(Path.Combine(rec.Path, "server.jar"));
        var rt = new ServerRuntime(rec.Id);
        var e = Assert.Throws<ProvisionException>(() => rt.Start(rec));
        Assert.Contains("server.jar", e.Message); Assert.Contains("Change version", e.Message);
        Assert.False(rt.IsRunning);
    }

    [Theory]
    [InlineData("Error: Unable to access jarfile fabric-server-launch.jar", "launch file")]
    [InlineData("java.nio.file.NoSuchFileException: .fabric/server/fabric-loader-server-0.19.3-minecraft-26.2.jar", "Fabric's own files")]
    [InlineData("Error: Could not find or load main class net.fabricmc.loader.impl.launch.server.FabricServerLauncher", "launcher is damaged")]
    [InlineData("java.net.UnknownHostException: maven.fabricmc.net", "couldn't reach")]
    [InlineData("java.net.SocketTimeoutException: connect timed out", "couldn't reach")]
    [InlineData("Failed to download https://piston-data.mojang.com/v1/objects/x/server.jar", "couldn't reach")]
    public void KnownStartupFailuresGetPlainAdvice(string line, string expectedFragment)
    {
        var advice = StartupAdvice.Classify(line);
        Assert.NotNull(advice); Assert.Contains(expectedFragment, advice);
    }

    [Theory]
    [InlineData("[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type \"help\"")]
    [InlineData("[12:00:02] [Server thread/INFO]: Steve joined the game")]
    [InlineData("[12:00:03] [Server thread/WARN]: Can't keep up! Is the server overloaded?")]
    [InlineData("")]
    public void OrdinaryLinesGetNoAdvice(string line) => Assert.Null(StartupAdvice.Classify(line));

    [Fact]
    public async Task AdviceAppearsInTheConsoleOnceWhenTheServerPrintsAKnownFailure()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir(); var rec = Rec(t);
        var script = t.Write("failjava", "#!/bin/sh\necho 'Error: Unable to access jarfile fabric-server-launch.jar' >&2\necho 'Error: Unable to access jarfile fabric-server-launch.jar' >&2\nexit 1\n");
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        rec.JavaPath = script;
        var rt = new ServerRuntime(rec.Id);
        rt.Start(rec);
        await WaitFor(() => !rt.IsRunning);
        await Task.Delay(200);
        Assert.Single(rt.Lines().Where(l => l.Text.StartsWith("[OMNIServers]") && l.Text.Contains("launch file")));     // said once, not per line
    }

    sealed class Stub(Func<HttpRequestMessage, HttpResponseMessage> f) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) => Task.FromResult(f(r));
    }

    [Fact]
    public async Task HealthCheckNamesTheDownloadSitesThatAreBlocked()
    {
        using var t = new TempDir();
        var old = Http.Client; var oldData = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            Http.Client = new HttpClient(new Stub(r => r.RequestUri!.Host is "maven.fabricmc.net" or "libraries.minecraft.net" ? throw new HttpRequestException("blocked by filter") : new HttpResponseMessage(HttpStatusCode.NotFound)));
            var check = Assert.Single(await Doctor.RunAsync(Path.Combine(t.Path, "s")), c => c.Name == "Download access");
            Assert.Equal(CheckLevel.Warn, check.Level);
            Assert.Contains("maven.fabricmc.net", check.Detail); Assert.Contains("libraries.minecraft.net", check.Detail); Assert.DoesNotContain("meta.fabricmc.net", check.Detail);

            Http.Client = new HttpClient(new Stub(_ => new HttpResponseMessage(HttpStatusCode.Forbidden)));          // an answer of any kind = reachable
            Assert.Equal(CheckLevel.Ok, Assert.Single(await Doctor.RunAsync(Path.Combine(t.Path, "s")), c => c.Name == "Download access").Level);
        }
        finally { Http.Client = old; AppPaths.DataOverride = oldData; }
    }
}
