using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using CraftPanel.Core;

namespace CraftPanel.App.Controls;

/// <summary>
/// Memory allocation: the number is the hero, the slider is secondary, the PC's safe limit is a tick on the track, and a
/// recommendation follows the server kind and player count until you drag the slider yourself.
/// </summary>
public class RamPicker : UserControl
{
    public static readonly StyledProperty<double> RamMBProperty = AvaloniaProperty.Register<RamPicker, double>(nameof(RamMB), 4096, defaultBindingMode: Avalonia.Data.BindingMode.TwoWay);
    public static readonly StyledProperty<RamKind> KindProperty = AvaloniaProperty.Register<RamPicker, RamKind>(nameof(Kind));
    public static readonly StyledProperty<int> PlayersProperty = AvaloniaProperty.Register<RamPicker, int>(nameof(Players), 4, defaultBindingMode: Avalonia.Data.BindingMode.TwoWay);
    public static readonly StyledProperty<bool> ShowPlayersProperty = AvaloniaProperty.Register<RamPicker, bool>(nameof(ShowPlayers), true);
    public static readonly StyledProperty<bool> FollowProperty = AvaloniaProperty.Register<RamPicker, bool>(nameof(Follow), true);
    public static readonly StyledProperty<int> OtherAllocatedMBProperty = AvaloniaProperty.Register<RamPicker, int>(nameof(OtherAllocatedMB));

    SystemMemory _sys = SystemMemory.Current();
    readonly TextBlock _hero = new() { FontSize = 26, Classes = { "display" } };
    readonly TextBlock _gb = new() { Text = "GB", Classes = { "faint" }, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(4, 0, 0, 5) };
    readonly Slider _slider = new() { Minimum = RamAdvisor.MinMB, TickFrequency = 512, IsSnapToTickEnabled = true, Height = 24 };
    readonly Border _safeTick = new() { Width = 2, Height = 12, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
    readonly Grid _sliderHost = new() { Height = 24 };
    readonly TextBlock _minLabel = new() { Classes = { "faint", "tiny" } };
    readonly TextBlock _midLabel = new() { Classes = { "faint", "tiny" }, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _maxLabel = new() { Classes = { "faint", "tiny" }, HorizontalAlignment = HorizontalAlignment.Right };
    readonly NumericUpDown _players = new() { Minimum = 1, Maximum = 200, Increment = 1, Width = 100, FormatString = "0", Height = 30 };
    readonly StackPanel _playersRow = new() { Orientation = Orientation.Horizontal, Spacing = 10 };
    readonly TextBlock _recText = new() { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _useRec = new() { Content = "Use recommended", Classes = { "ghost", "sm" }, HorizontalAlignment = HorizontalAlignment.Right };
    readonly StackPanel _warnings = new() { Spacing = 6 };
    bool _updating;

    static RamPicker()
    {
        RamMBProperty.Changed.AddClassHandler<RamPicker>((p, _) => p.Sync());
        KindProperty.Changed.AddClassHandler<RamPicker>((p, _) => p.OnInputsChanged());
        PlayersProperty.Changed.AddClassHandler<RamPicker>((p, _) => p.OnInputsChanged());
        ShowPlayersProperty.Changed.AddClassHandler<RamPicker>((p, _) => p._playersRow.IsVisible = p.ShowPlayers);
        OtherAllocatedMBProperty.Changed.AddClassHandler<RamPicker>((p, _) => p.Sync());
        IsEnabledProperty.Changed.AddClassHandler<RamPicker>((p, _) => p.Sync());
    }

    public RamPicker()
    {
        _safeTick.Bind(Border.BackgroundProperty, this.GetResourceObservable("Cp.InkFaint"));
        _sliderHost.Children.Add(_slider);
        _sliderHost.Children.Add(_safeTick);
        _sliderHost.SizeChanged += (_, _) => PositionTick();

        _playersRow.Children.Add(new TextBlock { Text = "How many people will play?", Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center });
        _playersRow.Children.Add(_players);

        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var title = new StackPanel { Spacing = 3 };
        title.Children.Add(new TextBlock { Text = "MEMORY FOR THIS SERVER", Classes = { "label" }, HorizontalAlignment = HorizontalAlignment.Left });
        title.Children.Add(new TextBlock { Text = "More memory lets you run more mods and players — it doesn't make the game faster on its own.", Classes = { "faint", "small" }, TextWrapping = TextWrapping.Wrap, MaxWidth = 360, HorizontalAlignment = HorizontalAlignment.Left });
        var hero = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Children = { _hero, _gb } };
        Grid.SetColumn(hero, 1);
        head.Children.Add(title); head.Children.Add(hero);

        var labels = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        Grid.SetColumn(_midLabel, 1); Grid.SetColumn(_maxLabel, 2);
        labels.Children.Add(_minLabel); labels.Children.Add(_midLabel); labels.Children.Add(_maxLabel);

        var rec = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 8 };
        var sparkle = new Icon { Kind = "sparkle", Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        sparkle.Bind(Icon.ForegroundProperty, this.GetResourceObservable("Cp.Accent"));
        Grid.SetColumn(_recText, 1); Grid.SetColumn(_useRec, 2);
        rec.Children.Add(sparkle); rec.Children.Add(_recText); rec.Children.Add(_useRec);

        Content = new StackPanel { Spacing = 10, Children = { head, _playersRow, _sliderHost, labels, rec, _warnings } };

        _slider.PropertyChanged += (_, e) =>
        {
            if (e.Property == Avalonia.Controls.Primitives.RangeBase.ValueProperty && !_updating) { SetCurrentValue(FollowProperty, false); SetCurrentValue(RamMBProperty, _slider.Value); }
        };
        _players.ValueChanged += (_, e) => { if (!_updating && e.NewValue is { } v) SetCurrentValue(PlayersProperty, (int)v); };
        _useRec.Click += (_, _) => { SetCurrentValue(FollowProperty, true); SetCurrentValue(RamMBProperty, Recommended); };
        _sys = SystemMemory.Current();
        Sync();
        _ = LoadDetailedAsync();
    }

    public double RamMB { get => GetValue(RamMBProperty); set => SetValue(RamMBProperty, value); }
    public RamKind Kind { get => GetValue(KindProperty); set => SetValue(KindProperty, value); }
    public int Players { get => GetValue(PlayersProperty); set => SetValue(PlayersProperty, value); }
    public bool ShowPlayers { get => GetValue(ShowPlayersProperty); set => SetValue(ShowPlayersProperty, value); }
    public bool Follow { get => GetValue(FollowProperty); set => SetValue(FollowProperty, value); }
    public int OtherAllocatedMB { get => GetValue(OtherAllocatedMBProperty); set => SetValue(OtherAllocatedMBProperty, value); }

    public SystemMemory System => _sys;
    public int Recommended => RamAdvisor.Recommend(Kind, Players, _sys.SafeMaxMB);
    public List<RamWarning> Warnings => RamAdvisor.Warnings((int)RamMB, Kind, Players, _sys, OtherAllocatedMB);

    async Task LoadDetailedAsync()
    {
        _sys = await SystemMemory.DetailedAsync();
        Avalonia.Threading.Dispatcher.UIThread.Post(() => { if (Follow) SetCurrentValue(RamMBProperty, Recommended); Sync(); });
    }

    void OnInputsChanged()
    {
        if (Follow) SetCurrentValue(RamMBProperty, Recommended);
        Sync();
    }

    int MaxMb => Math.Max(Math.Max(_sys.TotalMB, (int)RamMB), 4096);

    void PositionTick()
    {
        var w = _slider.Bounds.Width;
        if (w <= 0) return;
        var frac = Math.Clamp((double)(_sys.SafeMaxMB - RamAdvisor.MinMB) / (MaxMb - RamAdvisor.MinMB), 0, 1);
        _safeTick.IsVisible = frac is > 0.02 and < 0.98;
        _safeTick.Margin = new Thickness(11 + frac * (w - 22), 0, 0, 0);
    }

    void Sync()
    {
        _updating = true;
        try
        {
            var ram = (int)RamMB;
            var over = ram > _sys.SafeMaxMB;
            _slider.Maximum = MaxMb;
            _slider.Value = Math.Clamp(ram, RamAdvisor.MinMB, MaxMb);
            _slider.IsEnabled = IsEnabled;
            _hero.Text = ram % 1024 == 0 ? (ram / 1024).ToString() : (ram / 1024.0).ToString("0.0");
            _hero.Classes.Set("warn", over);
            _playersRow.IsVisible = ShowPlayers && Kind != RamKind.Bedrock;
            if ((int)_players.Value.GetValueOrDefault() != Players) _players.Value = Players;
            _minLabel.Text = RamAdvisor.Gb(RamAdvisor.MinMB);
            _maxLabel.Text = RamAdvisor.Gb(MaxMb);
            _midLabel.Text = over ? $"Over the {RamAdvisor.Gb(_sys.SafeMaxMB)} safe limit"
                : $"{RamAdvisor.Gb(_sys.TotalMB)}{(_sys.MemoryType is { } t ? " " + t : "")} · {ShortChip(_sys.Chip)} · {RamAdvisor.Gb(_sys.AvailableMB)} free now";
            _midLabel.Classes.Set("warn", over);
            var rec = Recommended;
            var forWho = ShowPlayers ? $" for {Kind.Label()} with {Players} player{(Players == 1 ? "" : "s")}" : $" for {Kind.Label()}";
            _recText.Text = $"Recommended: {RamAdvisor.Gb(rec)}{forWho}";
            var showRec = Kind != RamKind.Bedrock;
            _recText.IsVisible = showRec; _useRec.IsVisible = showRec && ram != rec && IsEnabled;
            _warnings.Children.Clear();
            foreach (var w in Warnings)
            {
                var b = new Border { Classes = { "banner" } };
                if (w.Serious) b.Classes.Add("warn");
                b.Child = new TextBlock { Text = w.Message, TextWrapping = TextWrapping.Wrap, Classes = { w.Serious ? "warn" : "dim" } };
                _warnings.Children.Add(b);
            }
            PositionTick();
        }
        finally { _updating = false; }
    }

    static string ShortChip(string chip) => chip.Replace("(R)", "").Replace("(TM)", "").Replace("Apple ", "").Replace(" CPU", "").Trim();
}
