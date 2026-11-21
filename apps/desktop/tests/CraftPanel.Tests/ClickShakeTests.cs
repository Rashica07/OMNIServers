using CraftPanel.App.Services;
using Xunit;

namespace CraftPanel.Tests;

public class ClickShakeTests
{
    [Fact] public void SwellIsTinyAndEndsAtRest()
    {
        var f = ClickShake.Frames();
        Assert.All(f, x => Assert.InRange(x, 1.0, 1.0141));
        Assert.Equal(1, f[^1]);
        Assert.InRange(f.Max(), 1.013, 1.0141);
    }

    [Fact] public void SwellIsSmoothAndSlow()
    {
        var f = ClickShake.Frames();
        for (var i = 1; i < f.Count; i++) Assert.True(Math.Abs(f[i] - f[i - 1]) < 0.003, $"frame {i} jumps");
        Assert.True(f.Count * 16 >= 700);
    }
}
