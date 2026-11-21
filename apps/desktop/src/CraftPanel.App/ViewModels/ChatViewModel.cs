using System.Collections.ObjectModel;
using Avalonia.Media;
using CraftPanel.App.Services;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

public sealed class ChatRowViewModel(ChatEntry e)
{
    public ChatEntry Entry { get; } = e;
    public string Who => Entry.Kind == ChatKind.Broadcast ? $"[{Entry.Who}]" : Entry.Who;
    public string Text => Entry.Text;
    public string Time => Entry.Date.ToString("HH:mm");
    public bool IsMessage => Entry.Kind is ChatKind.Chat or ChatKind.Mine or ChatKind.Broadcast;
    public bool IsEvent => !IsMessage;
    public bool IsMine => Entry.Kind == ChatKind.Mine;
    public bool IsBroadcast => Entry.Kind == ChatKind.Broadcast;
    public string Initial => (Entry.Who.TrimStart('.', '*') is { Length: > 0 } n ? n[..1] : "?").ToUpperInvariant();
    public IBrush Avatar => IsBroadcast ? Brushes.Transparent : PlayerColors.For(Entry.Who);
    public string EventIcon => Entry.Kind switch { ChatKind.Join => "user-plus", ChatKind.Leave => "user", _ => "sparkle" };
    public string EventTone => Entry.Kind switch { ChatKind.Join => "ok", ChatKind.Advancement => "warn", _ => "idle" };
    public string EventText => Entry.Kind == ChatKind.Advancement ? $"{Entry.Who} made the advancement {Entry.Text}" : $"{Entry.Who} {Entry.Text}";
}

public static class PlayerColors
{
    /// <summary>A stable colour per name — no skin service is contacted.</summary>
    public static IBrush For(string name)
    {
        uint h = 5381;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(name.ToLowerInvariant())) h = h * 33 + b;
        return new SolidColorBrush(Hsv((h % 360), 0.55, 0.78));
    }

    public static Color Hsv(double h, double s, double v)
    {
        var c = v * s; var x = c * (1 - Math.Abs(h / 60 % 2 - 1)); var m = v - c;
        var (r, g, b) = h switch { < 60 => (c, x, 0d), < 120 => (x, c, 0d), < 180 => (0d, c, x), < 240 => (0d, x, c), < 300 => (x, 0d, c), _ => (c, 0d, x) };
        return Color.FromRgb((byte)((r + m) * 255), (byte)((g + m) * 255), (byte)((b + m) * 255));
    }
}

public sealed class OnlinePlayer(string name)
{
    public string Name { get; } = name;
    public string Initial => (Name.TrimStart('.', '*') is { Length: > 0 } n ? n[..1] : "?").ToUpperInvariant();
    public IBrush Avatar => PlayerColors.For(Name);
}

public sealed class ChatViewModel : ViewModelBase, IDisposable
{
    readonly ServerItemViewModel _server;
    string _draft = "", _error = "";

    public ServerRuntime Runtime => _server.Runtime;
    public ObservableCollection<ChatRowViewModel> Messages { get; } = [];
    public ObservableCollection<OnlinePlayer> Online { get; } = [];

    public ChatViewModel(ServerItemViewModel server)
    {
        _server = server;
        foreach (var e in Runtime.Chat()) Messages.Add(new ChatRowViewModel(e));
        RefreshOnline();
        Runtime.ChatAdded += OnChat;
        Runtime.PlayersChanged += OnPlayers;
        Runtime.StateChanged += OnState;
        SendCommand = new RelayCommand(Send, () => Runtime.IsRunning && Draft.Trim().Length > 0);
        _ = Runtime.LoadChatHistoryAsync(server.Record.Path);
    }

    public string Draft { get => _draft; set { if (Set(ref _draft, value)) SendCommand.RaiseCanExecuteChanged(); } }
    public string Error { get => _error; set { Set(ref _error, value); Raise(nameof(HasError)); } }
    public bool HasError => _error.Length > 0;
    public bool IsRunning => Runtime.IsRunning;
    public bool IsEmpty => Messages.Count == 0;
    public string StatusText => Runtime.IsRunning ? (Online.Count == 1 ? "1 online" : $"{Online.Count} online") : "Server offline";
    public string Placeholder => Runtime.IsRunning ? $"Message everyone as <{AppServices.Settings.EffectiveChatName}>…" : "Start the server to chat";
    public RelayCommand SendCommand { get; }

    void OnChat(ChatEntry e) => Ui.Post(() =>
    {
        if (Messages.Any(m => m.Entry.Id == e.Id && m.Entry.Text == e.Text)) return;
        Messages.Add(new ChatRowViewModel(e));
        while (Messages.Count > ServerRuntime.ChatCapacity) Messages.RemoveAt(0);
        Raise(nameof(IsEmpty));
    });

    void OnPlayers() => Ui.Post(RefreshOnline);

    void OnState() => Ui.Post(() =>
    {
        Raise(nameof(IsRunning)); Raise(nameof(StatusText)); Raise(nameof(Placeholder)); SendCommand.RaiseCanExecuteChanged();
        if (Messages.Count == 0) foreach (var e in Runtime.Chat()) Messages.Add(new ChatRowViewModel(e));
    });

    void RefreshOnline()
    {
        Online.Clear();
        if (Runtime.IsRunning) foreach (var n in Runtime.Online()) Online.Add(new OnlinePlayer(n));
        Raise(nameof(StatusText));
    }

    void Send()
    {
        var text = Draft.Trim();
        if (text.Length == 0 || !Runtime.IsRunning) return;
        try { Runtime.SendChat(text, AppServices.Settings.EffectiveChatName); Draft = ""; Error = ""; }
        catch (Exception e) { Error = e.Message; }
    }

    public void Dispose()
    {
        Runtime.ChatAdded -= OnChat; Runtime.PlayersChanged -= OnPlayers; Runtime.StateChanged -= OnState;
    }
}
