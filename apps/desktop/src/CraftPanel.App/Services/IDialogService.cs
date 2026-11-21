namespace CraftPanel.App.Services;

/// <summary>The few things view-models need from the window system (implemented by MainWindow).</summary>
public interface IDialogService
{
    Task<string?> PickFolderAsync(string title);
    Task<IReadOnlyList<string>> PickFilesAsync(string title, bool multiple = false);
    Task<bool> ConfirmAsync(string title, string message, string confirmText = "OK", bool danger = false);
    /// <summary>A dialog with several buttons. Returns the index of the one pressed, or -1 if it was closed.</summary>
    Task<int> ChooseAsync(string title, string message, params string[] buttons);
    Task<string?> PromptAsync(string title, string label, string? initial = null, string confirmText = "OK");
    Task ShowMessageAsync(string title, string message);
    void OpenFolder(string path);
    void OpenUrl(string url);
    void CopyText(string text);
    Task<string?> ReadClipboardAsync();
    /// <summary>Opens the create-server wizard; returns the created server or null.</summary>
    Task<Guid?> ShowCreateWizardAsync(WizardMode mode);
    Task ShowChangeVersionAsync(Core.ServerRecord server);
    /// <summary>Opens an NBT file (level.dat, player data…) in the tree editor.</summary>
    Task ShowNbtEditorAsync(string path, string title, bool serverRunning);
    /// <summary>Opens the "Report a problem" window.</summary>
    Task ShowReportAsync(string? error = null);
    /// <summary>Opens (or re-points) the Help window on a page, or on the tour. It stays open beside the app; <paramref name="act"/> runs the buttons inside the guides.</summary>
    void ShowHelp(string pageId, bool tour, Action<Core.Help.HelpAction> act);
    /// <summary>Shows a list and returns the index of the chosen row, or null if cancelled.</summary>
    Task<int?> PickFromListAsync(string title, string message, IReadOnlyList<string> items, string confirmText = "Choose");
}

public enum WizardMode { Custom, Modpack, QuickStart }

public static class Dialogs
{
    public static IDialogService Current { get; set; } = null!;
}
