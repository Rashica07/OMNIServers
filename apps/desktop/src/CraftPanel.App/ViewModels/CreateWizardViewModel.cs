using System.Collections.ObjectModel;
using Avalonia.Media.Imaging;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Addons;

namespace CraftPanel.App.ViewModels;

public enum WizardStep { Loader, Version, Modpack, Template, Details, Working }

public sealed class LoaderChoice(Loader loader, string blurb, string icon, int speed = 3, bool plugins = false, bool mods = false, bool recommended = false, ServerType? game = null, string? note = null)
{
    /// <summary>Set for non-Minecraft games (FiveM, Terraria): no version step, downloads the game's own server.</summary>
    public ServerType? Game { get; } = game;
    public bool IsGame => Game is not null;
    public bool IsMinecraft => Game is null;
    public string Note { get; } = note ?? "";
    public int Speed { get; } = speed;
    public bool Plugins { get; } = plugins;
    public bool Mods { get; } = mods;
    public bool Recommended { get; } = recommended;
    public bool Bar1 => Speed >= 1; public bool Bar2 => Speed >= 2; public bool Bar3 => Speed >= 3; public bool Bar4 => Speed >= 4; public bool Bar5 => Speed >= 5;
    public string PluginsText => Plugins ? "✓ Plugins" : "✕ Plugins";
    public string ModsText => Mods ? "✓ Mods" : "✕ Mods";
    public Loader Loader { get; } = loader;
    public string Label { get; } = game?.Label() ?? loader.Label();
    public string Blurb { get; } = blurb;
    public string Icon { get; } = icon;
}

public sealed class VersionRow(VersionInfo v)
{
    public string Id { get; } = v.Id;
    public string Kind { get; } = v.Kind;
    public bool IsStable => Kind == "release";
}

public sealed class PackRow : ViewModelBase
{
    Bitmap? _icon;
    public ModpackHit Hit { get; }
    public PackRow(ModpackHit hit) { Hit = hit; _ = Load(); }
    async Task Load() { var b = await ImageCache.LoadAsync(Hit.IconUrl); Ui.Post(() => { _icon = b; Raise(nameof(Icon)); Raise(nameof(HasIcon)); }); }
    public string Title => Hit.Title;
    public string Description => Hit.Description;
    public string Downloads => Hit.Downloads >= 1000 ? $"{Hit.Downloads / 1000.0:0.#}k downloads" : $"{Hit.Downloads} downloads";
    public Bitmap? Icon => _icon;
    public bool HasIcon => _icon is not null;
}

public sealed class TemplateChoice(string id, string label, string icon, string blurb, string? pluginSlug, string? pluginName)
{
    public string Id { get; } = id; public string Label { get; } = label; public string Icon { get; } = icon; public string Blurb { get; } = blurb;
    public string? PluginSlug { get; } = pluginSlug; public string? PluginName { get; } = pluginName;
    public bool IsMinigame => Id is "skyblock" or "bedwars";
}

/// <summary>The "New server" flow: pick a loader and version (or a modpack, or a ready-made game mode), name it, size its memory, and let OMNIServers build it.</summary>
public sealed class CreateWizardViewModel : ViewModelBase
{
    public static readonly LoaderChoice[] LoaderChoices =
    [
        new(Loader.Paper, "Fast and friendly. Runs Bukkit/Spigot plugins — the best pick for most friend servers.", "zap", 5, plugins: true, recommended: true),
        new(Loader.Fabric, "Lightweight modding. Great for performance mods and small mod lists.", "package", 4, mods: true),
        new(Loader.Vanilla, "Plain Minecraft, exactly as Mojang ships it. No mods, no plugins.", "cube", 3),
        new(Loader.NeoForge, "Modern Forge-family modding for big mod packs (1.20.2 and newer).", "layers", 3, mods: true),
        new(Loader.Forge, "The classic mod loader, best for older versions and packs.", "pickaxe", 3, mods: true),
        new(Loader.Bedrock, "Bedrock Edition: for phones, consoles and Windows 10/11 players. Runs on Windows and Linux.", "globe", 4),
        new(Loader.Vanilla, "GTA V multiplayer (roleplay and more). Pick your own server files, or make a new one. Needs your free licence key from keymaster.fivem.net.", "swords", game: ServerType.FiveM, note: "Windows & Linux"),
        new(Loader.Vanilla, "The sandbox adventure. Pick an existing server, or make a new one that creates its own world.", "pickaxe", game: ServerType.Terraria, note: "Windows, Mac & Linux"),
    ];

    public static readonly TemplateChoice[] Templates =
    [
        new("smp", "Vanilla SMP", "users", "Plain survival with friends, no gimmicks — Paper for the performance headroom, nothing else installed.", null, null),
        new("skyblock", "Skyblock", "cloud", "Start on one block that regenerates as you break it. Auto-installs OneBlock.", "oneblock_bukkit", "OneBlock"),
        new("bedwars", "Bedwars", "swords", "Team PvP, protect your bed. Auto-installs BedWars1058 — you'll still set up an arena in-game.", "bedwars1058", "BedWars1058"),
        new("essentials", "Survival + Essentials", "sliders", "Vanilla SMP plus /home, /tpa, /kits… Auto-installs EssentialsX.", "essentialsx", "EssentialsX"),
    ];

    WizardStep _step = WizardStep.Loader;
    Loader _loader = Loader.Paper;
    ServerType? _game;
    public bool IsGameServer => _game is not null;
    public bool IsMinecraftServer => _game is null;
    bool _showUnstable, _loadingVersions, _loadingPacks;
    string _versionQuery = "", _packQuery = "", _name = "", _location = "", _java = "", _seed = "", _motd = "", _gamemode = "survival", _difficulty = "normal";
    string _message = "", _error = "";
    int? _pct;
    double _ram = AppServices.Settings.DefaultRamMB, _players = 4, _maxPlayers = 20;
    bool _follow = true, _isModpack, _isTemplate;
    VersionRow? _version;
    PackRow? _pack;
    TemplateChoice _template = Templates[0];
    List<VersionRow> _allVersions = [];
    CancellationTokenSource? _cts;

    public ObservableCollection<VersionRow> Versions { get; } = [];
    public ObservableCollection<PackRow> Packs { get; } = [];
    public static string[] Gamemodes => ServerSettingsViewModel.Gamemodes;
    public static string[] Difficulties => ServerSettingsViewModel.Difficulties;

    /// <summary>The finished server's id (set when creation succeeds).</summary>
    public Guid? CreatedId { get; private set; }
    public event Action? RequestClose;

    public CreateWizardViewModel(WizardMode mode)
    {
        _java = AppServices.Settings.DefaultJava;
        PickLoaderCommand = new RelayCommand(o => { if (o is LoaderChoice c) { if (c.Game is { } g) ChooseGame(g); else ChooseLoader(c.Loader); } });
        PickVersionCommand = new RelayCommand(o => { if (o is VersionRow v) { Version = v; GoDetails(); } });
        PickPackCommand = new RelayCommand(o => { if (o is PackRow p) { Pack = p; _isModpack = true; if (Name.Length == 0) Name = p.Title; GoDetails(); } });
        SearchPacksCommand = new AsyncCommand(() => LoadPacksAsync());
        BackCommand = new RelayCommand(Back);
        CreateCommand = new AsyncCommand(CreateAsync, () => CanCreate);
        BrowseLocationCommand = new AsyncCommand(async () => { if (await Dialogs.Current.PickFolderAsync("Where should the server folder go?") is { } f) { _locationEdited = true; Location = Path.Combine(f, FolderName()); } });
        SwitchToModpacksCommand = new RelayCommand(() => StartModpacks());
        SwitchToTemplatesCommand = new RelayCommand(() => StartTemplates());
        PickTemplateCommand = new RelayCommand(o => { if (o is TemplateChoice t) { Template = t; } });
        NextTemplateCommand = new RelayCommand(() => { _isTemplate = true; if (Name.Length == 0) Name = Template.Label; GoDetails(); });
        CloseCommand = new RelayCommand(() => RequestClose?.Invoke());
        _nextTemplateAsync = new AsyncCommand(() => { NextTemplateCommand.Execute(null); return Task.CompletedTask; });
        switch (mode)
        {
            case WizardMode.Modpack: StartModpacks(); break;
            case WizardMode.QuickStart: StartTemplates(); break;
        }
    }

    // ---- state -----------------------------------------------------------------------------

    public WizardStep Step
    {
        get => _step;
        private set { if (Set(ref _step, value)) foreach (var n in new[] { nameof(IsLoaderStep), nameof(IsVersionStep), nameof(IsModpackStep), nameof(IsTemplateStep), nameof(IsDetailsStep), nameof(IsWorkingStep), nameof(ShowSteps), nameof(Op1), nameof(Op2), nameof(Op3), nameof(CanGoBack), nameof(StepTitle), nameof(StepHint), nameof(ShowFooter), nameof(PrimaryText), nameof(PrimaryCommand) }) Raise(n); }
    }
    int StepIndex => Step switch { WizardStep.Loader or WizardStep.Modpack or WizardStep.Template => 0, WizardStep.Version => 1, _ => 2 };
    public bool ShowSteps => Step != WizardStep.Working;
    public double Op1 => StepIndex >= 0 ? 1 : .4;
    public double Op2 => StepIndex >= 1 ? 1 : .4;
    public double Op3 => StepIndex >= 2 ? 1 : .4;
    public bool IsLoaderStep => Step == WizardStep.Loader;
    public bool IsVersionStep => Step == WizardStep.Version;
    public bool IsModpackStep => Step == WizardStep.Modpack;
    public bool IsTemplateStep => Step == WizardStep.Template;
    public bool IsDetailsStep => Step == WizardStep.Details;
    public bool IsWorkingStep => Step == WizardStep.Working;
    public bool CanGoBack => Step is WizardStep.Version or WizardStep.Details or WizardStep.Modpack or WizardStep.Template;
    public bool ShowFooter => Step is WizardStep.Details or WizardStep.Template;
    public string PrimaryText => Step == WizardStep.Template ? "Next" : "Create server";
    public AsyncCommand PrimaryCommand => Step == WizardStep.Template ? _nextTemplateAsync : CreateCommand;
    readonly AsyncCommand _nextTemplateAsync;

    public string StepTitle => Step switch
    {
        WizardStep.Loader => "What kind of server?", WizardStep.Version => $"Pick a {_loader.Label()} version", WizardStep.Modpack => "Choose a modpack",
        WizardStep.Template => "Quick start", WizardStep.Details => _isModpack ? $"Set up {Pack?.Title ?? "the modpack"}" : _isTemplate ? $"Set up {Template.Label}" : $"Set up your {_game?.Label() ?? _loader.Label()} server",
        _ => "Building your server",
    };
    public string StepHint => Step switch
    {
        WizardStep.Loader => "You can change most of this later.", WizardStep.Version => "The newest is usually the best choice unless your mods say otherwise.",
        WizardStep.Modpack => "From Modrinth. OMNIServers downloads the pack, its mods and the right loader.", WizardStep.Template => "A ready-made game mode — Paper, EULA accepted, the right plugin installed automatically.",
        WizardStep.Details => "", _ => "This takes a minute or two the first time.",
    };

    public Loader Loader => _loader;
    public bool ShowUnstable { get => _showUnstable; set { if (Set(ref _showUnstable, value)) ApplyVersionFilter(); } }
    public string VersionQuery { get => _versionQuery; set { if (Set(ref _versionQuery, value)) ApplyVersionFilter(); } }
    public string PackQuery { get => _packQuery; set => Set(ref _packQuery, value); }
    public bool LoadingVersions { get => _loadingVersions; private set => Set(ref _loadingVersions, value); }
    public bool LoadingPacks { get => _loadingPacks; private set => Set(ref _loadingPacks, value); }
    public VersionRow? Version { get => _version; set => Set(ref _version, value); }
    public PackRow? Pack { get => _pack; set => Set(ref _pack, value); }
    public TemplateChoice Template { get => _template; set { if (Set(ref _template, value)) { Raise(nameof(RamKind)); Raise(nameof(TemplateIndex)); } } }
    public int TemplateIndex => Array.IndexOf(Templates, Template);

    public string Name { get => _name; set { if (Set(ref _name, value)) { if (!_locationEdited) Location = Path.Combine(BaseDir, FolderName()); Raise(nameof(CanCreate)); CreateCommand.RaiseCanExecuteChanged(); } } }
    bool _locationEdited;
    static string BaseDir => AppPaths.DefaultServersDir;
    public string Location { get => _location; set { if (_location != value) { _location = value; Raise(nameof(Location)); } } }
    public string Java { get => _java; set => Set(ref _java, value); }
    public string Seed { get => _seed; set => Set(ref _seed, value); }
    public string Motd { get => _motd; set => Set(ref _motd, value); }
    public string Gamemode { get => _gamemode; set => Set(ref _gamemode, value); }
    public string Difficulty { get => _difficulty; set => Set(ref _difficulty, value); }
    public double MaxPlayers { get => _maxPlayers; set => Set(ref _maxPlayers, value); }
    public double RamMB { get => _ram; set => Set(ref _ram, value); }
    public double Players { get => _players; set => Set(ref _players, value); }
    public bool Follow { get => _follow; set => Set(ref _follow, value); }
    public bool ShowWorldSettings => !_isModpack && !_isTemplate && _game is null;

    public RamKind RamKind => _isModpack ? RamKind.Modpack : _isTemplate ? (Template.IsMinigame ? RamKind.Minigame : RamKind.VanillaLike) : RamAdvisor.KindFor(_loader.ServerType());
    public bool CanCreate => Name.Trim().Length > 0 && Location.Length > 0;
    public string Message { get => _message; private set => Set(ref _message, value); }
    public int? Pct { get => _pct; private set { Set(ref _pct, value); Raise(nameof(Indeterminate)); Raise(nameof(PctValue)); } }
    public bool Indeterminate => _pct is null;
    public double PctValue => _pct ?? 0;
    public string Error { get => _error; private set { Set(ref _error, value); Raise(nameof(HasError)); } }
    public bool HasError => _error.Length > 0;

    public RelayCommand PickLoaderCommand { get; }
    public RelayCommand PickVersionCommand { get; }
    public RelayCommand PickPackCommand { get; }
    public AsyncCommand SearchPacksCommand { get; }
    public RelayCommand BackCommand { get; }
    public AsyncCommand CreateCommand { get; }
    public AsyncCommand BrowseLocationCommand { get; }
    public RelayCommand SwitchToModpacksCommand { get; }
    public RelayCommand SwitchToTemplatesCommand { get; }
    public RelayCommand PickTemplateCommand { get; }
    public RelayCommand NextTemplateCommand { get; }
    public RelayCommand CloseCommand { get; }

    // ---- navigation ------------------------------------------------------------------------

    void ChooseLoader(Loader l)
    {
        _loader = l; _isModpack = false; _isTemplate = false; Version = null; Raise(nameof(Loader));
        Step = WizardStep.Version;
        _ = LoadVersionsAsync();
    }

    void ChooseGame(ServerType g)
    {
        _game = g; _isModpack = false; _isTemplate = false; Version = null;
        Name = $"My {g.Label()} Server";
        GoDetails();
    }

    void StartModpacks() { _isModpack = true; _isTemplate = false; Step = WizardStep.Modpack; if (Packs.Count == 0) _ = LoadPacksAsync(); }
    void StartTemplates() { _isTemplate = true; _isModpack = false; Step = WizardStep.Template; }

    void Back()
    {
        Error = "";
        Step = Step switch
        {
            WizardStep.Details when _game is not null => WizardStep.Loader,
            WizardStep.Details => _isModpack ? WizardStep.Modpack : _isTemplate ? WizardStep.Template : WizardStep.Version,
            _ => WizardStep.Loader,
        };
        if (Step == WizardStep.Loader) { _isModpack = false; _isTemplate = false; _game = null; Raise(nameof(IsGameServer)); Raise(nameof(IsMinecraftServer)); Raise(nameof(ShowWorldSettings)); }
    }

    void GoDetails()
    {
        if (_isTemplate || _game is not null) { } else if (!_isModpack && Version is null) return;
        if (Name.Length == 0 && !_isModpack && !_isTemplate && _game is null) Name = $"My {_loader.Label()} Server";
        _locationEdited = false;
        Location = Path.Combine(BaseDir, FolderName());
        Raise(nameof(RamKind)); Raise(nameof(ShowWorldSettings)); Raise(nameof(IsGameServer)); Raise(nameof(IsMinecraftServer));
        Step = WizardStep.Details;
    }

    string FolderName()
    {
        var clean = new string((Name.Length == 0 ? "server" : Name).Select(c => char.IsLetterOrDigit(c) || c is ' ' or '-' or '_' ? c : ' ').ToArray()).Trim().Replace(' ', '-');
        return clean.Length == 0 ? "server" : clean;
    }

    string UniqueDir()
    {
        var path = Location;
        if (!Directory.Exists(path) || !Directory.EnumerateFileSystemEntries(path).Any()) return path;
        var i = 2;
        while (Directory.Exists($"{path}-{i}") && Directory.EnumerateFileSystemEntries($"{path}-{i}").Any()) i++;
        return $"{path}-{i}";
    }

    // ---- data ------------------------------------------------------------------------------

    async Task LoadVersionsAsync()
    {
        LoadingVersions = true; Error = ""; Versions.Clear();
        try { _allVersions = (await Provisioner.ListVersionsAsync(_loader)).Select(v => new VersionRow(v)).ToList(); ApplyVersionFilter(); }
        catch (Exception e) { Error = "Couldn't load versions: " + e.Message; }
        finally { LoadingVersions = false; }
    }

    void ApplyVersionFilter()
    {
        Versions.Clear();
        foreach (var v in _allVersions.Where(v => (ShowUnstable || v.IsStable) && (VersionQuery.Trim().Length == 0 || v.Id.Contains(VersionQuery.Trim(), StringComparison.OrdinalIgnoreCase))).Take(200)) Versions.Add(v);
    }

    async Task LoadPacksAsync()
    {
        LoadingPacks = true; Error = ""; Packs.Clear();
        try { foreach (var h in await Modpacks.SearchAsync(PackQuery.Trim())) Packs.Add(new PackRow(h)); }
        catch (Exception e) { Error = "Couldn't reach Modrinth: " + e.Message; }
        finally { LoadingPacks = false; }
    }

    // ---- create ----------------------------------------------------------------------------

    async Task CreateAsync()
    {
        Error = "";
        var others = AppServices.Store.All.Where(s => AppServices.Processes.IsRunning(s.Id)).Sum(s => (int)s.RamMB);
        var warnings = _game is not null ? [] : RamAdvisor.Warnings((int)RamMB, RamKind, (int)Players, SystemMemory.Current(), others);
        if (warnings.Count > 0 && !await Dialogs.Current.ConfirmAsync("This PC might struggle with this server", string.Join("\n\n", warnings.Select(w => "• " + w.Message)), "Install anyway")) return;

        var dir = UniqueDir();
        var name = Name.Trim();
        Step = WizardStep.Working; Pct = null; Message = "Getting ready…";
        _cts = new CancellationTokenSource();
        var progress = new Progress<ProvisionProgress>(p => { Message = p.Message; Pct = p.Pct; });
        try
        {
            Created created;
            var taken = AppServices.Store.TakenPorts();
            if (_game is { } game)
            {
                created = await GameInstaller.CreateAsync(game, dir, name, progress, _cts.Token);
            }
            else if (_isModpack && Pack is { } pack)
            {
                created = await Modpacks.CreateAsync(pack.Hit.ProjectId, dir, name, (uint)RamMB, Java, taken, progress, _cts.Token);
            }
            else if (_isTemplate)
            {
                created = await CreateTemplateAsync(dir, name, progress, taken);
            }
            else
            {
                var versionId = Version!.Id;
                var loaderVersion = _loader is Loader.Forge or Loader.NeoForge ? versionId : null;
                var spec = new CreateSpec(_loader, Provisioner.DeriveMcVersion(_loader, versionId), loaderVersion, dir, name, (uint)RamMB, Java);
                created = await Provisioner.CreateAsync(spec, progress, _cts.Token);
                var bedrock = _loader == Loader.Bedrock;
                Provisioner.ApplyStartingSettings(dir, bedrock, bedrock ? Provisioner.PickFreeBedrockPort(taken) : Provisioner.PickFreePort(taken), Seed, Gamemode, Difficulty, Motd, (int)MaxPlayers);
            }
            var rec = new ServerRecord
            {
                Name = name, Path = dir, ServerType = created.ServerType, LaunchTarget = created.LaunchTarget, McVersion = created.McVersion,
                JavaPath = created.JavaPath, RamMB = (uint)RamMB,
            };
            AppServices.Store.Add(rec);
            CreatedId = rec.Id;
            ToastService.Shared.Show($"{name} is ready", "Press Start to launch it.", "check-circle", "ok");
            RequestClose?.Invoke();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Error = e.Message; Step = WizardStep.Details;
            ToastService.Shared.Error(e.Message);
        }
    }

    async Task<Created> CreateTemplateAsync(string dir, string name, IProgress<ProvisionProgress> progress, ISet<int> taken)
    {
        progress.Report(new("fetch", "Finding a Paper version…", null));
        var versions = (await Provisioner.ListVersionsAsync(Loader.Paper)).Where(v => v.Kind == "release").ToList();
        var mc = versions.FirstOrDefault()?.Id;
        if (Template.PluginSlug is { } slug)
        {
            progress.Report(new("check", $"Checking {Template.PluginName} compatibility…", null));
            var supported = await ModrinthClient.SupportedVersionsAsync(slug, "paper");
            mc = versions.FirstOrDefault(v => supported.Contains(v.Id))?.Id
                ?? throw new ProvisionException($"{Template.PluginName} doesn't have a build for any available Paper version yet.");
        }
        if (mc is null) throw new ProvisionException("Couldn't find a Paper build to install.");
        var created = await Provisioner.CreateAsync(new CreateSpec(Loader.Paper, mc, null, dir, name, (uint)RamMB, Java), progress);
        Provisioner.ApplyStartingSettings(dir, false, Provisioner.PickFreePort(taken), null, null, null, null, null);
        if (Template.PluginSlug is { } s2)
        {
            progress.Report(new("plugin", $"Installing {Template.PluginName}…", null));
            await ModrinthClient.InstallAsync(dir, ServerType.Paper, s2, "mod", mc);
        }
        return created;
    }

    public void Cancel() => _cts?.Cancel();
}
