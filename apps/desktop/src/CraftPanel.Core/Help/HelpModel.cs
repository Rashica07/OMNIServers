namespace CraftPanel.Core.Help;

/// <summary>Every page of the app that has help. Ids are what a topic lists in <see cref="HelpTopic.Pages"/>.</summary>
public static class HelpPages
{
    public const string Overview = "overview";
    public const string SettingsGeneral = "settings.general", SettingsAccount = "settings.account",
        SettingsJava = "settings.java", SettingsBackups = "settings.backups", SettingsDiagnostics = "settings.diagnostics", SettingsAbout = "settings.about";
    public const string ServerPerformance = "server.performance", ServerConsole = "server.console", ServerChat = "server.chat", ServerNetwork = "server.network", ServerPlayers = "server.players",
        ServerMap = "server.map", ServerSettings = "server.settings", ServerAddons = "server.addons", ServerMods = "server.mods",
        ServerWorlds = "server.worlds", ServerBackups = "server.backups", ServerFiles = "server.files";
    public const string WizardCreate = "wizard.create", ToolNbt = "tool.nbt", ToolReport = "tool.report";

    /// <summary>Id → the name shown to the user.</summary>
    public static readonly IReadOnlyDictionary<string, string> All = new Dictionary<string, string>
    {
        [Overview] = "Overview",
        [SettingsGeneral] = "Settings — General", [SettingsAccount] = "Settings — Account", [SettingsJava] = "Settings — Java",
        [SettingsBackups] = "Settings — Backups", [SettingsDiagnostics] = "Settings — Diagnostics", [SettingsAbout] = "Settings — About",
        [ServerPerformance] = "Performance", [ServerConsole] = "Console", [ServerChat] = "Chat", [ServerNetwork] = "Network", [ServerPlayers] = "Players", [ServerMap] = "Map", [ServerSettings] = "Server settings",
        [ServerAddons] = "Add-ons", [ServerMods] = "Mods", [ServerWorlds] = "Worlds", [ServerBackups] = "Backups", [ServerFiles] = "Files",
        [WizardCreate] = "Create a server", [ToolNbt] = "NBT editor", [ToolReport] = "Report a problem",
    };

    /// <summary>The page id for a server tab name (the <c>ServerSection</c> enum's names).</summary>
    public static string ForServerSection(string section) => "server." + section.ToLowerInvariant().Replace("-", "");
    public static string ForSettingsTab(string tab) => "settings." + tab.ToLowerInvariant();
}

public enum HelpActionKind
{
    /// <summary>Go to a tab of the selected server (Arg = the section name, e.g. "Worlds").</summary>
    Section,
    /// <summary>Open OMNIServers settings on a tab (Arg = "General", "Java"…).</summary>
    SettingsTab,
    Overview,
    NewServer,
    /// <summary>Put text on the clipboard (Arg = the text).</summary>
    Copy,
    ReportProblem,
}

public sealed record HelpAction(string Label, HelpActionKind Kind, string Arg = "");

public sealed record HelpStep(string Text, HelpAction? Action = null);

/// <summary>One how-to: a short title, what it's for, numbered steps, and "good to know" notes.</summary>
public sealed record HelpTopic(string Id, string Title, string Summary, string[] Pages, string[] Keywords, HelpStep[] Steps, string[]? Notes = null);

/// <summary>One stop of the first-launch tour.</summary>
public sealed record TourStep(string Title, string Text, HelpAction? Action = null);
