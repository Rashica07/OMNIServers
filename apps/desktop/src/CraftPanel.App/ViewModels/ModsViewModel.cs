using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Addons;

namespace CraftPanel.App.ViewModels;

public sealed class ModRow(string file, bool enabled, long size, string? managedTitle)
{
    public string File { get; } = file;
    public string DisplayName => System.IO.Path.GetFileName(File).Replace(".disabled", "");
    public bool Enabled { get; } = enabled;
    public string Size { get; } = BackupRow.Format(size);
    public string? ManagedTitle { get; } = managedTitle;
    public bool IsManaged => ManagedTitle is not null;
    public string ToggleText => Enabled ? "Disable" : "Enable";
}

/// <summary>The jars in mods/ (or plugins/): enable, disable, add, remove. Disabled ones get a ".disabled" suffix so the server skips them.</summary>
public sealed class ModsViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    ServerRecord R => _server.Record;
    public ObservableCollection<ModRow> Mods { get; } = [];
    public string FolderName => R.ServerType.UsesPlugins() ? "plugins" : "mods";
    public string Dir => Path.Combine(R.Path, FolderName);
    public bool IsEmpty => Mods.Count == 0;
    public bool IsRunning => _server.IsRunning;

    public ModsViewModel(ServerItemViewModel server)
    {
        _server = server;
        AddCommand = new AsyncCommand(AddAsync);
        ToggleCommand = new RelayCommand(Toggle);
        RemoveCommand = new AsyncCommand(RemoveAsync);
        OpenFolderCommand = new RelayCommand(() => { Directory.CreateDirectory(Dir); Dialogs.Current.OpenFolder(Dir); });
        server.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ServerItemViewModel.IsRunning)) Raise(nameof(IsRunning)); };
        Reload();
    }

    public AsyncCommand AddCommand { get; }
    public RelayCommand ToggleCommand { get; }
    public AsyncCommand RemoveCommand { get; }
    public RelayCommand OpenFolderCommand { get; }

    public void Reload()
    {
        Mods.Clear();
        if (Directory.Exists(Dir))
        {
            var managed = ModrinthClient.Installed(R.Path).GroupBy(e => e.Filename, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First().Title, StringComparer.OrdinalIgnoreCase);   // the add-on list can name a file twice
            foreach (var f in Directory.EnumerateFiles(Dir).Where(f => f.EndsWith(".jar", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".jar.disabled", StringComparison.OrdinalIgnoreCase)).OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase))
            {
                var name = Path.GetFileName(f).Replace(".disabled", "");
                Mods.Add(new ModRow(f, !f.EndsWith(".disabled", StringComparison.OrdinalIgnoreCase), new FileInfo(f).Length, managed.GetValueOrDefault(name)));
            }
        }
        Raise(nameof(IsEmpty));
    }

    async Task AddAsync()
    {
        var files = await Dialogs.Current.PickFilesAsync($"Add to {FolderName}", true);
        if (files.Count == 0) return;
        Directory.CreateDirectory(Dir);
        var added = 0;
        foreach (var f in files)
        {
            try
            {
                var name = FileOps.SafeFileName(Path.GetFileName(f));
                if (!name.EndsWith(".jar", StringComparison.OrdinalIgnoreCase)) { ToastService.Shared.Error($"{name} isn't a .jar file."); continue; }
                File.Copy(f, Path.Combine(Dir, name), overwrite: false); added++;
            }
            catch (Exception e) { ToastService.Shared.Error(e.Message); }
        }
        if (added > 0) ToastService.Shared.Show($"Added {added} file{(added == 1 ? "" : "s")}", IsRunning ? "Restart the server to load them." : "", "check-circle", "ok");
        Reload();
    }

    void Toggle(object? p)
    {
        if (p is not ModRow m) return;
        try
        {
            var target = m.Enabled ? m.File + ".disabled" : m.File[..^".disabled".Length];
            File.Move(m.File, target);
            if (IsRunning) ToastService.Shared.Show("Restart the server to apply", "", "info", "info", null, 3);
        }
        catch (Exception e) { ToastService.Shared.Error(e.Message); }
        Reload();
    }

    async Task RemoveAsync(object? p)
    {
        if (p is not ModRow m) return;
        if (!await Dialogs.Current.ConfirmAsync($"Remove {m.DisplayName}?", "It's moved to a trash folder inside the server folder, not permanently deleted.", "Remove", true)) return;
        try
        {
            FileOps.MoveToTrash(m.File, Path.Combine(R.Path, ".craftpanel-trash"));
            var manifest = ModrinthClient.Installed(R.Path).FirstOrDefault(e => string.Equals(e.Filename, m.DisplayName, StringComparison.OrdinalIgnoreCase));
            if (manifest is not null) { try { ModrinthClient.RemoveOne(R.Path, R.ServerType, manifest.ProjectId); } catch { } }
        }
        catch (Exception e) { ToastService.Shared.Error(e.Message); }
        Reload();
    }
}
