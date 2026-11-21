using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Platform.Storage;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using CraftPanel.App.Services;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        DataContext = new MainViewModel();
        Dialogs.Current = new DialogService(this);
        Ui.Error = e => ToastService.Shared.Error(e.Message);
        PlayerNotifier.IsAppActive = () => IsActive;
        void ApplyWidth() => Root.ColumnDefinitions[0].Width = new GridLength(AppServices.Settings.SidebarCollapsed ? 76 : 256);
        ApplyWidth();
        if (DataContext is MainViewModel main) main.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(MainViewModel.SidebarCollapsed)) ApplyWidth(); };
        // Drop a server folder anywhere on the window to add it.
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = DroppedFolder(e) is not null ? DragDropEffects.Copy : DragDropEffects.None);
        AddHandler(DragDrop.DropEvent, OnDropFolder);
    }

    static string? DroppedFolder(DragEventArgs e) =>
        (e.DataTransfer.TryGetFiles() ?? []).Select(f => f.TryGetLocalPath()).FirstOrDefault(p => p is not null && Directory.Exists(p));

    async void OnDropFolder(object? sender, DragEventArgs e)
    {
        if (DroppedFolder(e) is not { } folder || DataContext is not MainViewModel vm) { ToastService.Shared.Error("Drop the server's folder here, not a file."); return; }
        e.Handled = true;
        await vm.AddFolderAsync(folder);
    }

    static ServerItemViewModel? Item(object? sender) => (sender as Control)?.DataContext as ServerItemViewModel;

    void OnServerMenuStart(object? s, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (Item(s) is { } i) try { i.Runtime.Start(i.Record); AppServices.Store.Update(i.Record); } catch (Exception ex) { ToastService.Shared.Error($"{i.Name}: {ex.Message}"); }
    }
    void OnServerMenuStop(object? s, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (Item(s) is { } i) try { i.Runtime.Stop(); } catch (Exception ex) { ToastService.Shared.Error(ex.Message); }
    }
    void OnServerMenuFolder(object? s, Avalonia.Interactivity.RoutedEventArgs e) { if (Item(s) is { } i) Dialogs.Current.OpenFolder(i.Record.Path); }
    void OnServerMenuCopyPath(object? s, Avalonia.Interactivity.RoutedEventArgs e) { if (Item(s) is { } i) { Dialogs.Current.CopyText(i.Record.Path); ToastService.Shared.Show("Copied", i.Record.Path, "check-circle", "ok"); } }
    async void OnServerMenuRemove(object? s, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (Item(s) is not { } i) return;
        if (!await Dialogs.Current.ConfirmAsync($"Remove {i.Name}?", "The server disappears from OMNIServers but its folder and world stay exactly where they are. You can add it again any time.", "Remove", true)) return;
        AppServices.Store.Remove(i.Id);
    }

    void OnToastTapped(object? sender, TappedEventArgs e)
    {
        if (sender is Control { DataContext: ToastItem t } && DataContext is MainViewModel vm)
        {
            ToastService.Shared.Dismiss(t);
            if (t.ServerId is { } id) vm.Open(id, ServerSection.Chat);
        }
    }
}
