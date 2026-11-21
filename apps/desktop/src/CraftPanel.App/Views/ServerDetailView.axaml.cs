using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Platform.Storage;
using CraftPanel.App.Services;
using CraftPanel.App.ViewModels;
using CraftPanel.Core.Adapters;

namespace CraftPanel.App.Views;

public partial class ServerDetailView : UserControl
{
    public ServerDetailView()
    {
        InitializeComponent();
        // Drop a world folder or .zip anywhere on a server's page to add it as a world.
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, OnDragOver);
        AddHandler(DragDrop.DropEvent, OnDrop);
    }

    static List<string> Paths(DragEventArgs e) =>
        (e.DataTransfer.TryGetFiles() ?? []).Select(f => f.TryGetLocalPath()).Where(p => p is not null).Cast<string>().ToList();

    void OnDragOver(object? sender, DragEventArgs e) => e.DragEffects = Paths(e).Count > 0 ? DragDropEffects.Copy : DragDropEffects.None;

    async void OnDrop(object? sender, DragEventArgs e)
    {
        var paths = Paths(e);
        if (paths.Count == 0 || DataContext is not ServerDetailViewModel detail) return;
        // A whole server folder (not a world) is for the main window's "add server" flow.
        if (paths.Any(p => Directory.Exists(p) && !File.Exists(Path.Combine(p, "level.dat")) && (MinecraftAdapter.Inspect(p) is not null || GameServers.Inspect(p) is not null))) return;
        e.Handled = true;
        detail.Select(ServerSection.Worlds);
        if (detail.Section is WorldsViewModel worlds) await worlds.ImportDroppedAsync(paths);
        else ToastService.Shared.Error("This kind of server doesn't use Java world folders.");
    }
}
