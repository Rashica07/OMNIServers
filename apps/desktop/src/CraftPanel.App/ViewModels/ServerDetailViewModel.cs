using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Network;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Runtime;

namespace CraftPanel.App.ViewModels;

public enum ServerSection { Performance, Console, Chat, Network, Players, Map, Settings, Addons, Mods, Worlds, Backups, Files }

public static class ServerSectionExt
{
    public static string Label(this ServerSection s) => s == ServerSection.Addons ? "Add-ons" : s.ToString();

    public static string Icon(this ServerSection s) => s switch
    {
        ServerSection.Performance => "activity", ServerSection.Console => "terminal", ServerSection.Chat => "message-circle", ServerSection.Network => "signal", ServerSection.Players => "users",
        ServerSection.Map => "map", ServerSection.Settings => "sliders", ServerSection.Addons => "sparkle", ServerSection.Mods => "package",
        ServerSection.Worlds => "globe", ServerSection.Backups => "archive", _ => "folder",
    };

    /// <summary>Bedrock has no RCON, no Modrinth ecosystem and a different world format; Mods only shows for loaders that load a mods/ folder.</summary>
    public static bool AppliesTo(this ServerSection s, ServerType t)
    {
        if (s == ServerSection.Mods) return t.UsesModsFolder();
        if (s == ServerSection.Map) return BlueMapSupported(t);
        if (!t.IsBedrock() && !t.IsOmniHost()) return true;   // OMNIHost: no Minecraft-console features (players tab, chat, worlds, addons)
        return s is not (ServerSection.Players or ServerSection.Addons or ServerSection.Worlds or ServerSection.Chat);
    }

    static bool BlueMapSupported(ServerType t) => Core.Addons.BlueMap.Supported(t);
}

public sealed class SectionTab(ServerSection section, Action<ServerSection> select) : ViewModelBase
{
    bool _active;
    public ServerSection Section { get; } = section;
    public string Label => Section.Label();
    public string Icon => Section.Icon();
    public bool IsActive { get => _active; set => Set(ref _active, value); }
    public RelayCommand SelectCommand { get; } = new(() => select(section));
}

/// <summary>One server's page: header (name, status, start/stop) and the tab strip with the active section's view-model.</summary>
public sealed class ServerDetailViewModel : ViewModelBase
{
    readonly MainViewModel _main;
    ViewModelBase? _section;
    ServerSection _current = ServerSection.Console;

    public ServerItemViewModel Server { get; }
    public ObservableCollection<SectionTab> Tabs { get; } = [];

    public ServerDetailViewModel(ServerItemViewModel server, MainViewModel main)
    {
        Server = server; _main = main;
        foreach (var s in Enum.GetValues<ServerSection>().Where(s => s.AppliesTo(server.Record.ServerType)))
            Tabs.Add(new SectionTab(s, Select));
        StartCommand = new AsyncCommand(StartAsync, () => Server.CanStart);
        StopCommand = new RelayCommand(() => { try { Server.Runtime.Stop(); } catch (Exception e) { ToastService.Shared.Error(e.Message); } }, () => Server.CanStop);
        RestartCommand = new AsyncCommand(RestartAsync, () => Server.IsRunning);
        KillCommand = new RelayCommand(() => Server.Runtime.Kill(), () => Server.IsRunning);
        OpenFolderCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(Server.Record.Path));
        CopyAddressCommand = new RelayCommand(() => { Dialogs.Current.CopyText(Address); ToastService.Shared.Show("Address copied", Address, "copy", "ok", null, 3); });
        JoinCommand = new RelayCommand(() =>
        {
            // Java servers: hand over to OMNI Launcher, which opens straight onto the server.
            if (!Server.Record.ServerType.IsBedrock() && OmniLauncherLink.CanPlay(Server.Record.McVersion))
            {
                var pub = TunnelManager.Shared.Status(Server.Record.Id) is { Running: true, Address: { Length: > 0 } a } ? a : null;
                if (OmniLauncherLink.Play(Server.Record.Name, $"localhost:{ServerPort}", pub, Server.Record.McVersion!))
                {
                    ToastService.Shared.Show("Opening OMNI Launcher", "Pick an instance and press Play.", "play", "ok", null, 4);
                    return;
                }
            }
            var plan = JoinLink.Plan(Server.Record.ServerType, Server.Record.Name, Address);
            if (!plan.Bedrock) Dialogs.Current.CopyText(plan.Address);
            var opened = JoinLink.Open(plan);
            ToastService.Shared.Show(plan.Bedrock ? (opened ? "Opening Minecraft" : "Couldn't open Minecraft") : "Address copied",
                plan.Bedrock ? "The server is added to your list: pick it and join." : (opened ? "Minecraft is opening. Choose Multiplayer, Add Server, and paste." : "Open Minecraft, choose Multiplayer, Add Server, and paste."),
                "play", opened || !plan.Bedrock ? "ok" : "warn", null, 5);
        });
        InviteCommand = new RelayCommand(() => { Dialogs.Current.CopyText(LaunchInfo.InviteText(Server.Record.Name, Address, Server.Record.McVersion)); ToastService.Shared.Show("Invite copied", "Paste it into a message to your friends.", "copy", "ok", null, 3); });
        ChangeVersionCommand = new AsyncCommand(() => Dialogs.Current.ShowChangeVersionAsync(Server.Record), () => !Server.IsRunning && !Server.Record.ServerType.IsBedrock());
        Server.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ServerItemViewModel.IsRunning) or nameof(ServerItemViewModel.Status))
            {
                StartCommand.RaiseCanExecuteChanged(); StopCommand.RaiseCanExecuteChanged(); RestartCommand.RaiseCanExecuteChanged();
                KillCommand.RaiseCanExecuteChanged(); ChangeVersionCommand.RaiseCanExecuteChanged();
                Raise(nameof(NeedsEula)); Raise(nameof(ShowLaunch)); Raise(nameof(LaunchSteps)); Raise(nameof(HasAddress));
            }
        };
        Select(ServerSection.Console);
    }

    public ViewModelBase? Section { get => _section; private set => Set(ref _section, value); }
    public ServerSection Current => _current;

    public AsyncCommand StartCommand { get; }
    public RelayCommand StopCommand { get; }
    public AsyncCommand RestartCommand { get; }
    public RelayCommand KillCommand { get; }
    public RelayCommand OpenFolderCommand { get; }
    public AsyncCommand ChangeVersionCommand { get; }

    public RelayCommand CopyAddressCommand { get; }
    public RelayCommand InviteCommand { get; }
    public RelayCommand JoinCommand { get; }

    /// <summary>The address friends on this network type into Minecraft (the Network tab has tunnel and public options).</summary>
    int ServerPort => Server.Record.ServerType.IsOmniHost() ? OmniHostAdapter.Port(Server.Record.Path) : Properties.Load(Server.Record.Path).GetInt("server-port", Server.Record.ServerType.IsBedrock() ? 19132 : 25565);
    public string Address => LaunchInfo.Address(Net.LanIp(), ServerPort);
    public bool HasAddress => Server.IsRunning;

    public bool ShowLaunch => Server.Status is ServerStatus.Starting or ServerStatus.Running;
    public IReadOnlyList<LaunchStep> LaunchSteps => LaunchInfo.Steps(Server.Status);

    public bool NeedsEula => Server.Runtime.NeedsEula;

    public void Select(ServerSection s)
    {
        if (!s.AppliesTo(Server.Record.ServerType)) s = ServerSection.Console;
        _current = s;
        foreach (var t in Tabs) t.IsActive = t.Section == s;
        Section = SectionFactory.Create(s, Server, this);
        Raise(nameof(Current));
    }

    async Task StartAsync()
    {
        var rec = Server.Record;
        var problem = await JavaCheck.CheckAsync(rec);
        if (problem is not null && !await JavaCheck.OfferFixAsync(rec, problem)) return;
        try { Server.Runtime.Start(rec); AppServices.Store.Update(rec); }
        catch (Core.Sharing.LeaseHeldException held)
        {
            // Another PC is running this shared server. Starting anyway is only right if that PC is really off.
            if (!await Dialogs.Current.ConfirmAsync("Another PC is running this server", $"{held.Message}\n\nStarting it on two PCs at once can corrupt the world.", "Start anyway", true)) return;
            try { Server.Runtime.Start(rec, forceShareLease: true); AppServices.Store.Update(rec); }
            catch (Exception e) { Server.Runtime.Push(Core.Runtime.LogStream.System, e.Message); ToastService.Shared.Error(e.Message); }
        }
        catch (Exception e) { Server.Runtime.Push(Core.Runtime.LogStream.System, e.Message); ToastService.Shared.Error(e.Message); }
    }

    async Task RestartAsync()
    {
        if (!Server.IsRunning) return;
        Server.Runtime.Stop();
        for (var i = 0; i < 120 && Server.IsRunning; i++) await Task.Delay(500);
        await StartAsync();
    }
}
