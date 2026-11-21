using CraftPanel.Core.Performance;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class PerformanceChartTests
{
    [Fact]
    public void WindowKeepsOnlyRecentSamples()
    {
        var now = new DateTime(2026, 11, 1, 12, 0, 0, DateTimeKind.Utc);
        var all = new List<MetricSample> { new(now.AddMinutes(-10), 100, 1), new(now.AddSeconds(-50), 200, 2), new(now.AddSeconds(-5), 300, 3) };
        Assert.Equal(2, PerformanceChart.Window(all, TimeSpan.FromMinutes(1), now).Count);
        Assert.Equal(3, PerformanceChart.Window(all, TimeSpan.FromMinutes(30), now).Count);
        Assert.Empty(PerformanceChart.Window([], TimeSpan.FromHours(4), now));
    }

    [Fact]
    public void DownsampleAveragesInsteadOfDroppingSpikes()
    {
        var v = Enumerable.Repeat(0.0, 100).ToList(); v[50] = 100;
        var d = PerformanceChart.Downsample(v, 10);
        Assert.Equal(10, d.Length);
        Assert.Contains(d, x => x > 5);                          // the spike survives as a bump
        Assert.Equal(v.Count, PerformanceChart.Downsample(v, 500).Length);   // short series are returned untouched
        Assert.Empty(PerformanceChart.Downsample([], 10));
    }

    [Theory]
    [InlineData(48, "48s")]
    [InlineData(192, "3m 12s")]
    [InlineData(7500, "2h 05m")]
    [InlineData(100000, "1d 3h")]
    public void UptimeIsReadable(int seconds, string expected)
    {
        var now = DateTime.Now;
        Assert.Equal(expected, PerformanceChart.Uptime(now.AddSeconds(-seconds), now));
        Assert.Equal("—", PerformanceChart.Uptime(null, now));
    }

    [Fact]
    public void RangesCoverOneMinuteToFourHours()
    {
        Assert.Equal(["1m", "5m", "30m", "1h", "4h"], PerformanceChart.Ranges.Select(r => r.Label));
        Assert.Equal(TimeSpan.FromHours(4), PerformanceChart.Ranges[^1].Span);
    }
}
