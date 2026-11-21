using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Network;
using CraftPanel.Core.Addons;
using CraftPanel.Core.Sharing;

namespace CraftPanel.App.ViewModels;

public sealed class NetworkViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    string _publicIp = "", _tunnel, _upnpStatus = "", _firewallStatus = "", _note = "";
    int _port;
    bool _busy;

    ServerRecord R => _server.Record;

    public NetworkViewModel(ServerItemViewModel server)
    {
        _server = server;
        _tunnel = R.ManualTunnelAddress ?? "";
        _port = Properties.Load(R.Path).GetInt("server-port", R.ServerType.IsBedrock() ? 19132 : 25565);
        CopyCommand = new RelayCommand(o => { if (o is string s && s.Length > 0) { Dialogs.Current.CopyText(s); ToastService.Shared.Show("Copied", s, "copy", "ok", null, 2); } });
        PublicIpCommand = new AsyncCommand(FetchPublicIpAsync);
        SaveTunnelCommand = new RelayCommand(SaveTunnel);
        UpnpForwardCommand = new AsyncCommand(UpnpForwardAsync, () => !_busy);
        UpnpRemoveCommand = new AsyncCommand(UpnpRemoveAsync, () => !_busy);
        UpnpCheckCommand = new AsyncCommand(UpnpCheckAsync, () => !_busy);
        FirewallCommand = new AsyncCommand(AddFirewallAsync);
        Share = new ShareCardViewModel(server);
        Ports = new PortRulesViewModel(server);
        CopyInviteCommand = new RelayCommand(() => { Dialogs.Current.CopyText(InviteText); ToastService.Shared.Show("Invite copied", "Paste it into a message to your friends.", "copy", "ok", null, 3); });
        CopyNetworkRequestCommand = new RelayCommand(() => { Dialogs.Current.CopyText(NetworkAccessRequest); ToastService.Shared.Show("Request copied", "Give this to whoever manages the network.", "copy", "ok", null, 3); });
        TestServerCommand = new AsyncCommand(TestServerAsync);
        StartTunnelCommand = new AsyncCommand(StartTunnelAsync, () => !TunnelRunning);
        StopTunnelCommand = new RelayCommand(() => TunnelManager.Shared.Stop(R.Id), () => TunnelRunning);
        EnableCrossplayCommand = new AsyncCommand(EnableCrossplayAsync, () => !_xpBusy);
        DisableCrossplayCommand = new AsyncCommand(DisableCrossplayAsync, () => !_xpBusy);
        ForwardBedrockCommand = new AsyncCommand(ForwardBedrockAsync);
        BedrockFirewallCommand = new AsyncCommand(BedrockFirewallAsync);
        UpdateGeyserCommand = new AsyncCommand(UpdateGeyserAsync, () => !_xpBusy);
        AllowAnyoneCommand = new RelayCommand(AllowAnyone);
        SetBedrockPublicAddressCommand = new AsyncCommand(SetBedrockPublicAddressAsync);
        // the tunnel manager outlives this view: hold the view-model weakly and unhook once it's gone
        var weak = new WeakReference<NetworkViewModel>(this);
        Action<Guid>? hook = null;
        hook = id => { if (weak.TryGetTarget(out var vm)) { if (id == vm.R.Id) Ui.Post(vm.RefreshTunnel); } else TunnelManager.Shared.Changed -= hook; };
        TunnelManager.Shared.Changed += hook;
        RefreshCrossplay();
        _ = CheckFirewallAsync();
    }

    public ShareCardViewModel Share { get; }
    public PortRulesViewModel Ports { get; }
    public RelayCommand CopyInviteCommand { get; }
    public RelayCommand CopyNetworkRequestCommand { get; }
    public AsyncCommand TestServerCommand { get; }
    string _testResult = "";
    public string TestResult { get => _testResult; private set { Set(ref _testResult, value); Raise(nameof(HasTestResult)); } }
    public bool HasTestResult => _testResult.Length > 0;
    public string NetworkAccessRequest => LanTools.NetworkAccessRequest(_port, IsBedrock);

    /// <summary>A message to paste to friends: what to type and which Minecraft to use.</summary>
    public string InviteText
    {
        get
        {
            var how = TunnelAddress.Length > 0 ? "Works from anywhere while I have the tunnel on."
                : R.ManualTunnelAddress is { Length: > 0 } ? "Works from anywhere."
                : UpnpStatus.Contains("forwarded") ? "Works from anywhere."
                : "Works when you're on the same Wi-Fi or network as me.";
            var game = IsBedrock ? $"Minecraft Bedrock (port {_port})" : $"Minecraft Java Edition{(R.McVersion is { Length: > 0 } v ? " " + v : "")}";
            var bedrock = !IsBedrock && XpOn ? $"\nOn Bedrock (phone, console, Windows store): Servers → Add Server → {XpAddress}. {BedrockNetwork.TrustPromptNote}" : "";
            return $"Join my Minecraft server \"{R.Name}\"!\nAddress: {Recommended}\nGame: {game}\n{how}\nIn Minecraft: Multiplayer → Add Server → paste the address.{bedrock}";
        }
    }

    /// <summary>Does anything answer on this PC's own network address? Tells "the server isn't running" from "something blocks it".</summary>
    async Task TestServerAsync()
    {
        TestResult = "Checking…";
        var host = Net.LanIp() ?? "127.0.0.1";
        var local = await LanTools.CanConnectAsync("127.0.0.1", _port);
        var lan = local && await LanTools.CanConnectAsync(host, _port);
        TestResult = !local ? $"Nothing is answering on port {_port}. Start the server first (and wait until it says Running)."
            : lan ? $"The server answers on {host}:{_port}. Friends on your network can use that address; if they still can't connect, the school or home network may be blocking devices from reaching each other — try the free tunnel."
            : $"The server runs, but isn't answering on {host}:{_port} — Windows Firewall is probably blocking it. Use 'Allow through Windows Firewall' below, or ask IT to allow port {_port}.";
    }

    public int Port => _port;
    public string LanAddress => Net.LanIp() is { } ip ? $"{ip}:{_port}" : "";
    public string LocalAddress => $"localhost:{_port}";
    public string PublicIp { get => _publicIp; private set { Set(ref _publicIp, value); Raise(nameof(PublicAddress)); Raise(nameof(HasPublicIp)); Raise(nameof(XpAddress)); Raise(nameof(XpAddressLabel)); } }
    public bool HasPublicIp => _publicIp.Length > 0;
    public string PublicAddress => _publicIp.Length == 0 ? "" : _publicIp.Contains(':') && !_publicIp.Contains("::") ? _publicIp : $"{_publicIp}:{_port}";
    public string Tunnel { get => _tunnel; set => Set(ref _tunnel, value); }
    public string UpnpStatus { get => _upnpStatus; private set => Set(ref _upnpStatus, value); }
    public string FirewallStatus { get => _firewallStatus; private set { Set(ref _firewallStatus, value); Raise(nameof(HasFirewallStatus)); } }
    public bool HasFirewallStatus => _firewallStatus.Length > 0;
    public bool FirewallSupported => Firewall.Supported;
    public string Note { get => _note; private set { Set(ref _note, value); Raise(nameof(HasNote)); } }
    public bool HasNote => _note.Length > 0;
    public bool IsBedrock => R.ServerType.IsBedrock();

    /// <summary>What to tell friends: a saved permanent address, else the LAN address.</summary>
    public string Recommended => TunnelAddress is { Length: > 0 } tun ? tun : R.ManualTunnelAddress is { Length: > 0 } t ? t : PublicAddress.Length > 0 && UpnpStatus.Contains("forwarded") ? PublicAddress : LanAddress;
    public string RecommendedLabel => TunnelAddress.Length > 0 ? "Free tunnel — works from anywhere while it's on" : R.ManualTunnelAddress is { Length: > 0 } ? "Your permanent address" : UpnpStatus.Contains("forwarded") ? "Public address (port forwarded)" : "On your Wi-Fi / network";

    // ---- free tunnel (bore) ----------------------------------------------------------------------

    TunnelStatus TunnelState => TunnelManager.Shared.Status(R.Id);
    string _tunnelNote = "";
    public bool TunnelRunning => TunnelState.Running;
    public bool TunnelStopped => !TunnelRunning;
    public string TunnelAddress => TunnelState.Address ?? "";
    public bool TunnelHasAddress => TunnelAddress.Length > 0;
    public bool TunnelOpening => TunnelRunning && !TunnelHasAddress;
    public string TunnelError => _tunnelNote.Length > 0 ? _tunnelNote : TunnelState.Error ?? "";
    public bool HasTunnelError => TunnelError.Length > 0;
    public bool JavaServer => !IsBedrock;
    public AsyncCommand StartTunnelCommand { get; }
    public RelayCommand StopTunnelCommand { get; }

    async Task StartTunnelAsync()
    {
        _tunnelNote = "Getting the tunnel client ready…"; RefreshTunnel();
        var progress = new Progress<ProvisionProgress>(p => { _tunnelNote = p.Pct is { } n ? $"{p.Message} {n}%" : p.Message; RefreshTunnel(); });
        await TunnelManager.Shared.StartAsync(R.Id, _port, progress);
        _tunnelNote = ""; RefreshTunnel();
    }

    void RefreshTunnel()
    {
        foreach (var n in new[] { nameof(TunnelRunning), nameof(TunnelStopped), nameof(TunnelAddress), nameof(TunnelHasAddress), nameof(TunnelOpening), nameof(TunnelError), nameof(HasTunnelError), nameof(Recommended), nameof(RecommendedLabel) }) Raise(n);
        StartTunnelCommand.RaiseCanExecuteChanged(); StopTunnelCommand.RaiseCanExecuteChanged();
    }

    // ---- Bedrock cross-play (Geyser + Floodgate) ------------------------------------------------

    CrossplayStatus _xp = new(false, false, false, CrossplayManager.DefaultBedrockPort, "plugins");
    bool _xpBusy;
    string _xpError = "";
    public bool XpAvailable => !IsBedrock;
    public bool XpCompatible => _xp.Compatible;
    public bool XpIncompatible => XpAvailable && !_xp.Compatible;
    public bool XpOff => _xp.Compatible && !_xp.Geyser;
    public bool XpOn => _xp.Geyser;
    public bool XpFloodgate => _xp.Floodgate;
    public bool XpFloodgateMissing => _xp.Geyser && !_xp.Floodgate;
    public int XpPort => _xp.BedrockPort;
    /// <summary>What a Bedrock friend types: your public IP once known, else your network address — never the free tunnel's (it only carries Java).</summary>
    public string XpAddress => BedrockNetwork.BedrockAddress(_publicIp.Contains(':') && !_publicIp.Contains("::") ? _publicIp[.._publicIp.LastIndexOf(':')] : _publicIp, Net.LanIp(), _xp.BedrockPort);
    public string XpAddressLabel => _publicIp.Length > 0 ? "BEDROCK ADDRESS (PUBLIC)" : "BEDROCK ADDRESS (ON YOUR NETWORK)";
    public string XpUdpText => $"Bedrock 26.60 signs in over TCP and plays over UDP on port {_xp.BedrockPort}, so both must be open. {BedrockNetwork.TunnelNote} {BedrockNetwork.TrustPromptNote}";
    public bool XpNeedsUpdate => XpAvailable && _xp.NeedsUpdate;
    public string XpUpdateText => _xp.GeyserBuild is { } b
        ? $"This Geyser (build {b}) is too old for Bedrock 26.60. Update it so Bedrock players can join."
        : "OMNIServers can't tell how old this Geyser is. Bedrock 26.60 needs build 1273 or newer, so update it to be sure.";
    public string XpUpdateLabel => _xpBusy ? "Updating…" : "Update Geyser";
    public bool XpCloneWarning => XpOn && _xp.CloneRemotePort;
    public string XpCloneText => "Geyser is set to share your Java port (clone-remote-port). Bedrock sign-in needs its own TCP port, so Geyser falls back to an outside service and prints the address to use in the server console. Set clone-remote-port to false in Geyser's config for a normal address.";
    public AsyncCommand UpdateGeyserCommand { get; }
    public string XpError { get => _xpError; private set { Set(ref _xpError, value); Raise(nameof(HasXpError)); } }
    public bool HasXpError => _xpError.Length > 0;
    public bool XpBusy { get => _xpBusy; private set { if (Set(ref _xpBusy, value)) { EnableCrossplayCommand.RaiseCanExecuteChanged(); DisableCrossplayCommand.RaiseCanExecuteChanged(); } } }
    public string XpEnableLabel => _xpBusy ? "Installing…" : "Turn on cross-play";
    public bool XpNeedsRestart => XpOn && _server.IsRunning;
    public AsyncCommand EnableCrossplayCommand { get; }
    public AsyncCommand DisableCrossplayCommand { get; }
    public AsyncCommand ForwardBedrockCommand { get; }
    public AsyncCommand BedrockFirewallCommand { get; }

    void RefreshCrossplay()
    {
        _xp = CrossplayManager.Status(R.Path, R.ServerType);
        foreach (var n in new[] { nameof(XpAvailable), nameof(XpCompatible), nameof(XpIncompatible), nameof(XpOff), nameof(XpOn), nameof(XpFloodgate), nameof(XpFloodgateMissing), nameof(XpPort), nameof(XpAddress), nameof(XpUdpText), nameof(XpEnableLabel), nameof(XpNeedsRestart), nameof(XpNeedsUpdate), nameof(XpUpdateText), nameof(XpUpdateLabel), nameof(XpCloneWarning), nameof(XpAddressLabel) }) Raise(n);
    }

    async Task EnableCrossplayAsync()
    {
        XpBusy = true; XpError = ""; Raise(nameof(XpEnableLabel));
        try { await CrossplayManager.EnableAsync(R.Path, R.ServerType, R.McVersion); ToastService.Shared.Show("Cross-play is on", _server.IsRunning ? "Restart the server to load it." : "It loads the next time the server starts.", "check-circle", "ok"); }
        catch (Exception e) { XpError = e.Message; }
        finally { XpBusy = false; RefreshCrossplay(); }
    }

    async Task UpdateGeyserAsync()
    {
        XpBusy = true; XpError = ""; Raise(nameof(XpUpdateLabel));
        try { await CrossplayManager.UpdateGeyserAsync(R.Path, R.ServerType); ToastService.Shared.Show("Geyser updated", _server.IsRunning ? "Restart the server to load it." : "It loads the next time the server starts.", "check-circle", "ok"); }
        catch (Exception e) { XpError = e.Message; }
        finally { XpBusy = false; RefreshCrossplay(); }
    }

    // ---- official Bedrock server (BDS) ------------------------------------------------------------

    public bool BdsLegacy => IsBedrock && BedrockNetwork.IsLegacyBds(R.McVersion);
    public string BdsLegacyText => $"This Bedrock server is version {R.McVersion}. Versions before 1.26.50 only speak the old RakNet connection, which Bedrock 26.60 players no longer use. Use Change Version in the server's menu to update (your world stays).";
    public string BdsPortsText => $"Bedrock 26.60 signs in over TCP and plays over UDP, so {BedrockNetwork.Describe(ForwardRules)} must be open. {BedrockNetwork.TunnelNote} {BedrockNetwork.TrustPromptNote}";
    bool AllowListOn => IsBedrock && !string.Equals(Properties.Load(R.Path).Get("allow-list")?.Trim(), "false", StringComparison.OrdinalIgnoreCase);
    public bool BdsAllowListOn => AllowListOn;
    public string BdsAllowListText => "The allow list is on, so only names in allowlist.json can join. New Bedrock servers ship with it on and empty, which means nobody can, you included. Players still have to be signed in to Xbox either way.";
    public RelayCommand AllowAnyoneCommand { get; }
    public AsyncCommand SetBedrockPublicAddressCommand { get; }
    string _bdsNote = "";
    public string BdsNote { get => _bdsNote; private set { Set(ref _bdsNote, value); Raise(nameof(HasBdsNote)); } }
    public bool HasBdsNote => _bdsNote.Length > 0;

    void AllowAnyone()
    {
        var p = Properties.Load(R.Path); p.Set("allow-list", "false"); p.Save();
        Raise(nameof(BdsAllowListOn));
        BdsNote = _server.IsRunning ? "Restart the server for this to apply." : "Done. It applies the next time the server starts.";
    }

    /// <summary>Puts your public IP into <c>server-udp-ports</c> so Bedrock hands friends an address they can reach. Needs repeating if your internet address changes.</summary>
    async Task SetBedrockPublicAddressAsync()
    {
        if (!HasPublicIp) await FetchPublicIpAsync();
        if (!HasPublicIp) { BdsNote = "Couldn't find your public address. Check your internet connection and try again."; return; }
        var p = Properties.Load(R.Path);
        var current = BedrockNetwork.ParseUdpPorts(p.Get("server-udp-ports"));
        if (current is { Count: > 1 }) { BdsNote = "Your UDP port range is set by hand, so OMNIServers left it alone."; return; }
        p.Set("server-udp-ports", BedrockNetwork.UdpPortsValue(current?.First ?? _port, _publicIp.Split(':')[0]));
        p.Save();
        BdsNote = (_server.IsRunning ? "Restart the server to apply. " : "Saved. ") + "If your internet address changes, press this again.";
    }

    async Task DisableCrossplayAsync()
    {
        if (!await Dialogs.Current.ConfirmAsync("Remove cross-play?", "Geyser and Floodgate are moved to the server's trash folder. Bedrock players won't be able to join.", "Remove", true)) return;
        XpBusy = true;
        try { await Task.Run(() => CrossplayManager.Disable(R.Path, R.ServerType)); XpError = ""; }
        catch (Exception e) { XpError = e.Message; }
        finally { XpBusy = false; RefreshCrossplay(); }
    }

    async Task ForwardBedrockAsync()
    {
        try
        {
            var addr = await UPnP.ForwardRulesAsync(BedrockNetwork.GeyserRules(_xp.BedrockPort), $"OMNIServers Bedrock (Geyser) {R.Name}");
            XpError = ""; PublicIp = addr.Split(':')[0]; RefreshCrossplay();
            ToastService.Shared.Show("TCP and UDP forwarded", BedrockNetwork.BedrockAddress(PublicIp, null, _xp.BedrockPort), "check-circle", "ok");
        }
        catch (Exception e) { XpError = e.Message + $" You may need to forward TCP and UDP {_xp.BedrockPort} in your router's settings."; }
    }

    async Task BedrockFirewallAsync()
    {
        var ok = await Firewall.AddBothRulesAsync(Firewall.RuleName(R.Name + " Bedrock", _xp.BedrockPort), _xp.BedrockPort);
        if (ok) { XpError = ""; ToastService.Shared.Show("Done", "Windows Firewall now allows the Bedrock port for TCP and UDP.", "check-circle", "ok"); }
        else XpError = "That didn't go through (permission declined, or this isn't Windows).";
    }

    public RelayCommand CopyCommand { get; }
    public AsyncCommand PublicIpCommand { get; }
    public RelayCommand SaveTunnelCommand { get; }
    public AsyncCommand UpnpForwardCommand { get; }
    public AsyncCommand UpnpRemoveCommand { get; }
    public AsyncCommand UpnpCheckCommand { get; }
    public AsyncCommand FirewallCommand { get; }

    async Task FetchPublicIpAsync()
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            PublicIp = (await Http.Client.GetStringAsync("https://api.ipify.org", cts.Token)).Trim();
        }
        catch (Exception e) { Note = "Couldn't look up your public address: " + e.Message; }
    }

    void SaveTunnel()
    {
        R.ManualTunnelAddress = string.IsNullOrWhiteSpace(Tunnel) ? null : Tunnel.Trim();
        AppServices.Store.Update(R);
        Raise(nameof(Recommended)); Raise(nameof(RecommendedLabel));
        ToastService.Shared.Show("Address saved", "", "check-circle", "ok", null, 2);
    }

    async Task UpnpForwardAsync()
    {
        _busy = true; UpnpStatus = "Asking your router…";
        try
        {
            var addr = await UPnP.ForwardRulesAsync(ForwardRules, $"OMNIServers {R.Name}");
            UpnpStatus = $"{BedrockNetwork.Describe(ForwardRules)} forwarded — friends can join at {BedrockNetwork.BedrockAddress(addr.Split(':')[0], null, _port)}";
            PublicIp = addr.Split(':')[0];
        }
        catch (Exception e) { UpnpStatus = e.Message + " You may need to forward the port in your router's settings."; }
        finally { _busy = false; Raise(nameof(Recommended)); Raise(nameof(RecommendedLabel)); }
    }

    async Task UpnpRemoveAsync()
    {
        _busy = true;
        try { await UPnP.RemoveRulesAsync(ForwardRules); UpnpStatus = "The port forward was removed."; }
        catch (Exception e) { UpnpStatus = e.Message; }
        finally { _busy = false; Raise(nameof(Recommended)); Raise(nameof(RecommendedLabel)); }
    }

    async Task UpnpCheckAsync()
    {
        _busy = true; UpnpStatus = "Checking…";
        try
        {
            var (available, mapped) = await UPnP.StatusRulesAsync(ForwardRules);
            UpnpStatus = !available ? "No UPnP router was found on this network." : mapped ? $"{BedrockNetwork.Describe(ForwardRules)} forwarded." : $"Your router supports UPnP but {BedrockNetwork.Describe(ForwardRules)} isn't forwarded yet.";
        }
        finally { _busy = false; }
    }

    string RuleName => Firewall.RuleName(R.Name, _port);

    /// <summary>Java: the one TCP port. Bedrock server (26.60+): TCP sign-in on server-port plus its UDP port(s).</summary>
    IReadOnlyList<PortRule> ForwardRules => IsBedrock ? BedrockNetwork.BdsRules(_port, Properties.Load(R.Path).Get("server-udp-ports")) : [new(PortProtocol.Tcp, _port)];

    async Task CheckFirewallAsync()
    {
        if (!Firewall.Supported) return;
        var exists = IsBedrock ? await Firewall.RulesExistAsync(RuleName, ForwardRules) : await Firewall.RuleExistsAsync(RuleName);
        Ui.Post(() => FirewallStatus = exists switch { true => "Windows Firewall already allows this port.", false => "Windows Firewall may block friends on your network from connecting.", _ => "" });
    }

    async Task AddFirewallAsync()
    {
        FirewallStatus = "Waiting for administrator permission…";
        var ok = IsBedrock ? await Firewall.AddForRulesAsync(RuleName, ForwardRules) : await Firewall.AddRuleAsync(RuleName, _port);
        FirewallStatus = ok ? "Done — Windows Firewall now allows this port." : "That didn't go through (permission declined?). You can try again.";
    }
}
