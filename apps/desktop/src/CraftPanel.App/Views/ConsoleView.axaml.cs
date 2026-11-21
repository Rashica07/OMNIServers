using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
using CraftPanel.App.Services;
using CraftPanel.App.ViewModels;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.Views;

public partial class ConsoleView : UserControl
{
    bool _follow = true;
    ConsoleViewModel? _vm;
    DispatcherTimer? _logTimer;
    const int MaxRuns = 700;

    public ConsoleView()
    {
        InitializeComponent();
        Scroller.ScrollChanged += OnScroll;
        CommandBox.KeyDown += OnCommandKey;
        DataContextChanged += (_, _) => Attach();
        Palette.Changed += OnPaletteChanged;
        DetachedFromVisualTree += (_, _) => { _logTimer?.Stop(); Palette.Changed -= OnPaletteChanged; if (_vm is not null) { _vm.LineAdded -= Append; _vm.Reset -= Rebuild; } };
    }

    void OnPaletteChanged() => Dispatcher.UIThread.Post(Rebuild);

    void Attach()
    {
        if (_vm is not null) { _vm.LineAdded -= Append; _vm.Reset -= Rebuild; }
        _vm = DataContext as ConsoleViewModel;
        if (_vm is null) return;
        _vm.LineAdded += Append;
        _vm.Reset += Rebuild;
        _logTimer ??= new DispatcherTimer { Interval = CraftPanel.Core.Performance.LightMode.LogRefresh };
        _logTimer.Tick -= OnLogTick; _logTimer.Tick += OnLogTick; _logTimer.Start();
        Rebuild();
    }

    void OnLogTick(object? s, EventArgs e) { if (_vm is { LogMode: true } && _follow) { _vm.LoadLog(); Rebuild(); } }

    IBrush Brush(string key) => this.TryFindResource(key, ActualThemeVariant, out var r) && r is IBrush b ? b : Brushes.Gray;

    IBrush ForLine(LogLine l)
    {
        if (l.Stream == LogStream.System) return l.Text.StartsWith("> ") ? Brush("Cp.AccentSoft") : Brush("Cp.InkFaint");
        if (l.Stream == LogStream.Stderr || l.Text.Contains("/ERROR]") || l.Text.Contains(" ERROR]")) return Brush("Cp.BadSoft");
        if (l.Text.Contains("/WARN]") || l.Text.Contains(" WARN]")) return Brush("Cp.WarnSoft");
        return Brush("Cp.InkDim");
    }

    void Rebuild()
    {
        if (_vm is null) return;
        Output.Inlines?.Clear();
        if (_vm.LogMode)
        {
            var lines = _vm.LogText.Split('\n');
            var color = Brush("Cp.InkDim");
            foreach (var line in lines.TakeLast(2500).Where(l => _vm.Filter.Length == 0 || l.Contains(_vm.Filter, StringComparison.OrdinalIgnoreCase)))
                Output.Inlines!.Add(new Run(line.TrimEnd('\r') + "\n") { Foreground = color });
            if (_vm.LogText.Length == 0) Output.Inlines!.Add(new Run("(the log file is empty or doesn't exist yet)") { Foreground = Brush("Cp.InkFaint") });
        }
        else
        {
            var lines = _vm.Visible().ToList();
            foreach (var l in lines) Output.Inlines!.Add(new Run(l.Text + "\n") { Foreground = ForLine(l) });
            if (lines.Count == 0) Output.Inlines!.Add(new Run(_vm.IsRunning ? "Waiting for output…" : "The server isn't running. Press Start to launch it.") { Foreground = Brush("Cp.InkFaint") });
        }
        if (_follow) ScrollToEnd();
    }

    void Append(LogLine l)
    {
        var inlines = Output.Inlines!;
        if (inlines.Count == 1 && inlines[0] is Run { Text: { } t } && (t.StartsWith("Waiting for output") || t.StartsWith("The server isn't running"))) inlines.Clear();
        inlines.Add(new Run(l.Text + "\n") { Foreground = ForLine(l) });
        if (inlines.Count > MaxRuns) inlines.RemoveRange(0, inlines.Count - MaxRuns);
        if (_follow) ScrollToEnd();
    }

    void ScrollToEnd() => Dispatcher.UIThread.Post(() => Scroller.ScrollToEnd(), DispatcherPriority.Background);

    // Following stops only when *you* scroll up (the offset moves up), never because new lines grew the content
    // before the follow-scroll landed; reaching the bottom again resumes it.
    void OnScroll(object? s, ScrollChangedEventArgs e)
    {
        var nearBottom = Scroller.Offset.Y + Scroller.Viewport.Height >= Scroller.Extent.Height - 40;
        if (nearBottom) _follow = true;
        else if (e.OffsetDelta.Y < -1) _follow = false;
        JumpButton.IsVisible = !_follow;
    }

    void OnJumpClick(object? s, RoutedEventArgs e) { _follow = true; JumpButton.IsVisible = false; Scroller.ScrollToEnd(); }

    void OnCommandKey(object? s, KeyEventArgs e)
    {
        if (_vm is null) return;
        if (e.Key == Key.Enter) { _vm.SendCommand.Execute(null); e.Handled = true; }
        else if (e.Key == Key.Up) { _vm.RecallHistory(-1); e.Handled = true; }
        else if (e.Key == Key.Down) { _vm.RecallHistory(1); e.Handled = true; }
    }
}
