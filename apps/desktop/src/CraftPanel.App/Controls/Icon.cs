using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Media;

namespace CraftPanel.App.Controls;

/// <summary>A Lucide icon (24×24 box, round-capped stroke) drawn straight from path data; colour comes from the inherited foreground.</summary>
public class Icon : Control
{
    public static readonly StyledProperty<string?> KindProperty = AvaloniaProperty.Register<Icon, string?>(nameof(Kind));
    public static readonly StyledProperty<IBrush?> ForegroundProperty = TextElement.ForegroundProperty.AddOwner<Icon>();
    public static readonly StyledProperty<double> StrokeWidthProperty = AvaloniaProperty.Register<Icon, double>(nameof(StrokeWidth), 2);

    static readonly Dictionary<string, Geometry> Cache = [];

    static Icon()
    {
        AffectsRender<Icon>(KindProperty, ForegroundProperty, StrokeWidthProperty);
        WidthProperty.OverrideDefaultValue<Icon>(16);
        HeightProperty.OverrideDefaultValue<Icon>(16);
    }

    public string? Kind { get => GetValue(KindProperty); set => SetValue(KindProperty, value); }
    public IBrush? Foreground { get => GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }
    public double StrokeWidth { get => GetValue(StrokeWidthProperty); set => SetValue(StrokeWidthProperty, value); }

    public static Geometry? Lookup(string? kind)
    {
        if (kind is null || !(IconData.Paths.TryGetValue(kind, out var d) || IconDataExtra.Paths.TryGetValue(kind, out d))) return null;
        if (!Cache.TryGetValue(kind, out var g))
        {
            var parts = d.Split('|', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 1) g = Geometry.Parse(parts[0]);
            else
            {
                var group = new GeometryGroup { FillRule = FillRule.NonZero };
                foreach (var part in parts) group.Children.Add(Geometry.Parse(part));
                g = group;
            }
            Cache[kind] = g;
        }
        return g;
    }

    public override void Render(DrawingContext context)
    {
        if (Lookup(Kind) is not { } geo || Bounds.Width <= 0) return;
        var brush = Foreground ?? Brushes.White;
        using (context.PushTransform(Matrix.CreateScale(Bounds.Width / 24, Bounds.Height / 24)))
            context.DrawGeometry(null, new Pen(brush, StrokeWidth, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round), geo);
    }
}
