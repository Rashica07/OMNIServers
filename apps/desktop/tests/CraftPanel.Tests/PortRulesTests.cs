using CraftPanel.Core.Network;
using Xunit;

namespace CraftPanel.Tests;

public class PortRulesTests
{
    [Fact] public void BuiltInPresetsHaveExpectedPorts()
    {
        Assert.Equal([new PortRule(PortProtocol.Tcp, 25565, "Game")], PortRules.Find("minecraft-java")!.Rules);
        Assert.All(PortRules.Find("minecraft-bedrock")!.Rules, r => Assert.Equal(PortProtocol.Both, r.Protocol));   // 26.60: TCP sign-in + UDP game
        Assert.Equal(30120, PortRules.Find("fivem")!.Rules[0].Port);
        Assert.Empty(PortRules.Find("custom")!.Rules);
        Assert.Equal(PortRules.BuiltIn.Count, PortRules.BuiltIn.Select(p => p.Id).Distinct().Count());
    }

    [Fact] public void BothExpandsToTcpAndUdp() =>
        Assert.Equal([(PortProtocol.Tcp, 30120), (PortProtocol.Udp, 30120)], PortRules.Expand([new(PortProtocol.Both, 30120)]).ToList());

    [Fact] public void ValidationCatchesBadAndRepeatedPorts()
    {
        var bad = PortRules.Validate([new(PortProtocol.Tcp, 0), new(PortProtocol.Udp, 70000)]);
        Assert.Equal(2, bad.Count(i => i.Level == IssueLevel.Error));
        var dup = PortRules.Validate([new(PortProtocol.Tcp, 25565), new(PortProtocol.Both, 25565)]);
        Assert.Contains(dup, i => i.Level == IssueLevel.Error && i.Message.Contains("TCP 25565"));
        Assert.DoesNotContain(PortRules.Validate([new(PortProtocol.Tcp, 25565), new(PortProtocol.Udp, 25565)]), i => i.Level == IssueLevel.Error);
    }

    [Fact] public void AdminPortsGetASecurityWarning()
    {
        var w = PortRules.Validate([new(PortProtocol.Tcp, 25575, "RCON")]);
        Assert.Single(w); Assert.Equal(IssueLevel.Warning, w[0].Level); Assert.Contains("RCON", w[0].Message);
        Assert.Empty(PortRules.Validate([new(PortProtocol.Tcp, 25565)]));
    }

    [Fact] public void ConflictsFlagOtherServersAndBusyPorts()
    {
        var rules = new List<PortRule> { new(PortProtocol.Both, 30120), new(PortProtocol.Tcp, 25565) };
        var c = PortRules.FindConflicts(rules, new HashSet<int> { 25565 }, (proto, port) => !(proto == PortProtocol.Udp && port == 30120));
        Assert.Contains(c, i => i.Message.Contains("Another OMNIServers server") && i.Message.Contains("25565"));
        Assert.Contains(c, i => i.Message.Contains("UDP 30120") && i.Message.Contains("another program"));
        Assert.Equal(2, c.Count);
    }

    [Fact] public void CommandsAreGeneratedPerProtocol()
    {
        var rules = new List<PortRule> { new(PortProtocol.Both, 30120) };
        Assert.Equal(["sudo ufw allow 30120/tcp", "sudo ufw allow 30120/udp"], PortRules.UfwCommands(rules).ToList());
        var n = PortRules.NetshCommands("FiveM", rules).ToList();
        Assert.Equal(2, n.Count); Assert.Contains("protocol=UDP localport=30120", n[1]);
    }

    [Fact] public void CustomPresetsRoundTripAndBuiltInsAreNotSaved()
    {
        var f = Path.Combine(Path.GetTempPath(), "omni-presets-" + Guid.NewGuid() + ".json");
        try
        {
            Assert.Empty(PortRules.LoadSaved(f));
            PortRules.Save(f, [.. PortRules.BuiltIn, new PortPreset("mine", "My lobby", "", [new(PortProtocol.Udp, 4000, "Voice")], false)]);
            var back = PortRules.LoadSaved(f);
            Assert.Single(back); Assert.Equal("My lobby", back[0].Name); Assert.Equal(PortProtocol.Udp, back[0].Rules[0].Protocol); Assert.False(back[0].BuiltIn);
        }
        finally { File.Delete(f); }
    }

    [Fact] public void BrokenPresetFileGivesEmptyList()
    {
        var f = Path.Combine(Path.GetTempPath(), "omni-presets-" + Guid.NewGuid() + ".json");
        File.WriteAllText(f, "{not json"); try { Assert.Empty(PortRules.LoadSaved(f)); } finally { File.Delete(f); }
    }
}
