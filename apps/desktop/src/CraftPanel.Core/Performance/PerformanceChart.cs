using CraftPanel.Core.Runtime;

namespace CraftPanel.Core.Performance;

/// <summary>Time windows and number-crunching for the Performance tab's graph.</summary>
public static class PerformanceChart
{
    public static readonly (string Label, TimeSpan Span)[] Ranges =
    [
        ("1m", TimeSpan.FromMinutes(1)), ("5m", TimeSpan.FromMinutes(5)), ("30m", TimeSpan.FromMinutes(30)), ("1h", TimeSpan.FromHours(1)), ("4h", TimeSpan.FromHours(4)),
    ];

    /// <summary>The samples that fall inside the last <paramref name="span"/> (oldest first).</summary>
    public static List<MetricSample> Window(IReadOnlyList<MetricSample> all, TimeSpan span, DateTime nowUtc) =>
        all.Where(s => nowUtc - s.At <= span).ToList();

    /// <summary>Evenly spaced points for drawing: at most <paramref name="maxPoints"/>, averaging neighbours so spikes aren't dropped.</summary>
    public static double[] Downsample(IReadOnlyList<double> values, int maxPoints)
    {
        if (values.Count <= maxPoints || maxPoints < 2) return [.. values];
        var result = new double[maxPoints];
        for (var i = 0; i < maxPoints; i++)
        {
            var from = (int)((long)i * values.Count / maxPoints);
            var to = Math.Max(from + 1, (int)((long)(i + 1) * values.Count / maxPoints));
            double sum = 0;
            for (var j = from; j < to; j++) sum += values[j];
            result[i] = sum / (to - from);
        }
        return result;
    }

    public static string Uptime(DateTime? started, DateTime now)
    {
        if (started is null) return "—";
        var t = now - started.Value;
        if (t < TimeSpan.Zero) t = TimeSpan.Zero;
        if (t.TotalMinutes < 1) return $"{(int)t.TotalSeconds}s";
        if (t.TotalHours < 1) return $"{t.Minutes}m {t.Seconds:00}s";
        if (t.TotalDays < 1) return $"{(int)t.TotalHours}h {t.Minutes:00}m";
        return $"{(int)t.TotalDays}d {t.Hours}h";
    }
}
