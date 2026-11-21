using CraftPanel.Core;
using Xunit;

namespace CraftPanel.Tests;

public class QuickServerTests
{
    static readonly VersionInfo[] Versions = [new("26.1-pre2", "snapshot"), new("1.21.8", "release"), new("1.21.7", "release")];

    [Fact] public void PicksTheNewestStableRelease() => Assert.Equal("1.21.8", QuickServer.PickVersion(Versions));
    [Fact] public void NoReleaseMeansNoPlan() => Assert.Null(QuickServer.Plan([new("x", "snapshot")], new SystemMemory(16384, 8000, null, "", 8), Path.GetTempPath(), []));

    [Fact] public void RamFitsTheMachine()
    {
        var big = QuickServer.Plan(Versions, new SystemMemory(32768, 20000, null, "", 12), Path.GetTempPath(), [])!;
        Assert.Equal(3072, big.RamMB);                               // 2 GB base + 5 players, rounded up to 512
        var small = QuickServer.Plan(Versions, new SystemMemory(4096, 1500, null, "", 2), Path.GetTempPath(), [])!;
        Assert.Equal(2048, small.RamMB);                             // capped at the safe limit of a 4 GB PC
    }

    [Fact] public void NamesAndFoldersNeverClash()
    {
        var dir = Path.Combine(Path.GetTempPath(), "omni-qs-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(dir, "My-Server")); File.WriteAllText(Path.Combine(dir, "My-Server", "x"), "");
        try
        {
            Assert.Equal("My Server 2", QuickServer.PickName(dir, []).Name);
            Assert.Equal("My Server 3", QuickServer.PickName(dir, ["My Server 2"]).Name);
            Assert.Equal("My Server", QuickServer.PickName(Path.Combine(dir, "other"), []).Name);
        }
        finally { Directory.Delete(dir, true); }
    }
}
