using CraftPanel.App.Services;
using CraftPanel.Core;

namespace CraftPanel.Tests;

/// <summary>A scripted stand-in for the window system: answers confirmations from a queue and records what was asked.</summary>
public sealed class FakeDialogs : IDialogService
{
    public Queue<bool> Confirms { get; } = new();
    public List<(string Title, string Message)> Asked { get; } = [];
    public List<string> OpenedFolders { get; } = [];
    public int? ListChoice { get; set; }
    public List<(string Page, bool Tour)> HelpShown { get; } = [];
    public List<string> Copied { get; } = [];
    public string? FolderToPick { get; set; }

    public Task<bool> ConfirmAsync(string title, string message, string confirmText = "OK", bool danger = false)
    { Asked.Add((title, message)); return Task.FromResult(Confirms.Count > 0 && Confirms.Dequeue()); }
    public Task<string?> PickFolderAsync(string title) => Task.FromResult(FolderToPick);
    public Task<IReadOnlyList<string>> PickFilesAsync(string title, bool multiple = false) => Task.FromResult<IReadOnlyList<string>>([]);
    public Task<string?> PromptAsync(string title, string label, string? initial = null, string confirmText = "OK") => Task.FromResult<string?>(null);
    public Task ShowMessageAsync(string title, string message) { Asked.Add((title, message)); return Task.CompletedTask; }
    public void OpenFolder(string path) => OpenedFolders.Add(path);
    public void OpenUrl(string url) { }
    public void CopyText(string text) => Copied.Add(text);
    public Task<string?> ReadClipboardAsync() => Task.FromResult<string?>(null);
    public Task<Guid?> ShowCreateWizardAsync(WizardMode mode) => Task.FromResult<Guid?>(null);
    public Task ShowChangeVersionAsync(ServerRecord server) => Task.CompletedTask;
    public Task ShowNbtEditorAsync(string path, string title, bool serverRunning) => Task.CompletedTask;
    public Task ShowReportAsync(string? error = null) => Task.CompletedTask;
    public void ShowHelp(string pageId, bool tour, Action<CraftPanel.Core.Help.HelpAction> act) => HelpShown.Add((pageId, tour));
    public Task<int?> PickFromListAsync(string title, string message, IReadOnlyList<string> items, string confirmText = "Choose") => Task.FromResult(ListChoice);
}
