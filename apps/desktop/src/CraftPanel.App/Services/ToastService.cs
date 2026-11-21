using System.Collections.ObjectModel;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Services;

public sealed class ToastItem(string title, string subtitle, string icon, string tone, Guid? serverId)
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Title { get; } = title;
    public string Subtitle { get; } = subtitle;
    public string Icon { get; } = icon;
    public string Tone { get; } = tone;
    public Guid? ServerId { get; } = serverId;
    public bool HasSubtitle => Subtitle.Length > 0;
    /// <summary>Icon colour follows the tone: green for done, gold for warnings, red for errors, crimson otherwise.</summary>
    public Avalonia.Media.IBrush IconBrush
    {
        get
        {
            var key = Tone switch { "ok" => "Cp.Ok", "warn" => "Cp.Warn", "bad" or "error" => "Cp.Bad", _ => "Cp.Accent" };
            return Avalonia.Application.Current?.TryGetResource(key, null, out var r) == true && r is Avalonia.Media.IBrush b ? b : Avalonia.Media.Brushes.Gray;
        }
    }
}

/// <summary>In-app notices (join/leave, errors, "done") shown as small cards in the window corner.</summary>
public sealed class ToastService
{
    public static ToastService Shared { get; } = new();
    public ObservableCollection<ToastItem> Items { get; } = [];

    public void Show(string title, string subtitle = "", string icon = "info", string tone = "info", Guid? serverId = null, int seconds = 4)
    {
        Ui.Post(() =>
        {
            var t = new ToastItem(title, subtitle, icon, tone, serverId);
            Items.Add(t);
            while (Items.Count > 4) Items.RemoveAt(0);
            _ = Task.Delay(TimeSpan.FromSeconds(seconds)).ContinueWith(_ => Ui.Post(() => Items.Remove(t)));
        });
    }

    public void Error(string message) => Show(message, "", "alert-octagon", "bad", null, 7);
    public void Dismiss(ToastItem t) => Items.Remove(t);
}
