using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace CraftPanel.App.Controls;

/// <summary>A small two-series line graph with a faint grid. Values are percentages (0–100), oldest first.</summary>
public class LineChart : Control
{
    public static readonly StyledProperty<IReadOnlyList<double>?> ValuesProperty = AvaloniaProperty.Register<LineChart, IReadOnlyList<double>?>(nameof(Values));
    public static readonly StyledProperty<IReadOnlyList<double>?> Values2Property = AvaloniaProperty.Register<LineChart, IReadOnlyList<double>?>(nameof(Values2));
    public static readonly StyledProperty<IBrush?> StrokeProperty = AvaloniaProperty.Register<LineChart, IBrush?>(nameof(Stroke));
    public static readonly StyledProperty<IBrush?> Stroke2Property = AvaloniaProperty.Register<LineChart, IBrush?>(nameof(Stroke2));
    public static readonly StyledProperty<IBrush?> GridProperty = AvaloniaProperty.Register<LineChart, IBrush?>(nameof(Grid));

    static LineChart() => AffectsRender<LineChart>(ValuesProperty, Values2Property, StrokeProperty, Stroke2Property, GridProperty);

    public IReadOnlyList<double>? Values { get => GetValue(ValuesProperty); set => SetValue(ValuesProperty, value); }
    public IReadOnlyList<double>? Values2 { get => GetValue(Values2Property); set => SetValue(Values2Property, value); }
    public IBrush? Stroke { get => GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public IBrush? Stroke2 { get => GetValue(Stroke2Property); set => SetValue(Stroke2Property, value); }
    public IBrush? Grid { get => GetValue(GridProperty); set => SetValue(GridProperty, value); }

    public override void Render(DrawingContext ctx)
    {
        var w = Bounds.Width; var h = Bounds.Height;
        if (w < 4 || h < 4) return;
        var grid = new Pen(Grid ?? Brushes.Gray, 1, new DashStyle([2, 4], 0));
        for (var i = 0; i <= 4; i++) { var y = Math.Round(h * i / 4) + .5; ctx.DrawLine(grid, new Point(0, y), new Point(w, y)); }
        Draw(ctx, Values, Stroke, w, h, fill: true);
        Draw(ctx, Values2, Stroke2, w, h, fill: false);
    }

    static void Draw(DrawingContext ctx, IReadOnlyList<double>? v, IBrush? stroke, double w, double h, bool fill)
    {
        if (v is null || v.Count < 2 || stroke is null) return;
        var pts = new Point[v.Count];
        for (var i = 0; i < v.Count; i++) pts[i] = new Point(w * i / (v.Count - 1), h - Math.Clamp(v[i], 0, 100) / 100 * (h - 2) - 1);
        var line = new StreamGeometry();
        using (var g = line.Open()) { g.BeginFigure(pts[0], false); for (var i = 1; i < pts.Length; i++) g.LineTo(pts[i]); g.EndFigure(false); }
        if (fill && stroke is ISolidColorBrush sb)
        {
            var area = new StreamGeometry();
            using (var g = area.Open()) { g.BeginFigure(new Point(0, h), true); foreach (var p in pts) g.LineTo(p); g.LineTo(new Point(w, h)); g.EndFigure(true); }
            var grad = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.FromArgb(70, sb.Color.R, sb.Color.G, sb.Color.B), 0), new GradientStop(Color.FromArgb(0, sb.Color.R, sb.Color.G, sb.Color.B), 1) },
            };
            ctx.DrawGeometry(grad, null, area);
        }
        ctx.DrawGeometry(null, new Pen(stroke, 2, lineJoin: PenLineJoin.Round, lineCap: PenLineCap.Round), line);
    }
}
