using Avalonia;
using Avalonia.Controls;

namespace CraftPanel.App.Controls;

/// <summary>A label above a control, with an optional hint below.</summary>
public class Field : ContentControl
{
    public static readonly StyledProperty<string?> LabelProperty = AvaloniaProperty.Register<Field, string?>(nameof(Label));
    public static readonly StyledProperty<string?> HintProperty = AvaloniaProperty.Register<Field, string?>(nameof(Hint));
    public string? Label { get => GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
    public string? Hint { get => GetValue(HintProperty); set => SetValue(HintProperty, value); }
    protected override Type StyleKeyOverride => typeof(Field);
}

/// <summary>A titled card (icon, title, description) holding a form or a list.</summary>
public class Card : ContentControl
{
    public static readonly StyledProperty<string?> TitleProperty = AvaloniaProperty.Register<Card, string?>(nameof(Title));
    public static readonly StyledProperty<string?> DescriptionProperty = AvaloniaProperty.Register<Card, string?>(nameof(Description));
    public static readonly StyledProperty<string?> IconProperty = AvaloniaProperty.Register<Card, string?>(nameof(Icon));
    public static readonly StyledProperty<object?> ActionsProperty = AvaloniaProperty.Register<Card, object?>(nameof(Actions));
    public string? Title { get => GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Description { get => GetValue(DescriptionProperty); set => SetValue(DescriptionProperty, value); }
    public string? Icon { get => GetValue(IconProperty); set => SetValue(IconProperty, value); }
    public object? Actions { get => GetValue(ActionsProperty); set => SetValue(ActionsProperty, value); }
    protected override Type StyleKeyOverride => typeof(Card);
}

/// <summary>A row with a title and hint on the left and a control (toggle, button) on the right.</summary>
public class SettingRow : ContentControl
{
    public static readonly StyledProperty<string?> TitleProperty = AvaloniaProperty.Register<SettingRow, string?>(nameof(Title));
    public static readonly StyledProperty<string?> HintProperty = AvaloniaProperty.Register<SettingRow, string?>(nameof(Hint));
    public string? Title { get => GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string? Hint { get => GetValue(HintProperty); set => SetValue(HintProperty, value); }
    protected override Type StyleKeyOverride => typeof(SettingRow);
}
