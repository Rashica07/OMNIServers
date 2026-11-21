using Avalonia;
using Avalonia.Media;

namespace CraftPanel.App.Services;

/// <summary>One complete set of <c>--cp-*</c> colour tokens (from the Tauri app's index.css / theme.ts).</summary>
public sealed record Palette(
    uint Bg, uint Surface, uint Surface2, uint Surface3, uint Surface4, uint Console,
    uint LineSoft, uint Line, uint LineStrong,
    uint Ink, uint InkDim, uint InkFaint, uint InkGhost,
    uint Accent, uint AccentHover, uint AccentPress, uint AccentSoft, uint AccentMuted, uint OnAccent,
    uint Ok, uint OkSoft, uint OkMuted, uint Warn, uint WarnSoft, uint WarnMuted, uint Bad, uint BadSoft, uint BadMuted, uint Info, uint InfoSoft, uint InfoMuted,
    bool IsLight = false)
{
    // Windows values from the Tauri build: a visible 1 px stroke (Fluent likes one).
    // OMNI look: warm near-black, ivory ink, Imperial Crimson for the primary action, Solar Gold as the rare highlight.
    public static readonly Palette Dark = new(
        0x0f0e0d, 0x171513, 0x1c1a17, 0x221f1c, 0x2b2824, 0x0b0a09,
        0x24211e, 0x34302b, 0x484239,
        0xe8dcc8, 0xb9af9f, 0x948b7c, 0x6f685c,
        0xc83246, 0xd94459, 0xa8283a, 0xf0707f, 0x2a1216, 0xffffff,
        0x5fbf7f, 0x8fd6a5, 0x12241a, 0xe8b44f, 0xf0cb85, 0x2a2010, 0xf0707f, 0xf6a0aa, 0x2b1214, 0x6aa6e8, 0x9cc3f0, 0x0d1b2c);

    public static readonly Palette Light = new(
        0xfaf6ee, 0xffffff, 0xf4eee2, 0xede3d0, 0xe0d3bc, 0x1e1a16,
        0xece4d4, 0xddd2bc, 0xc7b99d,
        0x1e1a16, 0x4a4137, 0x625849, 0x9a8f7e,
        0xc83246, 0xa8283a, 0x8f2230, 0xa8283a, 0xfbe9ec, 0xffffff,
        0x176a35, 0x115227, 0xe4f2e8, 0x8a5f00, 0x6e4c00, 0xfaf0d6, 0xb0243a, 0x8a1c2e, 0xfbe6ea, 0x1f6fc4, 0x17558f, 0xe9f1fb, true);

    public static readonly Palette Midnight = Dark with
    {
        Bg = 0x0a0e17, Surface = 0x10151f, Surface2 = 0x161c28, Surface3 = 0x1c2330, Surface4 = 0x242c3b, Console = 0x070a10,
        LineSoft = 0x1a212c, Line = 0x252d3a, LineStrong = 0x34404f, Ink = 0xeef1f5, InkDim = 0xa8b0bd, InkFaint = 0x838da0, InkGhost = 0x5f6878,
        Accent = 0x3ea6ff, AccentHover = 0x5cb6ff, AccentPress = 0x2b8fe0, AccentSoft = 0x8fcaff, AccentMuted = 0x0d2438, OnAccent = 0x001322,
    };

    public static readonly Palette Sunset = Dark with
    {
        Bg = 0x150a12, Surface = 0x1e0f1a, Surface2 = 0x271521, Surface3 = 0x301c29, Surface4 = 0x3a2333, Console = 0x100810,
        LineSoft = 0x241522, Line = 0x33202e, LineStrong = 0x452c40, Ink = 0xf5eef2, InkDim = 0xc2adbd, InkFaint = 0xa08d9b, InkGhost = 0x7a6b75,
        Accent = 0xe8b44f, AccentHover = 0xf0c46a, AccentPress = 0xcf9b36, AccentSoft = 0xf0cb85, AccentMuted = 0x2e2210, OnAccent = 0x1a1200,
    };

    public static Palette ByName(string? name) => name switch { "light" => Light, "midnight" => Midnight, "sunset" => Sunset, _ => Dark };
    public static readonly string[] Names = ["dark", "light", "midnight", "sunset"];

    static Color C(uint rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    /// <summary>Raised after a palette is applied (views that cached brushes rebuild).</summary>
    public static event Action? Changed;

    /// <summary>Writes every token into Application resources; <c>DynamicResource</c> users update live.</summary>
    public void Apply(Application app)
    {
        void Set(string key, uint rgb, double opacity = 1)
        {
            var c = C(rgb);
            app.Resources[$"{key}.Color"] = c;
            app.Resources[key] = new SolidColorBrush(c, opacity);
        }
        Set("Cp.Bg", Bg); Set("Cp.Surface", Surface); Set("Cp.Surface2", Surface2); Set("Cp.Surface3", Surface3); Set("Cp.Surface4", Surface4); Set("Cp.Console", Console);
        Set("Cp.LineSoft", LineSoft); Set("Cp.Line", Line); Set("Cp.LineStrong", LineStrong);
        Set("Cp.Ink", Ink); Set("Cp.InkDim", InkDim); Set("Cp.InkFaint", InkFaint); Set("Cp.InkGhost", InkGhost);
        Set("Cp.Accent", Accent); Set("Cp.AccentHover", AccentHover); Set("Cp.AccentPress", AccentPress); Set("Cp.AccentSoft", AccentSoft);
        Set("Cp.AccentMuted", AccentMuted); Set("Cp.OnAccent", OnAccent); Set("Cp.AccentLine", Accent, 0.25); Set("Cp.AccentRing", Accent, 0.4);
        Set("Cp.Ok", Ok); Set("Cp.OkSoft", OkSoft); Set("Cp.OkMuted", OkMuted);
        Set("Cp.Warn", Warn); Set("Cp.WarnSoft", WarnSoft); Set("Cp.WarnMuted", WarnMuted);
        Set("Cp.Bad", Bad); Set("Cp.BadSoft", BadSoft); Set("Cp.BadMuted", BadMuted);
        Set("Cp.Info", Info); Set("Cp.InfoSoft", InfoSoft); Set("Cp.InfoMuted", InfoMuted);
        Set("Cp.Ok12", Ok, 0.12); Set("Cp.Warn12", Warn, 0.12); Set("Cp.Bad12", Bad, 0.12); Set("Cp.Info12", Info, 0.12);
        Set("Cp.Bad35", Bad, 0.35); Set("Cp.Warn35", Warn, 0.35);
        // Fluent's own accent, so focus rings, selection and checked toggles follow the theme.
        app.Resources["SystemAccentColor"] = C(Accent);
        app.Resources["SystemAccentColorLight1"] = C(AccentHover);
        app.Resources["SystemAccentColorLight2"] = C(AccentSoft);
        app.Resources["SystemAccentColorDark1"] = C(AccentPress);
        app.RequestedThemeVariant = IsLight ? Avalonia.Styling.ThemeVariant.Light : Avalonia.Styling.ThemeVariant.Dark;
        Changed?.Invoke();
    }
}
