using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

public sealed class PlayerRow(string name, string detail = "")
{
    public string Name { get; } = name;
    public string Detail { get; } = detail;
    public string Initial => (Name.TrimStart('.', '*') is { Length: > 0 } n ? n[..1] : "?").ToUpperInvariant();
    public Avalonia.Media.IBrush Avatar => PlayerColors.For(Name);
    public bool HasDetail => Detail.Length > 0;
}

public sealed class SeenRow(PlayerStats p)
{
    public string Name { get; } = p.Name;
    public string Initial => (Name.TrimStart('.', '*') is { Length: > 0 } n ? n[..1] : "?").ToUpperInvariant();
    public Avalonia.Media.IBrush Avatar => PlayerColors.For(Name);
    public bool Online { get; } = p.Online;
    public string Detail { get; } = $"{PlayerAnalytics.FormatDuration(p.TotalTime)} played · {p.Sessions} session{(p.Sessions == 1 ? "" : "s")} · " + (p.Online ? "online now" : "last seen " + p.LastSeen.ToString("d MMM, HH:mm"));
}

public sealed class PlayersViewModel : ViewModelBase, IDisposable
{
    readonly ServerItemViewModel _server;
    string _newName = "", _note = "";

    public ObservableCollection<PlayerRow> Online { get; } = [];
    public ObservableCollection<PlayerRow> Ops { get; } = [];
    public ObservableCollection<PlayerRow> Whitelist { get; } = [];
    public ObservableCollection<PlayerRow> Banned { get; } = [];
    public ObservableCollection<SeenRow> Seen { get; } = [];
    public bool NoSeen => Seen.Count == 0;
    public static string[] Gamemodes { get; } = ["survival", "creative", "adventure", "spectator"];

    ServerRecord R => _server.Record;
    public ServerRuntime Runtime => _server.Runtime;

    public PlayersViewModel(ServerItemViewModel server)
    {
        _server = server;
        KickCommand = new AsyncCommand(p => Act("kick", p));
        BanCommand = new AsyncCommand(p => Act("ban", p));
        OpCommand = new AsyncCommand(p => Act("op", p));
        DeopCommand = new AsyncCommand(p => Act("deop", p));
        GamemodeCommand = new AsyncCommand(async p => { if (p is (string who, string mode)) await ActArg("gamemode", who, mode); });
        AddWhitelistCommand = new AsyncCommand(() => AddNew("whitelist-add"));
        AddOpCommand = new AsyncCommand(() => AddNew("op"));
        AddBanCommand = new AsyncCommand(() => AddNew("ban"));
        UnOpCommand = new AsyncCommand(p => Remove(p, "deop", "ops.json"));
        UnWhitelistCommand = new AsyncCommand(p => Remove(p, "whitelist-remove", "whitelist.json"));
        PardonCommand = new AsyncCommand(p => Remove(p, "pardon", "banned-players.json"));
        RefreshCommand = new RelayCommand(Reload);
        Runtime.PlayersChanged += OnChanged; Runtime.StateChanged += OnChanged;
        Reload();
    }

    public string NewName { get => _newName; set => Set(ref _newName, value); }
    public string Note { get => _note; set { Set(ref _note, value); Raise(nameof(HasNote)); } }
    public bool HasNote => _note.Length > 0;
    public bool IsRunning => Runtime.IsRunning;
    public bool OnlineEmpty => Online.Count == 0;
    public string OnlineTitle => IsRunning ? $"Online now ({Online.Count})" : "Online now";

    public AsyncCommand KickCommand { get; }
    public AsyncCommand BanCommand { get; }
    public AsyncCommand OpCommand { get; }
    public AsyncCommand DeopCommand { get; }
    public AsyncCommand GamemodeCommand { get; }
    public AsyncCommand AddWhitelistCommand { get; }
    public AsyncCommand AddOpCommand { get; }
    public AsyncCommand AddBanCommand { get; }
    public AsyncCommand UnOpCommand { get; }
    public AsyncCommand UnWhitelistCommand { get; }
    public AsyncCommand PardonCommand { get; }
    public RelayCommand RefreshCommand { get; }

    void OnChanged() => Ui.Post(Reload);

    public void Reload()
    {
        Online.Clear();
        if (IsRunning) foreach (var n in Runtime.Online()) Online.Add(new PlayerRow(n));
        Fill(Ops, "ops.json", e => $"level {e["level"]?.GetValue<int>() ?? 4}");
        Fill(Whitelist, "whitelist.json", _ => "");
        Fill(Banned, "banned-players.json", e => e["reason"]?.GetValue<string>() ?? "");
        Raise(nameof(IsRunning)); Raise(nameof(OnlineEmpty)); Raise(nameof(OnlineTitle));
        _ = LoadSeenAsync();
    }

    async Task LoadSeenAsync()
    {
        var running = IsRunning;
        var list = await Task.Run(() => PlayerAnalytics.Load(R.Path, running));
        Ui.Post(() => { Seen.Clear(); foreach (var p in list.Take(50)) Seen.Add(new SeenRow(p)); Raise(nameof(NoSeen)); });
    }

    void Fill(ObservableCollection<PlayerRow> target, string file, Func<JsonNode, string> detail)
    {
        target.Clear();
        try
        {
            var path = Path.Combine(R.Path, file);
            if (!File.Exists(path)) return;
            foreach (var e in JsonNode.Parse(File.ReadAllText(path))!.AsArray())
                if (e?["name"]?.GetValue<string>() is { } n) target.Add(new PlayerRow(n, detail(e)));
        }
        catch { }
    }

    Task Act(string action, object? p) => p is string who ? ActArg(action, who, null) : Task.CompletedTask;

    async Task ActArg(string action, string who, string? arg)
    {
        if (!IsRunning) { Note = "Start the server to do that."; return; }
        try
        {
            var reply = await RconService.Shared.PlayerActionAsync(R, action, who, arg);
            Note = reply.Trim();
            ToastService.Shared.Show(reply.Trim().Length > 0 ? reply.Trim() : $"{action} {who}", R.Name, "check-circle", "ok");
            await Task.Delay(400);
            Ui.Post(Reload);
        }
        catch (Exception e) { Note = e.Message; ToastService.Shared.Error(e.Message); }
    }

    async Task AddNew(string action)
    {
        var name = NewName.Trim();
        if (!LiveEvent.IsValidName(name)) { Note = "Enter a valid player name (letters, numbers, underscore)."; return; }
        await ActArg(action, name, null);
        NewName = "";
    }

    async Task Remove(object? p, string action, string file)
    {
        if (p is not string name) return;
        if (IsRunning) { await ActArg(action, name, null); return; }
        try
        {
            var path = Path.Combine(R.Path, file);
            var arr = JsonNode.Parse(File.ReadAllText(path))!.AsArray();
            foreach (var e in arr.Where(e => string.Equals(e?["name"]?.GetValue<string>(), name, StringComparison.OrdinalIgnoreCase)).ToList()) arr.Remove(e);
            AppPaths.WriteAtomic(path, arr.ToJsonString(new() { WriteIndented = true }));
            Reload();
        }
        catch (Exception e) { Note = e.Message; }
    }

    public void Dispose() { Runtime.PlayersChanged -= OnChanged; Runtime.StateChanged -= OnChanged; }
}
