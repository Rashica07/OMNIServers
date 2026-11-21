using CraftPanel.App.ViewModels;
using CraftPanel.Core.Adapters;
using Xunit;

namespace CraftPanel.Tests;

public class LaunchInfoTests
{
    [Fact] public void AddressUsesLanIpOrFallsBackToLocalhost()
    {
        Assert.Equal("192.168.1.24:25565", LaunchInfo.Address("192.168.1.24", 25565));
        Assert.Equal("localhost:19132", LaunchInfo.Address(null, 19132));
    }

    [Fact] public void InviteHasNameAddressAndVersion()
    {
        var t = LaunchInfo.InviteText("Survival", "10.0.0.2:25565", "1.21.4");
        Assert.Contains("\"Survival\"", t); Assert.Contains("10.0.0.2:25565", t); Assert.Contains("Minecraft 1.21.4", t);
        Assert.DoesNotContain("Game:", LaunchInfo.InviteText("A", "x:1", null));
    }

    [Fact] public void ChecklistFollowsRealStatus()
    {
        Assert.Empty(LaunchInfo.Steps(ServerStatus.Stopped));
        var starting = LaunchInfo.Steps(ServerStatus.Starting);
        Assert.True(starting[0].Done); Assert.True(starting[1].Active); Assert.False(starting[2].Done);
        Assert.All(LaunchInfo.Steps(ServerStatus.Running), s => Assert.True(s.Done));
    }
}
