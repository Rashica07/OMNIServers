using CraftPanel.Core.Runtime;

namespace CraftPanel.App.Services;

/// <summary>Turns join/leave/chat/advancement events into in-app toasts (and, when the window is in the background, the tray notification).</summary>
public static class PlayerNotifier
{
    /// <summary>Set by the main window: is the app in the foreground?</summary>
    public static Func<bool> IsAppActive { get; set; } = () => true;
    /// <summary>Set by the tray: shows an out-of-app notice.</summary>
    public static Action<string, string, Guid>? Background { get; set; }

    public static void Handle(ServerRuntime rt, LiveEvent ev, int online)
    {
        var s = AppServices.Settings;
        (string title, string icon)? n = ev switch
        {
            LiveEvent.Join j when s.NotifyJoins => ($"{j.Player} joined", "user-plus"),
            LiveEvent.Leave l when s.NotifyJoins => ($"{l.Player} left", "user"),
            LiveEvent.Advancement a when s.NotifyJoins => ($"{a.Player} got [{a.Title}]", "sparkle"),
            LiveEvent.Chat c when s.NotifyChat => ($"{c.From}: {c.Text}", "message-circle"),
            _ => null,
        };
        if (n is not { } m) return;
        var sub = $"{rt.DisplayName} · {online} online";
        if (IsAppActive()) ToastService.Shared.Show(m.title, sub, m.icon, "accent", rt.ServerId);
        else Background?.Invoke(m.title, sub, rt.ServerId);
    }
}
