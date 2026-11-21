using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using CraftPanel.App.Controls;
using CraftPanel.Core;

namespace CraftPanel.App.Services;

/// <summary>Window-backed dialogs. Small ones are built in code; the wizards are real windows (see Views).</summary>
public sealed class DialogService(Window owner) : IDialogService
{
    public async Task<string?> PickFolderAsync(string title)
    {
        var r = await owner.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = title, AllowMultiple = false });
        return r.Count > 0 ? r[0].TryGetLocalPath() : null;
    }

    public async Task<IReadOnlyList<string>> PickFilesAsync(string title, bool multiple = false)
    {
        var r = await owner.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = title, AllowMultiple = multiple });
        return r.Select(f => f.TryGetLocalPath()).Where(p => p is not null).Cast<string>().ToList();
    }

    public async Task<bool> ConfirmAsync(string title, string message, string confirmText = "OK", bool danger = false)
    {
        var ok = false;
        await Show(title, message, null, [("Cancel", "ghost", false), (confirmText, danger ? "danger" : "primary", true)], r => ok = r);
        return ok;
    }

    public async Task ShowMessageAsync(string title, string message) => await Show(title, message, null, [("OK", "primary", true)], _ => { });

    public async Task<string?> PromptAsync(string title, string label, string? initial = null, string confirmText = "OK")
    {
        var box = new TextBox { Text = initial ?? "", PlaceholderText = label, MinWidth = 300 };
        string? result = null;
        await Show(title, label, box, [("Cancel", "ghost", false), (confirmText, "primary", true)], ok => { if (ok) result = box.Text; });
        return string.IsNullOrWhiteSpace(result) ? null : result.Trim();
    }

    async Task Show(string title, string message, Control? extra, (string Text, string Class, bool IsOk)[] buttons, Action<bool> done)
    {
        var win = new Window
        {
            Title = title, SizeToContent = SizeToContent.WidthAndHeight, MinWidth = 380, MaxWidth = 520, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var result = false;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var (text, cls, isOk) in buttons)
        {
            var b = new Button { Content = text, MinWidth = 84 };
            b.Classes.Add(cls);
            b.Click += (_, _) => { result = isOk; win.Close(); };
            row.Children.Add(b);
        }
        var body = new StackPanel { Spacing = 12, Margin = new Thickness(22) };
        body.Children.Add(new TextBlock { Text = title, Classes = { "h2" }, TextWrapping = TextWrapping.Wrap });
        if (extra is null || message != "") body.Children.Add(new TextBlock { Text = message, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap });
        if (extra is not null) body.Children.Add(extra);
        body.Children.Add(row);
        win.Content = body;
        if (extra is TextBox tb) win.Opened += (_, _) => tb.Focus();
        await win.ShowDialog(owner);
        done(result);
    }

    public void OpenFolder(string path)
    {
        try
        {
            if (OperatingSystem.IsWindows()) Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
            else if (OperatingSystem.IsMacOS()) Process.Start("open", [path]);
            else Process.Start("xdg-open", [path]);
        }
        catch (Exception e) { ToastService.Shared.Error("Couldn't open the folder: " + e.Message); }
    }

    public void OpenUrl(string url)
    {
        try
        {
            if (!(url.StartsWith("https://") || url.StartsWith("http://"))) return;
            if (OperatingSystem.IsMacOS()) Process.Start("open", [url]);
            else Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception e) { ToastService.Shared.Error("Couldn't open the link: " + e.Message); }
    }

    public void CopyText(string text) => _ = owner.Clipboard?.SetTextAsync(text);
    public async Task<string?> ReadClipboardAsync() => owner.Clipboard is { } c ? await c.TryGetTextAsync() : null;

    public async Task<Guid?> ShowCreateWizardAsync(WizardMode mode)
    {
        var vm = new ViewModels.CreateWizardViewModel(mode);
        await new Views.CreateWizardWindow(vm).ShowDialog(owner);
        return vm.CreatedId;
    }
    public async Task ShowNbtEditorAsync(string path, string title, bool serverRunning) => await new Views.NbtEditorWindow(new ViewModels.NbtEditorViewModel(path, title, serverRunning)).ShowDialog(owner);
    public async Task<int?> PickFromListAsync(string title, string message, IReadOnlyList<string> items, string confirmText = "Choose")
    {
        var list = new ListBox { ItemsSource = items, MinWidth = 380, MaxHeight = 280 };
        list.Classes.Add("plain");
        int? result = null;
        var win = new Window { Title = title, SizeToContent = SizeToContent.WidthAndHeight, MinWidth = 420, MaxWidth = 560, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var ok = new Button { Content = confirmText, MinWidth = 84 }; ok.Classes.Add("primary");
        var cancel = new Button { Content = "Cancel", MinWidth = 84 }; cancel.Classes.Add("ghost");
        ok.Click += (_, _) => { if (list.SelectedIndex >= 0) { result = list.SelectedIndex; win.Close(); } };
        cancel.Click += (_, _) => win.Close();
        list.DoubleTapped += (_, _) => ok.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        row.Children.Add(cancel); row.Children.Add(ok);
        var body = new StackPanel { Spacing = 12, Margin = new Thickness(22) };
        body.Children.Add(new TextBlock { Text = title, Classes = { "h2" }, TextWrapping = TextWrapping.Wrap });
        if (message != "") body.Children.Add(new TextBlock { Text = message, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(list); body.Children.Add(row);
        win.Content = body;
        await win.ShowDialog(owner);
        return result;
    }

    static Views.HelpWindow? _help;
    public void ShowHelp(string pageId, bool tour, Action<Core.Help.HelpAction> act)
    {
        var vm = new ViewModels.HelpViewModel(pageId, tour, act);
        if (_help is { } open) { open.DataContext = vm; vm.RequestClose += () => Avalonia.Threading.Dispatcher.UIThread.Post(open.Close); open.Activate(); return; }
        _help = new Views.HelpWindow(vm);
        _help.Closed += (_, _) => { _help = null; if (!AppServices.Settings.HelpTourDone) { AppServices.Settings.HelpTourDone = true; AppServices.Settings.Save(); } };
        _help.Show(owner);
    }

    public async Task ShowReportAsync(string? error = null) => await new Views.ReportWindow(new ViewModels.ReportViewModel(error)).ShowDialog(owner);
    public async Task ShowChangeVersionAsync(ServerRecord server) => await new Views.ChangeVersionWindow(new ViewModels.ChangeVersionViewModel(server)).ShowDialog(owner);
}
