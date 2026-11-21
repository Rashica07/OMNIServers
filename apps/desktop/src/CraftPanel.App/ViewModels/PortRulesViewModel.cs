using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Network;

namespace CraftPanel.App.ViewModels;

public sealed class PresetChip : ViewModelBase
{
    bool _active;
    public PresetChip(PortPreset preset, Action<PresetChip> pick) { Preset = preset; PickCommand = new RelayCommand(() => pick(this)); }
    public PortPreset Preset { get; }
    public string Name => Preset.Name;
    public bool IsActive { get => _active; set => Set(ref _active, value); }
    public RelayCommand PickCommand { get; }
}

/// <summary>One editable line: a protocol, a port number and a short label.</summary>
public sealed class RuleRow : ViewModelBase
{
    string _port; int _proto; string _label;
    readonly Action _changed;
    public RuleRow(PortRule r, Action changed, Action<RuleRow> remove)
    {
        _port = r.Port.ToString(); _proto = (int)r.Protocol; _label = r.Label; _changed = changed;
        RemoveCommand = new RelayCommand(() => remove(this));
    }
    public static string[] Protocols { get; } = ["TCP", "UDP", "TCP + UDP"];
    public int ProtocolIndex { get => _proto; set { if (Set(ref _proto, value)) _changed(); } }
    public string Port { get => _port; set { if (Set(ref _port, value)) _changed(); } }
    public string Label { get => _label; set => Set(ref _label, value); }
    public RelayCommand RemoveCommand { get; }
    public PortRule ToRule() => new(ProtocolIndex switch { 0 => PortProtocol.Tcp, 1 => PortProtocol.Udp, _ => PortProtocol.Both }, int.TryParse(_port.Trim(), out var p) ? p : 0, _label);
}

/// <summary>The "Port rules" card: pick a game preset or build your own, see problems, then apply to the firewall or copy the commands.</summary>
public sealed class PortRulesViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    List<PortPreset> _saved;
    string _presetName = "", _status = "";
    string? _activeId;
    bool _busy;
    static string File => System.IO.Path.Combine(AppPaths.DataDir, "port-presets.json");

    public PortRulesViewModel(ServerItemViewModel server)
    {
        _server = server;
        _saved = PortRules.LoadSaved(File);
        RebuildChips();
        AddRuleCommand = new RelayCommand(() => { Rules.Add(NewRow(new(PortProtocol.Tcp, 25565, ""))); Recheck(); });
        ApplyCommand = new AsyncCommand(ApplyAsync, () => !_busy && CanApply);
        CopyCommand = new RelayCommand(() => { Dialogs.Current.CopyText(string.Join("\n", Commands)); ToastService.Shared.Show("Commands copied", "Run them in an administrator terminal.", "copy", "ok", null, 3); });
        SavePresetCommand = new RelayCommand(SavePreset, () => _presetName.Trim().Length > 0 && Rules.Count > 0);
        DeletePresetCommand = new RelayCommand(DeletePreset, () => _saved.Any(p => p.Id == _activeId));
        PickDefault();
    }

    /// <summary>Starts on the preset that fits this server, with its real ports filled in (BDS's server-port and UDP ports, or Java + Geyser).</summary>
    void PickDefault()
    {
        var r = _server.Record;
        var fit = BedrockNetwork.DefaultRules(r.ServerType, r.Path);
        var id = fit?.PresetId ?? (r.ServerType.IsBedrock() ? "minecraft-bedrock" : "minecraft-java");
        Pick(Chips.FirstOrDefault(c => c.Preset.Id == id) ?? Chips[0]);
        if (fit is null) return;
        Rules.Clear();
        foreach (var rule in fit.Value.Rules) Rules.Add(NewRow(rule));
        Recheck();
    }

    public ObservableCollection<PresetChip> Chips { get; } = [];
    public ObservableCollection<RuleRow> Rules { get; } = [];
    public ObservableCollection<string> Issues { get; } = [];
    public RelayCommand AddRuleCommand { get; }
    public AsyncCommand ApplyCommand { get; }
    public RelayCommand CopyCommand { get; }
    public RelayCommand SavePresetCommand { get; }
    public RelayCommand DeletePresetCommand { get; }

    public string PresetNote => (Chips.FirstOrDefault(c => c.IsActive)?.Preset.Note) ?? "";
    public string PresetName { get => _presetName; set { if (Set(ref _presetName, value)) SavePresetCommand.RaiseCanExecuteChanged(); } }
    public string Status { get => _status; private set { Set(ref _status, value); Raise(nameof(HasStatus)); } }
    public bool HasStatus => _status.Length > 0;
    public bool HasIssues => Issues.Count > 0;
    public bool FirewallSupported => Firewall.Supported;
    public string ApplyLabel => "Allow through Windows Firewall";
    public string CommandsTitle => Firewall.Supported ? "Windows Firewall commands" : "Firewall commands (ufw)";
    public IEnumerable<string> Commands => Firewall.Supported ? PortRules.NetshCommands(_server.Name, ActiveRules) : PortRules.UfwCommands(ActiveRules);
    public string CommandsText => string.Join("\n", Commands);

    List<PortRule> ActiveRules => Rules.Select(r => r.ToRule()).Where(r => r.Port is >= 1 and <= 65535).ToList();
    bool CanApply => Firewall.Supported && Rules.Count > 0 && !PortRules.Validate(Rules.Select(r => r.ToRule()).ToList()).Any(i => i.Level == IssueLevel.Error);

    RuleRow NewRow(PortRule r) => new(r, Recheck, row => { Rules.Remove(row); Recheck(); });

    void RebuildChips()
    {
        Chips.Clear();
        foreach (var p in PortRules.BuiltIn.Where(p => p.Id != "custom").Concat(_saved).Append(PortRules.Find("custom")!))
        {
            Chips.Add(new PresetChip(p, Pick));
        }
    }

    void Pick(PresetChip chip)
    {
        foreach (var c in Chips) c.IsActive = c == chip;
        _activeId = chip.Preset.Id;
        Rules.Clear();
        foreach (var r in chip.Preset.Rules) Rules.Add(NewRow(r));
        Raise(nameof(PresetNote)); DeletePresetCommand.RaiseCanExecuteChanged();
        Recheck();
    }

    void Recheck()
    {
        var all = Rules.Select(r => r.ToRule()).ToList();
        Issues.Clear();
        foreach (var i in PortRules.Validate(all)) Issues.Add((i.Level == IssueLevel.Error ? "Fix: " : "Careful: ") + i.Message);
        var own = Properties.Load(_server.Record.Path).GetInt("server-port", _server.Record.ServerType.IsBedrock() ? 19132 : 25565);
        var others = AppServices.Store.TakenPorts(); others.Remove(own);
        // the server's own port is only "in use" while it is running; skip the bind check for it then
        foreach (var i in PortRules.FindConflicts(all, others, (proto, port) => (_server.IsRunning && port == own) || Net.PortFreeFor(proto, port))) Issues.Add("Careful: " + i.Message);
        Raise(nameof(HasIssues)); Raise(nameof(CommandsText));
        ApplyCommand.RaiseCanExecuteChanged(); SavePresetCommand.RaiseCanExecuteChanged();
    }

    async Task ApplyAsync()
    {
        _busy = true; ApplyCommand.RaiseCanExecuteChanged();
        try
        {
            var ok = 0; var failed = 0;
            foreach (var (proto, port) in PortRules.Expand(ActiveRules))
            {
                var name = $"CraftPanel - {_server.Name} {proto.ToString().ToUpperInvariant()} {port}";
                if (await Firewall.RuleExistsAsync(name) == true || await Firewall.AddRuleAsync(name, port, proto == PortProtocol.Udp)) ok++; else failed++;
            }
            Status = failed == 0 ? $"{ok} rule{(ok == 1 ? "" : "s")} allowed in Windows Firewall." : $"{ok} allowed, {failed} didn't go through. Windows asks for administrator permission each time, so say yes to each prompt.";
        }
        finally { _busy = false; ApplyCommand.RaiseCanExecuteChanged(); }
    }

    void SavePreset()
    {
        var name = _presetName.Trim();
        var id = "user-" + new string(name.ToLowerInvariant().Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());
        _saved.RemoveAll(p => p.Id == id);
        _saved.Add(new PortPreset(id, name, "Your saved preset.", ActiveRules, false));
        PortRules.Save(File, _saved);
        RebuildChips(); Pick(Chips.First(c => c.Preset.Id == id)); PresetName = "";
        Status = $"Saved \"{name}\". It will be here for every server.";
    }

    void DeletePreset()
    {
        _saved.RemoveAll(p => p.Id == _activeId);
        PortRules.Save(File, _saved);
        RebuildChips(); Pick(Chips[0]);
        Status = "Preset deleted.";
    }
}
