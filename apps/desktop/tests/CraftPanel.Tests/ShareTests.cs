using System.Text.Json;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Runtime;
using CraftPanel.Core.Sharing;
using Xunit;

namespace CraftPanel.Tests;

public class ShareTests : IDisposable
{
    long _now = 1_800_000_000;
    readonly Func<long> _oldNow = ShareLease.Now;
    readonly TimeSpan _oldBeat = ShareLease.HeartbeatEvery;
    public ShareTests() => ShareLease.Now = () => _now;
    public void Dispose() { ShareLease.Now = _oldNow; ShareLease.HeartbeatEvery = _oldBeat; }

    static string Folder(TempDir t, string name = "srv") { var d = Path.Combine(t.Path, name); Directory.CreateDirectory(d); return d; }

    [Fact]
    public void ANonSharedFolderNeedsNoClaimAndWritesNothing()
    {
        using var t = new TempDir(); var d = Folder(t);
        Assert.False(ShareLease.IsShared(d));
        var l = ShareLease.Claim(d, "PC-A", false);
        Assert.Equal("PC-A", l.Holder);
        Assert.False(File.Exists(Path.Combine(d, ShareLease.LeaseFile)));
        Assert.False(ShareLease.View(d, "PC-A").Shared);
    }

    [Fact]
    public void OnePcAtATimeAndTheClaimExpiresAndCanBeForced()
    {
        using var t = new TempDir(); var d = Folder(t);
        var info = ShareLease.CreateShare(d, "Our SMP");
        Assert.Matches("^[2-9BCDFGHJKMNPQRSTVWXZ]{4}-[2-9BCDFGHJKMNPQRSTVWXZ]{4}$", info.Code);
        Assert.Throws<ProvisionException>(() => ShareLease.CreateShare(d, "again"));

        ShareLease.Claim(d, "PC-A", false);
        var held = Assert.Throws<LeaseHeldException>(() => ShareLease.Claim(d, "PC-B", false));
        Assert.Equal(Environment.MachineName, held.Holder); Assert.Contains("In use on", held.Message);
        var vB = ShareLease.View(d, "PC-B");
        Assert.True(vB.Locked); Assert.False(vB.HeldByUs); Assert.Equal(120, vB.ExpiresIn);
        Assert.True(ShareLease.View(d, "PC-A").HeldByUs);

        ShareLease.Claim(d, "PC-A", false);                        // the holder may claim again (a restart)
        _now += 121;                                                 // PC-A's claim runs out (it was switched off)
        Assert.False(ShareLease.View(d, "PC-B").Locked);
        Assert.Equal("PC-B", ShareLease.Claim(d, "PC-B", false).Holder);

        Assert.Throws<LeaseHeldException>(() => ShareLease.Claim(d, "PC-A", false));
        Assert.Equal("PC-A", ShareLease.Claim(d, "PC-A", force: true).Holder);          // "start anyway, that PC is off"
    }

    [Fact]
    public void HeartbeatKeepsOurClaimAliveButNeverStealsOrRevivesOne()
    {
        using var t = new TempDir(); var d = Folder(t);
        ShareLease.CreateShare(d, "S"); ShareLease.Claim(d, "PC-A", false);
        _now += 100; ShareLease.Heartbeat(d, "PC-A");
        Assert.Equal(_now + 120, ShareLease.ReadLease(d)!.ExpiresAt);
        var before = ShareLease.ReadLease(d)!.ExpiresAt;
        ShareLease.Heartbeat(d, "PC-B");                              // someone else's heartbeat does nothing
        Assert.Equal(before, ShareLease.ReadLease(d)!.ExpiresAt);
        ShareLease.Release(d, "PC-B"); Assert.NotNull(ShareLease.ReadLease(d));       // …and can't release it either
        ShareLease.Release(d, "PC-A"); Assert.Null(ShareLease.ReadLease(d));
        ShareLease.Heartbeat(d, "PC-A"); Assert.Null(ShareLease.ReadLease(d));         // no claim → a heartbeat doesn't create one
    }

    [Fact]
    public void UnsharingIsRefusedWhileAnotherPcRunsItAndOtherwiseCleansUp()
    {
        using var t = new TempDir(); var d = Folder(t);
        ShareLease.CreateShare(d, "S"); ShareLease.Claim(d, "PC-A", false);
        Assert.Throws<ProvisionException>(() => ShareLease.Unshare(d, "PC-B"));
        Assert.True(ShareLease.IsShared(d));
        ShareLease.Unshare(d, "PC-A");
        Assert.False(ShareLease.IsShared(d)); Assert.Null(ShareLease.ReadLease(d));
    }

    [Fact]
    public void FilesUseTheExactFieldNamesTheMacAppReadsAndWrites()
    {
        using var t = new TempDir(); var d = Folder(t);
        // exactly what the Swift app writes (sorted keys, pretty-printed)
        File.WriteAllText(Path.Combine(d, ShareLease.ShareFile), "{\n  \"code\" : \"ABCD-2345\",\n  \"created_by\" : \"Kiqa's MacBook\",\n  \"name\" : \"Mac server\"\n}");
        File.WriteAllText(Path.Combine(d, ShareLease.LeaseFile), "{\n  \"claimed_at\" : 1799999000,\n  \"expires_at\" : " + (_now + 60) + ",\n  \"holder\" : \"MAC-ID\",\n  \"hostname\" : \"Kiqa's MacBook\"\n}");
        var v = ShareLease.View(d, "WIN-ID");
        Assert.True(v.Shared && v.Locked && !v.HeldByUs); Assert.Equal("ABCD-2345", v.Code); Assert.Equal("Kiqa's MacBook", v.HolderName);
        var ex = Assert.Throws<LeaseHeldException>(() => ShareLease.Claim(d, "WIN-ID", false));
        Assert.Equal("Kiqa's MacBook", ex.Holder);

        // and what we write has the same keys
        _now += 100; ShareLease.Claim(d, "WIN-ID", false);
        var keys = JsonDocument.Parse(File.ReadAllText(Path.Combine(d, ShareLease.LeaseFile))).RootElement.EnumerateObject().Select(p => p.Name).Order().ToArray();
        Assert.Equal(["claimed_at", "expires_at", "holder", "hostname"], keys);
        var share = ShareLease.CreateShare(Folder(t, "other"), "N");
        var skeys = JsonDocument.Parse(File.ReadAllText(Path.Combine(t.Path, "other", ShareLease.ShareFile))).RootElement.EnumerateObject().Select(p => p.Name).Order().ToArray();
        Assert.Equal(["code", "created_by", "name"], skeys);
    }

    [Fact]
    public void DamagedFilesAreTreatedAsNotThere()
    {
        using var t = new TempDir(); var d = Folder(t);
        File.WriteAllText(Path.Combine(d, ShareLease.ShareFile), "{{ nope");
        Assert.False(ShareLease.IsShared(d));
        ShareLease.CreateShare(Folder(t, "ok"), "S");
        File.WriteAllText(Path.Combine(t.Path, "ok", ShareLease.LeaseFile), "garbage");
        Assert.Null(ShareLease.ReadLease(Path.Combine(t.Path, "ok")));
        Assert.Equal("PC-A", ShareLease.Claim(Path.Combine(t.Path, "ok"), "PC-A", false).Holder);     // an unreadable claim doesn't lock anyone out
    }

    [Fact]
    public void DeviceIdIsCreatedOnceAndKept()
    {
        using var t = new TempDir();
        var a = ShareLease.DeviceId(t.Path); var b = ShareLease.DeviceId(t.Path);
        Assert.Equal(a, b); Assert.True(a.Length >= 32);
        Assert.NotEqual(a, ShareLease.DeviceId(Folder(t, "other-config")));
    }

    [Fact]
    public async Task ARunningSharedServerHoldsTheClaimKeepsItAndReleasesItWhenItStops()
    {
        if (OperatingSystem.IsWindows()) return;
        using var t = new TempDir();
        var old = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            var dir = Folder(t, "shared-server"); File.WriteAllText(Path.Combine(dir, "server.properties"), "a=1\n");
            ShareLease.CreateShare(dir, "S");
            var rec = new ServerRecord { Name = "S", Path = dir, LaunchTarget = "server.jar", McVersion = "1.21", JavaPath = ProcessTests.FakeJava(t) };
            Directory.CreateDirectory(rec.Path); File.WriteAllText(Path.Combine(rec.Path, "server.jar"), "x");   // the launch file must exist
            ShareLease.HeartbeatEvery = TimeSpan.FromMilliseconds(80);
            var rt = new ServerRuntime(Guid.NewGuid());

            // another PC is running it: refused, with who and for how long
            ShareLease.Claim(dir, "OTHER-PC", false);
            var held = Assert.Throws<LeaseHeldException>(() => rt.Start(rec));
            Assert.False(rt.IsRunning);
            // …unless the user confirms that PC is off
            rt.Start(rec, forceShareLease: true);
            for (var i = 0; i < 400 && rt.Status != ServerStatus.Running; i++) await Task.Delay(25);
            Assert.Equal(ShareLease.ThisDeviceId, ShareLease.ReadLease(dir)!.Holder);
            var first = ShareLease.ReadLease(dir)!.ExpiresAt;
            _now += 30;
            for (var i = 0; i < 100 && ShareLease.ReadLease(dir)!.ExpiresAt == first; i++) await Task.Delay(30);
            Assert.True(ShareLease.ReadLease(dir)!.ExpiresAt > first);              // the heartbeat extended it

            rt.SendCommand("stop");
            for (var i = 0; i < 400 && rt.IsRunning; i++) await Task.Delay(25);
            for (var i = 0; i < 100 && ShareLease.ReadLease(dir) is not null; i++) await Task.Delay(25);
            Assert.Null(ShareLease.ReadLease(dir));                                 // handed back for the other PC
        }
        finally { AppPaths.DataOverride = old; }
    }

    [Fact]
    public void LocationNoteOnlyAppearsForAFolderOnThisPcsOwnDisk()
    {
        using var t = new TempDir();
        if (!OperatingSystem.IsWindows()) return;                      // drive types are a Windows idea
        Assert.NotNull(ShareLease.LocationNote(t.Path));
        Assert.Null(ShareLease.LocationNote(@"C:\Users\x\OneDrive\Servers\one"));
        Assert.Null(ShareLease.LocationNote(@"\\nas\games\mc"));
    }

    [Fact]
    public void LanRequestIsSpecificAndDoesNotAskForAdminOrInternetForwarding()
    {
        var request = LanTools.NetworkAccessRequest(25565);
        Assert.Contains("TCP port 25565", request);
        Assert.Contains("client/AP isolation", request);
        Assert.Contains("do not need administrator access or an internet port forward", request);
        Assert.Contains("UDP port 19132", LanTools.NetworkAccessRequest(19132, udp: true));
    }
}
