using System.Globalization;
using Avalonia.Data.Converters;

namespace CraftPanel.App.ViewModels;

public static class Tones
{
    /// <summary>true → "ok", false → "idle".</summary>
    public static readonly IValueConverter RunningTone = new FuncValueConverter<bool, string>(b => b ? "ok" : "idle");
}
