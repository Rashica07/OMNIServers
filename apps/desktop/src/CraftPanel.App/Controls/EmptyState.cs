using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace CraftPanel.App.Controls;

/// <summary>A centred icon, title and message for empty lists and offline states.</summary>
public class EmptyState : Border
{
    public static readonly StyledProperty<string?> IconProperty = AvaloniaProperty.Register<EmptyState, string?>(nameof(Icon));
    public static readonly StyledProperty<string?> TitleProperty = AvaloniaProperty.Register<EmptyState, string?>(nameof(Title));
    public static readonly StyledProperty<string?> MessageProperty = AvaloniaProperty.Register<EmptyState, string?>(nameof(Message));

    readonly Icon _icon = new() { Width = 28, Height = 28, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _title = new() { Classes = { "h3" }, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center };
    readonly TextBlock _message = new() { Classes = { "faint" }, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 380 };

    public EmptyState()
    {
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        _icon.Bind(Controls.Icon.ForegroundProperty, this.GetResourceObservable("Cp.InkGhost"));
        Child = new StackPanel { Spacing = 8, Margin = new Thickness(24), Children = { _icon, _title, _message } };
    }

    public string? Icon { get => GetValue(IconProperty); set => SetValue(IconProperty, value); }
    public string? Title { get => GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Message { get => GetValue(MessageProperty); set => SetValue(MessageProperty, value); }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == IconProperty) _icon.Kind = Icon;
        else if (change.Property == TitleProperty) _title.Text = Title;
        else if (change.Property == MessageProperty) { _message.Text = Message; _message.IsVisible = !string.IsNullOrEmpty(Message); }
    }
}
