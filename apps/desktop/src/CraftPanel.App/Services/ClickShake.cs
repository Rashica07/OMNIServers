using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace CraftPanel.App.Services;

/// <summary>A very slight, slow whoosh to the left and back on any button when it is clicked. Installed once at startup.</summary>
public static class ClickShake
{
    public static void Install() =>
        Button.ClickEvent.AddClassHandler<Button>((b, _) => Run(b), Avalonia.Interactivity.RoutingStrategies.Bubble);

    /// <summary>
    /// One slow, soft swell (a slight zoom in and back, no movement): eased in and out, ending exactly at scale 1.
    /// </summary>
    public static IReadOnlyList<double> Frames(double travel = 0.014, int count = 48)
    {
        var f = new List<double>();
        for (var i = 1; i < count; i++)
        {
            var t = i / (double)count;
            var eased = t * t * t * (t * (t * 6 - 15) + 10); // smootherstep
            f.Add(1 + travel * Math.Sin(eased * Math.PI));
        }
        f.Add(1);
        return f;
    }

    static void Run(Control c)
    {
        if (c.Tag is "noshake") return;
        var frames = Frames();
        var i = 0;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        timer.Tick += (_, _) =>
        {
            if (i >= frames.Count) { timer.Stop(); c.RenderTransform = null; return; }
            var k = frames[i++]; c.RenderTransform = new ScaleTransform(k, k);
        };
        timer.Start();
    }
}
