using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using CraftPanel.App.Controls;

namespace CraftPanel.App.Views;

/// <summary>A small always-on-top card in the corner of the screen, for player events while OMNIServers is in the background.</summary>
public static class BackgroundToast
{
    static readonly List<Window> Open = [];

    public static void Show(string title, string subtitle, Action onClick)
    {
        Dispatcher.UIThread.Post(() =>
        {
            var app = Application.Current!;
            var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
            text.Children.Add(new TextBlock { Text = subtitle, Classes = { "faint", "small" } });
            var icon = new Icon { Kind = "users", Width = 20, Height = 20, VerticalAlignment = VerticalAlignment.Top };
            icon.Bind(Icon.ForegroundProperty, app.GetResourceObservable("Cp.Accent"));
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Margin = new Thickness(14, 12), ColumnSpacing = 12 };
            row.Children.Add(icon); Grid.SetColumn(text, 1); row.Children.Add(text);
            var border = new Border { Child = row, CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand) };
            border.Bind(Border.BackgroundProperty, app.GetResourceObservable("Cp.Surface2"));
            border.Bind(Border.BorderBrushProperty, app.GetResourceObservable("Cp.Line"));
            var w = new Window
            {
                Content = border, Width = 330, SizeToContent = SizeToContent.Height, WindowDecorations = WindowDecorations.None, Topmost = true,
                ShowInTaskbar = false, ShowActivated = false, CanResize = false, Background = Brushes.Transparent, TransparencyLevelHint = [WindowTransparencyLevel.Transparent],
            };
            w.Classes.Add("toast");
            w.PointerPressed += (_, _) => { onClick(); w.Close(); };
            w.Closed += (_, _) => { Open.Remove(w); Reposition(); };
            Open.Add(w);
            w.Show();
            Reposition();
            _ = Task.Delay(TimeSpan.FromSeconds(6)).ContinueWith(_ => Dispatcher.UIThread.Post(() => { if (Open.Contains(w)) w.Close(); }));
        });
    }

    static void Reposition()
    {
        var y = 0;
        foreach (var w in Open.ToList())
        {
            var screen = w.Screens.Primary ?? w.Screens.All.FirstOrDefault();
            if (screen is null) continue;
            var wa = screen.WorkingArea;
            var scale = screen.Scaling;
            var h = (int)((w.Bounds.Height > 0 ? w.Bounds.Height : 80) * scale);
            y += h + (int)(10 * scale);
            w.Position = new PixelPoint(wa.Right - (int)((330 + 16) * scale), wa.Bottom - y - (int)(6 * scale));
        }
    }
}
