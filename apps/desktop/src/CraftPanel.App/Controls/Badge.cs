using Avalonia;
using Avalonia.Controls;

namespace CraftPanel.App.Controls;

static class ToneClasses
{
    public static readonly string[] All = ["accent", "ok", "warn", "bad", "info"];

    public static void Apply(Control c, string? tone)
    {
        foreach (var t in All) c.Classes.Set(t, t == tone);
    }
}

/// <summary>A small pill: <c>Text</c> with a <c>Tone</c> (neutral, accent, ok, warn, bad).</summary>
public class Badge : Border
{
    public static readonly StyledProperty<string?> TextProperty = AvaloniaProperty.Register<Badge, string?>(nameof(Text));
    public static readonly StyledProperty<string?> ToneProperty = AvaloniaProperty.Register<Badge, string?>(nameof(Tone));

    readonly TextBlock _text = new();

    public Badge()
    {
        Classes.Add("badge");
        Child = _text;
    }

    public string? Text { get => GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public string? Tone { get => GetValue(ToneProperty); set => SetValue(ToneProperty, value); }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == TextProperty) _text.Text = Text;
        else if (change.Property == ToneProperty) ToneClasses.Apply(this, Tone);
    }
}

/// <summary>A round status dot coloured by tone (ok, warn, bad; anything else is idle grey).</summary>
public class ToneDot : Border
{
    public static readonly StyledProperty<string?> ToneProperty = AvaloniaProperty.Register<ToneDot, string?>(nameof(Tone));

    public ToneDot() => Classes.Add("dot");

    public string? Tone { get => GetValue(ToneProperty); set => SetValue(ToneProperty, value); }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == ToneProperty) ToneClasses.Apply(this, Tone);
    }
}
