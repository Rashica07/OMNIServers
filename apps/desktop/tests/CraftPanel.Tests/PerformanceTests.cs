using CraftPanel.Core;
using CraftPanel.Core.Performance;
using Xunit;

namespace CraftPanel.Tests;

public class PerformanceTests
{
    static SystemMemory Pc(int mb, int cores) => new(mb, mb / 2, null, "x", cores);

    [Fact]
    public void AutomaticTurnsLightModeOnForWeakAndRemotePcsOnly()
    {
        Assert.True(LightMode.Decide(LightSetting.Auto, Pc(4096, 8), false).Active);        // 4 GB
        Assert.True(LightMode.Decide(LightSetting.Auto, Pc(16384, 2), false).Active);       // 2 cores
        Assert.False(LightMode.Decide(LightSetting.Auto, Pc(16384, 8), false).Active);
        var remote = LightMode.Decide(LightSetting.Auto, Pc(16384, 8), true);
        Assert.True(remote.Active); Assert.True(remote.SoftwareDrawing); Assert.Contains("remote", remote.Reason);
        var weak = LightMode.Decide(LightSetting.Auto, Pc(4096, 2), false);
        Assert.False(weak.SoftwareDrawing);                                                  // a weak PC alone doesn't change how it draws
        Assert.Contains("4 GB", weak.Reason);
    }

    [Fact]
    public void YourChoiceAlwaysWins()
    {
        Assert.False(LightMode.Decide(LightSetting.Off, Pc(2048, 1), true).Active);
        var on = LightMode.Decide(LightSetting.On, Pc(32768, 16), false);
        Assert.True(on.Active); Assert.True(on.SoftwareDrawing);
    }

    [Fact]
    public void SettingNamesRoundTripAndUnknownMeansAuto()
    {
        foreach (var s in Enum.GetValues<LightSetting>()) Assert.Equal(s, LightMode.Parse(LightMode.Name(s)));
        Assert.Equal(LightSetting.Auto, LightMode.Parse(null)); Assert.Equal(LightSetting.Auto, LightMode.Parse("nonsense"));
        Assert.Equal(LightSetting.On, LightMode.Parse("ON"));
    }

    [Fact]
    public void LightModePollsLessOften()
    {
        var old = LightMode.Current;
        try
        {
            LightMode.Current = new(false, false, "");
            var normal = (LightMode.MetricsInterval, LightMode.LogRefresh);
            LightMode.Current = new(true, false, "");
            Assert.True(LightMode.MetricsInterval > normal.MetricsInterval); Assert.True(LightMode.LogRefresh > normal.LogRefresh);
        }
        finally { LightMode.Current = old; }
    }

    static Properties Props(TempDir t, string text) { t.Write("server.properties", text); return Properties.Load(t.Path); }

    [Fact]
    public void PresetOnlyLowersAndSaysWhatItWillChange()
    {
        using var t = new TempDir();
        var p = Props(t, "view-distance=12\nmotd=Hi\n");
        var plan = LowSpecPreset.Plan(p, ServerType.Paper);
        Assert.Equal(["view-distance", "simulation-distance"], plan.Select(c => c.Key));
        Assert.Equal("12", plan[0].From); Assert.Equal("6", plan[0].To); Assert.Null(plan[1].From);
        LowSpecPreset.Apply(p, plan);
        var again = Properties.Load(t.Path);
        Assert.Equal(6, again.GetInt("view-distance", 0)); Assert.Equal(4, again.GetInt("simulation-distance", 0)); Assert.Equal("Hi", again.Get("motd"));
        Assert.Empty(LowSpecPreset.Plan(again, ServerType.Paper));                             // nothing left to do
    }

    [Fact]
    public void PresetNeverRaisesAnAlreadyLowValue()
    {
        using var t = new TempDir();
        var p = Props(t, "view-distance=4\nsimulation-distance=3\n");
        Assert.Empty(LowSpecPreset.Plan(p, ServerType.Fabric));
    }

    [Fact]
    public void BedrockUsesItsOwnKeys()
    {
        using var t = new TempDir();
        var plan = LowSpecPreset.Plan(Props(t, "view-distance=32\ntick-distance=8\n"), ServerType.Bedrock);
        Assert.Equal(["view-distance", "tick-distance"], plan.Select(c => c.Key));
        Assert.DoesNotContain(plan, c => c.Key == "simulation-distance");
    }
}
