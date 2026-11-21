using CraftPanel.Core;
using CraftPanel.Core.Network;
using Xunit;

namespace CraftPanel.Tests;

public class JoinLinkTests
{
    [Fact] public void BedrockGetsALinkThatAddsTheServer()
    {
        var p = JoinLink.Plan(ServerType.Bedrock, "Our world", "192.168.1.9:19132");
        Assert.True(p.Bedrock);
        Assert.Equal("minecraft://?addExternalServer=Our%20world|192.168.1.9:19132", p.Uri);
    }

    [Fact] public void JavaHasNoLinkSoItCopiesTheAddress()
    {
        var p = JoinLink.Plan(ServerType.Paper, "SMP", "192.168.1.9:25565");
        Assert.False(p.Bedrock); Assert.Null(p.Uri); Assert.Equal("192.168.1.9:25565", p.Address);
    }

    [Fact] public void KnowsWhereTheLauncherLives() => Assert.NotEmpty(JoinLink.JavaLauncherCandidates());
}
