using CraftPanel.Core;
using CraftPanel.Core.Power;
using Xunit;

namespace CraftPanel.Tests;

public class KeepAwakeTests
{
    const string Sample = """
        Power Setting GUID: 5ca83367-6e45-459f-a27b-476b1d01c936  (Lid close action)
          Current AC Power Setting Index: 0x00000001
          Current DC Power Setting Index: 0x00000002
        """;

    [Fact] public void ReadsAcAndBatteryLidActions()
    {
        Assert.Equal(1, KeepAwake.ParseLidIndex(Sample, true));
        Assert.Equal(2, KeepAwake.ParseLidIndex(Sample, false));
        Assert.Null(KeepAwake.ParseLidIndex("nothing here", true));
    }

    [Fact] public void LidCommandsSetBothPowerSourcesThenApply()
    {
        var c = KeepAwake.LidCommands(0, 0);
        Assert.Equal(3, c.Count);
        Assert.Equal("/setacvalueindex", c[0][0]); Assert.Equal("0", c[0][4]);
        Assert.Equal("/setdcvalueindex", c[1][0]);
        Assert.Equal("/setactive", c[2][0]);
    }

    [Fact] public void LinuxLockCoversTheLidSwitch() =>
        Assert.Contains("--what=handle-lid-switch:sleep:idle", KeepAwake.InhibitArgs());

    [Fact] public void SettingsRememberTheOriginalLidAction()
    {
        var f = Path.Combine(Path.GetTempPath(), "omni-aw-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var s = AppSettings.Load(f); s.KeepRunningLidClosed = true; s.LidSavedAc = 1; s.LidSavedDc = 2; s.Save();
            var back = AppSettings.Load(f);
            Assert.True(back.KeepRunningLidClosed); Assert.Equal(1, back.LidSavedAc); Assert.Equal(2, back.LidSavedDc);
        }
        finally { File.Delete(f); }
    }
}
