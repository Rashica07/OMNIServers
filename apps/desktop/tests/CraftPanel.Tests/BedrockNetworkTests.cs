using System.Text.Json.Nodes;
using CraftPanel.Core;
using CraftPanel.Core.Network;
using Xunit;

namespace CraftPanel.Tests;

/// <summary>Bedrock 26.60 (NetherNet): TCP sign-in + UDP game. Pure rules; nothing here needs a real client.</summary>
public class BedrockNetworkTests
{
    // ---- Geyser launch flag ----
    [Fact] public void GeyserGetsTheNetherNetFlag() =>
        Assert.Equal("-DgeyserTransport=nethernet", BedrockNetwork.WithGeyserFlags(null, true, null));

    [Fact] public void TheFlagIsAppendedToUserArgs() =>
        Assert.Equal("-Xmx4G -DgeyserTransport=nethernet", BedrockNetwork.WithGeyserFlags("  -Xmx4G ", true, "raknet"));

    [Fact] public void NoGeyserMeansArgsAreUntouched()
    {
        Assert.Null(BedrockNetwork.WithGeyserFlags(null, false, null));
        Assert.Equal("-Xmx2G", BedrockNetwork.WithGeyserFlags("-Xmx2G", false, null));
    }

    [Theory] [InlineData("both")] [InlineData("NetherNet")] [InlineData(" both ")]
    public void ATransportChosenInGeyserConfigIsRespected(string cfg) =>
        Assert.Equal("-Xmx1G", BedrockNetwork.WithGeyserFlags("-Xmx1G", true, cfg));

    [Fact] public void AUserFlagWins() =>
        Assert.Equal("-DgeyserTransport=both", BedrockNetwork.WithGeyserFlags("-DgeyserTransport=both", true, null));

    // ---- Geyser build tracking ----
    [Theory] [InlineData(true, null, true)] [InlineData(true, 1272, true)] [InlineData(true, 1273, false)] [InlineData(true, 2000, false)] [InlineData(false, null, false)] [InlineData(false, 5, false)]
    public void OldOrUnknownGeyserNeedsAnUpdate(bool installed, int? build, bool expected) =>
        Assert.Equal(expected, BedrockNetwork.GeyserNeedsUpdate(installed, build));

    [Fact] public void ParsesBuildJson()
    {
        Assert.Equal((1273, "2.12.1"), BedrockNetwork.ParseGeyserBuild(JsonNode.Parse("""{"build":1273,"version":"2.12.1"}""")));
        Assert.Null(BedrockNetwork.ParseGeyserBuild(JsonNode.Parse("""{"build":"x","version":"2.12.1"}""")));
        Assert.Null(BedrockNetwork.ParseGeyserBuild(JsonNode.Parse("""{"version":"2.12.1"}""")));
        Assert.Null(BedrockNetwork.ParseGeyserBuild(null));
    }

    // ---- server-udp-ports ----
    [Theory]
    [InlineData("19132", 19132, 19132)]
    [InlineData(" 19200-19210 ", 19200, 19210)]
    [InlineData("19132:19133", 19133, 19133)]
    [InlineData("1.2.3.4:19132:19132", 19132, 19132)]
    [InlineData("1.2.3.4:19132:19000-19005", 19000, 19005)]
    [InlineData("[2001:db8::1]:19132:19132", 19132, 19132)]
    public void ParsesUdpPortsInEveryForm(string v, int first, int last)
    {
        var r = BedrockNetwork.ParseUdpPorts(v);
        Assert.Equal(new UdpPorts(first, last), r);
    }

    [Theory] [InlineData(null)] [InlineData("")] [InlineData("  ")] [InlineData("abc")] [InlineData("0")] [InlineData("70000")] [InlineData("19210-19200")] [InlineData("[::1")] [InlineData("1-x")]
    public void UnreadableUdpPortsGiveNull(string? v) => Assert.Null(BedrockNetwork.ParseUdpPorts(v));

    [Fact] public void RangeCount() => Assert.Equal(11, new UdpPorts(19200, 19210).Count);

    [Fact] public void UdpPortsValueUsesThePublicIpWhenItIsOne()
    {
        Assert.Equal("19132", BedrockNetwork.UdpPortsValue(19132, null));
        Assert.Equal("19132", BedrockNetwork.UdpPortsValue(19132, "not an ip"));
        Assert.Equal("203.0.113.9:19132:19132", BedrockNetwork.UdpPortsValue(19132, " 203.0.113.9 "));
        Assert.Equal("[2001:db8::1]:19132:19132", BedrockNetwork.UdpPortsValue(19132, "2001:db8::1"));
    }

    [Fact] public void UdpPortsValueRoundTrips() =>
        Assert.Equal(new UdpPorts(19140, 19140), BedrockNetwork.ParseUdpPorts(BedrockNetwork.UdpPortsValue(19140, "198.51.100.7")));

    // ---- rules ----
    [Fact] public void GeyserNeedsOnePortOnBothProtocols() =>
        Assert.Equal([new PortRule(PortProtocol.Both, 19133, "Bedrock sign-in (TCP) + game (UDP)")], BedrockNetwork.GeyserRules(19133));

    [Fact] public void BdsWithOneSharedPortIsOneBothRow()
    {
        var r = BedrockNetwork.BdsRules(19132, "19132");
        Assert.Single(r); Assert.Equal(PortProtocol.Both, r[0].Protocol); Assert.Equal(19132, r[0].Port);
    }

    [Fact] public void BdsWithDifferentUdpPortKeepsTwoRows()
    {
        var r = BedrockNetwork.BdsRules(19132, "19140");
        Assert.Equal([(PortProtocol.Tcp, 19132), (PortProtocol.Udp, 19140)], r.Select(x => (x.Protocol, x.Port)).ToList());
    }

    [Fact] public void BdsWithUnsetUdpPortsAssumesTheServerPortAndSaysHowToPinIt()
    {
        var r = BedrockNetwork.BdsRules(19132, null);
        Assert.Single(r);
        var two = BedrockNetwork.BdsRules(19132, "garbage");
        Assert.Equal(r, two);
    }

    [Fact] public void BdsRangeMentionsTheRestAreNotAdded()
    {
        var r = BedrockNetwork.BdsRules(19132, "19200-19210");
        Assert.Equal(2, r.Count);
        Assert.Contains("19200-19210", r[1].Label);
        Assert.Equal(19200, r[1].Port);
    }

    [Fact] public void DescribeReadsLikeAPerson()
    {
        Assert.Equal("TCP 19132 and UDP 19132", BedrockNetwork.Describe(BedrockNetwork.GeyserRules(19132)));
        Assert.Equal("TCP 25565, TCP 19132 and UDP 19132", BedrockNetwork.Describe([new(PortProtocol.Tcp, 25565), .. BedrockNetwork.GeyserRules(19132)]));
        Assert.Equal("TCP 25565", BedrockNetwork.Describe([new(PortProtocol.Tcp, 25565)]));
        Assert.Equal("no ports", BedrockNetwork.Describe([]));
    }

    // ---- BDS defaults ----
    [Fact] public void NewBdsGetsOneUdpPortAndAnOpenAllowList()
    {
        using var t = new TempDir();
        t.Write("server.properties", "server-port=19132\nallow-list=true\nonline-mode=true\nserver-udp-ports=\n");
        var p = Properties.Load(t.Path);
        BedrockNetwork.ApplyNewBdsDefaults(p, 19140);
        p.Save();
        var q = Properties.Load(t.Path);
        Assert.Equal("19140", q.Get("server-udp-ports")); Assert.Equal("false", q.Get("allow-list"));
        Assert.Equal("true", q.Get("online-mode"));     // every player is still Xbox-signed-in
    }

    [Fact] public void ProvisioningABedrockServerAppliesTheNetherNetDefaults()
    {
        using var t = new TempDir();
        t.Write("server.properties", "server-port=19132\nallow-list=true\nonline-mode=true\n");
        Provisioner.ApplyStartingSettings(t.Path, true, 19150, null, null, null, "Friends", 8);
        var p = Properties.Load(t.Path);
        Assert.Equal("19150", p.Get("server-port")); Assert.Equal("19150", p.Get("server-udp-ports")); Assert.Equal("false", p.Get("allow-list"));
        Assert.Equal("Friends", p.Get("server-name"));
    }

    [Fact] public void ProvisioningAJavaServerDoesNotTouchBedrockKeys()
    {
        using var t = new TempDir();
        t.Write("server.properties", "server-port=25565\n");
        Provisioner.ApplyStartingSettings(t.Path, false, 25570, null, null, null, null, null);
        Assert.Null(Properties.Load(t.Path).Get("server-udp-ports"));
        Assert.Null(Properties.Load(t.Path).Get("allow-list"));
    }

    [Theory] [InlineData("1.21.80.3", true)] [InlineData("1.26.49.0", true)] [InlineData("1.26.50", false)] [InlineData("1.26.63.1", false)] [InlineData(null, false)] [InlineData("", false)] [InlineData("preview", false)]
    public void OldBdsIsFlagged(string? v, bool legacy) => Assert.Equal(legacy, BedrockNetwork.IsLegacyBds(v));

    // ---- addresses ----
    [Theory]
    [InlineData("203.0.113.9", "192.168.1.5", 19132, "203.0.113.9:19132")]
    [InlineData("203.0.113.9:25565", "192.168.1.5", 19133, "203.0.113.9:19133")]     // the Java port is replaced by Geyser's
    [InlineData("", "192.168.1.5", 19132, "192.168.1.5:19132")]
    [InlineData(null, " 192.168.1.5 ", 19132, "192.168.1.5:19132")]
    [InlineData(null, null, 19132, "")]
    [InlineData("friends.example.com", null, 19132, "friends.example.com:19132")]
    public void BedrockAddressNeverUsesTheJavaPort(string? pub, string? lan, int port, string expected) =>
        Assert.Equal(expected, BedrockNetwork.BedrockAddress(pub, lan, port));

    [Fact] public void BedrockAddressNeverIsTheTunnel() =>
        Assert.DoesNotContain("bore", BedrockNetwork.BedrockAddress(null, "192.168.1.5", 19132));

    // ---- default rules for a server dir ----
    [Fact] public void BedrockServerDirGivesTheBedrockPreset()
    {
        using var t = new TempDir();
        t.Write("server.properties", "server-port=19140\nserver-udp-ports=19140\n");
        var d = BedrockNetwork.DefaultRules(ServerType.Bedrock, t.Path);
        Assert.NotNull(d);
        Assert.Equal("minecraft-bedrock", d!.Value.PresetId);
        Assert.Equal([new PortRule(PortProtocol.Both, 19140, "Sign-in (TCP) + game (UDP)")], d.Value.Rules);
    }

    [Fact] public void JavaServerWithGeyserGetsJavaPlusGeyserRules()
    {
        using var t = new TempDir();
        t.Write("server.properties", "server-port=25570\n");
        t.Write("plugins/Geyser-Spigot.jar");
        t.Write("plugins/Geyser-Spigot/config.yml", "bedrock:\n  port: 19133\n");
        var d = BedrockNetwork.DefaultRules(ServerType.Paper, t.Path)!.Value;
        Assert.Equal("minecraft-geyser", d.PresetId);
        Assert.Equal([(PortProtocol.Tcp, 25570), (PortProtocol.Both, 19133)], d.Rules.Select(r => (r.Protocol, r.Port)).ToList());
    }

    [Fact] public void JavaServerWithoutGeyserHasNoBedrockPreset()
    {
        using var t = new TempDir();
        Assert.Null(BedrockNetwork.DefaultRules(ServerType.Paper, t.Path));
    }

    // ---- presets ----
    [Fact] public void BedrockPresetIsTcpPlusUdpAndGeyserPresetExists()
    {
        var bedrock = PortRules.Find("minecraft-bedrock")!.Rules;
        Assert.Equal([PortProtocol.Both], bedrock.Select(r => r.Protocol).ToList());
        var expanded = PortRules.Expand(bedrock).ToList();
        Assert.Contains((PortProtocol.Tcp, 19132), expanded); Assert.Contains((PortProtocol.Udp, 19132), expanded);
        var g = PortRules.Find("minecraft-geyser")!;
        Assert.Equal([(PortProtocol.Tcp, 25565), (PortProtocol.Both, 19132)], g.Rules.Select(r => (r.Protocol, r.Port)).ToList());
    }

    // ---- firewall rule set (pure part) ----
    [Fact] public void FirewallRuleSetSplitsBothIntoTcpAndUdp()
    {
        var set = Firewall.RuleSet("OMNI Test", [new(PortProtocol.Both, 19132), new(PortProtocol.Tcp, 25565)]);
        Assert.Equal(3, set.Count);
        Assert.Contains(set, r => r.Port == 19132 && !r.Udp); Assert.Contains(set, r => r.Port == 19132 && r.Udp); Assert.Contains(set, r => r.Port == 25565 && !r.Udp);
        Assert.Equal(set.Count, set.Select(r => r.Name).Distinct().Count());        // every rule has its own name
    }

    [Fact] public void NetshArgsPickTheProtocolAndStripQuotes()
    {
        Assert.Contains("protocol=UDP localport=19132", Firewall.NetshArgs("A", 19132, true));
        Assert.Contains("protocol=TCP localport=19132", Firewall.NetshArgs("A", 19132, false));
        Assert.DoesNotContain("\"\"", Firewall.NetshArgs("x\"y", 1, false));
        var (tcp, udp) = Firewall.BothRuleNames("Base");
        Assert.NotEqual(tcp, udp);
    }

    // ---- Geyser config reading ----
    [Fact] public void ReadsOnlyTheBedrockSectionsOwnKeys()
    {
        const string yml = "java:\n  port: 25565\n  transport: raknet\nbedrock:\n  address: 0.0.0.0\n  port: 19133\n  transport: both\n  clone-remote-port: true\n  signaling:\n    mode: builtin\n    port: 9999\n  \nmotd:\n  port: 1\n";
        var (port, transport, clone) = CrossplayManager.ReadBedrockSection(yml.Split('\n'));
        Assert.Equal(19133, port); Assert.Equal("both", transport); Assert.True(clone);
    }

    [Fact] public void NestedBlocksDoNotLeakIntoTheBedrockValues()
    {
        var (port, transport, clone) = CrossplayManager.ReadBedrockSection("bedrock:\n  signaling:\n    port: 9999\n    transport: x\n    clone-remote-port: true\n".Split('\n'));
        Assert.Null(port); Assert.Null(transport); Assert.False(clone);
    }

    [Fact] public void MissingConfigMeansDefaults()
    {
        var (port, transport, clone) = CrossplayManager.ReadBedrockSection([]);
        Assert.Null(port); Assert.Null(transport); Assert.False(clone);
        using var t = new TempDir();
        Assert.Equal(19132, CrossplayManager.BedrockPort(t.Path));
        Assert.Null(CrossplayManager.ConfigTransport(t.Path));
    }
}

public class GeyserNetherNetTests : IDisposable
{
    sealed class Stub(Func<HttpRequestMessage, HttpResponseMessage> f) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) => Task.FromResult(f(r));
    }

    readonly HttpClient _old = Http.Client;
    public void Dispose() => Http.Client = _old;

    static readonly byte[] Jar = Enumerable.Range(0, 150_000).Select(i => (byte)(i * 11)).ToArray();

    static void Serve(int build, bool downloadFails = false) =>
        Http.Client = new HttpClient(new Stub(r =>
        {
            var p = r.RequestUri!.AbsolutePath;
            if (r.RequestUri.Host != "download.geysermc.org") return new(System.Net.HttpStatusCode.NotFound);
            var project = p.Contains("/floodgate/") ? "floodgate" : "geyser";
            if (p.EndsWith("/builds/latest"))
            {
                var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Jar));
                var json = $"{{\"version\":\"2.12.1\",\"build\":{build},\"downloads\":{{\"spigot\":{{\"name\":\"{project}-Spigot.jar\",\"sha256\":\"{sha}\"}}}}}}";
                return new(System.Net.HttpStatusCode.OK) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") };
            }
            if (p.Contains("/downloads/"))
                return downloadFails && project == "geyser" ? new(System.Net.HttpStatusCode.InternalServerError) : new(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(Jar) };
            return new(System.Net.HttpStatusCode.NotFound);
        }));

    static string GeyserJarPath(string dir) => Path.Combine(dir, "plugins", "Geyser-Spigot.jar");

    [Fact] public async Task EnablingRecordsTheInstalledBuild()
    {
        Serve(1280);
        using var t = new TempDir();
        var st = await CrossplayManager.EnableAsync(t.Path, ServerType.Paper);
        Assert.Equal(1280, st.GeyserBuild); Assert.False(st.NeedsUpdate);
        Assert.Equal(1280, CrossplayManager.InstalledBuild(t.Path));
    }

    [Fact] public void AnOldGeyserWithNoRecordNeedsAnUpdate()
    {
        using var t = new TempDir();
        t.Write("plugins/Geyser-Spigot.jar");
        var st = CrossplayManager.Status(t.Path, ServerType.Paper);
        Assert.True(st.Geyser); Assert.Null(st.GeyserBuild); Assert.True(st.NeedsUpdate);
    }

    [Fact] public void NoGeyserNeedsNoUpdateAndHasNoBuild()
    {
        using var t = new TempDir();
        t.Write(".craftpanel-geyser.json", """{"build":5,"version":"1"}""");
        var st = CrossplayManager.Status(t.Path, ServerType.Paper);
        Assert.False(st.Geyser); Assert.Null(st.GeyserBuild); Assert.False(st.NeedsUpdate);
    }

    [Fact] public async Task UpdatingReplacesTheOldJarAndRecordsTheNewBuild()
    {
        Serve(1290);
        using var t = new TempDir();
        t.Write("plugins/Geyser-Spigot.jar", "old geyser");
        t.Write("plugins/floodgate-spigot.jar", "floodgate");
        t.Write("plugins/EssentialsX.jar", "x");
        var st = await CrossplayManager.UpdateGeyserAsync(t.Path, ServerType.Paper);
        Assert.Equal(1290, st.GeyserBuild); Assert.False(st.NeedsUpdate);
        Assert.Equal(Jar, await File.ReadAllBytesAsync(GeyserJarPath(t.Path)));
        Assert.Single(Directory.GetFiles(Path.Combine(t.Path, "plugins"), "*eyser*.jar"));       // no duplicate Geyser to confuse the loader
        Assert.True(File.Exists(Path.Combine(t.Path, "plugins", "floodgate-spigot.jar")));        // Floodgate stays
        Assert.True(File.Exists(Path.Combine(t.Path, "plugins", "EssentialsX.jar")));
        var trash = Directory.GetFiles(Path.Combine(t.Path, ".craftpanel-trash"), "*", SearchOption.AllDirectories);
        Assert.Contains(trash, f => File.ReadAllText(f) == "old geyser");                        // moved, not deleted
    }

    [Fact] public async Task AFailedUpdateKeepsTheOldGeyser()
    {
        Serve(1290, downloadFails: true);
        using var t = new TempDir();
        t.Write("plugins/Geyser-Spigot.jar", "old geyser");
        await Assert.ThrowsAsync<ProvisionException>(() => CrossplayManager.UpdateGeyserAsync(t.Path, ServerType.Paper));
        Assert.Equal("old geyser", File.ReadAllText(GeyserJarPath(t.Path)));
        Assert.Null(CrossplayManager.InstalledBuild(t.Path));
    }

    [Fact] public async Task UpdateIsRefusedWhereGeyserCantRun() =>
        await Assert.ThrowsAsync<ProvisionException>(() => CrossplayManager.UpdateGeyserAsync(Path.GetTempPath(), ServerType.Vanilla));

    [Fact] public async Task TurningCrossplayOffForgetsTheRecordedBuild()
    {
        Serve(1290);
        using var t = new TempDir();
        await CrossplayManager.EnableAsync(t.Path, ServerType.Paper);
        CrossplayManager.Disable(t.Path, ServerType.Paper);
        Assert.Null(CrossplayManager.InstalledBuild(t.Path));
        Assert.False(File.Exists(Path.Combine(t.Path, CrossplayManager.BuildFile)));
    }

    [Fact] public void LaunchArgsAddTheFlagOnlyWhenGeyserIsThere()
    {
        using var t = new TempDir();
        Assert.Equal("-Xmx2G", CrossplayManager.LaunchJvmArgs(t.Path, ServerType.Paper, "-Xmx2G"));
        t.Write("plugins/Geyser-Spigot.jar");
        Assert.Equal("-Xmx2G -DgeyserTransport=nethernet", CrossplayManager.LaunchJvmArgs(t.Path, ServerType.Paper, "-Xmx2G"));
        Assert.Equal("-DgeyserTransport=nethernet", CrossplayManager.LaunchJvmArgs(t.Path, ServerType.Paper, null));
    }

    [Fact] public void LaunchArgsRespectGeyserConfigTransportAndUnsupportedTypes()
    {
        using var t = new TempDir();
        t.Write("plugins/Geyser-Spigot.jar");
        t.Write("plugins/Geyser-Spigot/config.yml", "bedrock:\n  transport: both\n");
        Assert.Equal("-Xmx1G", CrossplayManager.LaunchJvmArgs(t.Path, ServerType.Paper, "-Xmx1G"));
        Assert.Equal("-Xmx1G", CrossplayManager.LaunchJvmArgs(t.Path, ServerType.Vanilla, "-Xmx1G"));
        Assert.Null(CrossplayManager.LaunchJvmArgs(t.Path, ServerType.Bedrock, null));
    }

    [Fact] public void CloneRemotePortIsReported()
    {
        using var t = new TempDir();
        t.Write("plugins/Geyser-Spigot.jar");
        t.Write("plugins/Geyser-Spigot/config.yml", "bedrock:\n  clone-remote-port: true\n");
        Assert.True(CrossplayManager.Status(t.Path, ServerType.Paper).CloneRemotePort);
    }
}
