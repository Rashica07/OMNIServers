using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Worlds;

namespace CraftPanel.App.ViewModels;

public sealed class WorldRow(string name, string path, bool active, long size, DateTime modified)
{
    public bool HasLevelDat { get; } = File.Exists(System.IO.Path.Combine(path, "level.dat"));
    public string Name { get; } = name;
    public string Path { get; } = path;
    public bool Active { get; } = active;
    public string Size { get; } = BackupRow.Format(size);
    public string Modified { get; } = modified.ToString("d MMM yyyy, HH:mm");
}

public sealed class WorldsViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    ServerRecord R => _server.Record;
    string _status = "";
    public ObservableCollection<WorldRow> Worlds { get; } = [];
    public bool IsRunning => _server.IsRunning;
    public bool CanEdit => !_server.IsRunning;
    public string Status { get => _status; private set { Set(ref _status, value); Raise(nameof(HasStatus)); } }
    public bool HasStatus => _status.Length > 0;
    public bool IsEmpty => Worlds.Count == 0;

    public WorldsViewModel(ServerItemViewModel server)
    {
        _server = server;
        SetActiveCommand = new RelayCommand(SetActive);
        NewWorldCommand = new AsyncCommand(NewWorldAsync);
        AddFolderCommand = new AsyncCommand(async () => { if (await Dialogs.Current.PickFolderAsync("Choose the world folder (the one with level.dat in it)") is { } f) await AddAsync(f); });
        AddZipCommand = new AsyncCommand(async () => { var z = await Dialogs.Current.PickFilesAsync("Choose a world .zip", false); if (z.Count > 0) await AddAsync(z[0]); });
        AddSingleplayerCommand = new AsyncCommand(AddSingleplayerAsync);
        ExportCommand = new AsyncCommand(ExportAsync);
        DeleteCommand = new AsyncCommand(DeleteAsync);
        OpenCommand = new RelayCommand(p => { if (p is WorldRow w) Dialogs.Current.OpenFolder(w.Path); });
        EditLevelCommand = new AsyncCommand(async p => { if (p is WorldRow w) await Dialogs.Current.ShowNbtEditorAsync(System.IO.Path.Combine(w.Path, "level.dat"), $"{w.Name}/level.dat", _server.IsRunning); });
        server.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ServerItemViewModel.IsRunning)) { Raise(nameof(IsRunning)); Raise(nameof(CanEdit)); } };
        Reload();
    }

    public RelayCommand SetActiveCommand { get; }
    public AsyncCommand NewWorldCommand { get; }
    public AsyncCommand AddFolderCommand { get; }
    public AsyncCommand AddZipCommand { get; }
    public AsyncCommand AddSingleplayerCommand { get; }
    public AsyncCommand ExportCommand { get; }
    public AsyncCommand DeleteCommand { get; }
    public RelayCommand OpenCommand { get; }
    public AsyncCommand EditLevelCommand { get; }

    static long DirSize(string d) { try { return Directory.EnumerateFiles(d, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length); } catch { return 0; } }

    public void Reload()
    {
        Worlds.Clear();
        var active = Properties.Load(R.Path).GetOr("level-name", "world");
        foreach (var d in Directory.EnumerateDirectories(R.Path).OrderBy(d => d, StringComparer.OrdinalIgnoreCase))
        {
            var name = Path.GetFileName(d);
            if (name.StartsWith('.') || name == BackupManager.BackupDirName) continue;
            if (!File.Exists(Path.Combine(d, "level.dat")) && name != active) continue;
            Worlds.Add(new WorldRow(name, d, name == active, DirSize(d), Directory.GetLastWriteTime(d)));
        }
        Raise(nameof(IsEmpty));
    }

    void SetActive(object? p)
    {
        if (p is not WorldRow w) return;
        if (IsRunning) { ToastService.Shared.Error("Stop the server first."); return; }
        var props = Properties.Load(R.Path);
        props.Set("level-name", w.Name); props.Save();
        Status = $"“{w.Name}” will load the next time the server starts.";
        Reload();
    }

    async Task NewWorldAsync()
    {
        if (IsRunning) { ToastService.Shared.Error("Stop the server first."); return; }
        var name = await Dialogs.Current.PromptAsync("New world", "World folder name", "world2", "Create");
        if (name is null) return;
        try
        {
            var safe = FileOps.SafeFileName(name);
            var props = Properties.Load(R.Path);
            props.Set("level-name", safe); props.Save();
            Status = $"A fresh world called “{safe}” will be generated the next time the server starts.";
        }
        catch (Exception e) { ToastService.Shared.Error(e.Message); }
        Reload();
    }

    async Task DeleteAsync(object? p)
    {
        if (p is not WorldRow w) return;
        if (IsRunning) { ToastService.Shared.Error("Stop the server first."); return; }
        if (w.Active) { ToastService.Shared.Error("That's the active world — pick another one first."); return; }
        if (!await Dialogs.Current.ConfirmAsync($"Delete “{w.Name}”?", "The world folder is moved to a trash folder inside the server folder, not permanently deleted.", "Move to trash", true)) return;
        try { FileOps.MoveToTrash(w.Path, Path.Combine(R.Path, ".craftpanel-trash")); } catch (Exception e) { ToastService.Shared.Error(e.Message); }
        Reload();
    }

    // ---- bringing a world in from outside --------------------------------------------------------

    /// <summary>Called by drag-and-drop: one world folder or .zip at a time.</summary>
    public async Task ImportDroppedAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        if (paths.Count > 1) { Status = "One world at a time, please — drop just one folder or .zip."; return; }
        await AddAsync(paths[0]);
    }

    /// <summary>Checks what's in the folder/zip, tells you what it is, copies it in, and offers to switch to it.</summary>
    public async Task AddAsync(string path)
    {
        FoundWorld w;
        try { w = await Task.Run(() => WorldImporter.Inspect(path)); }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); return; }

        var warn = WorldImporter.VersionWarning(w.McVersion, R.McVersion);
        var what = $"“{w.Name}” — {(w.McVersion is null ? "Minecraft version unknown" : "Minecraft " + w.McVersion)}, {BackupRow.Format(w.Bytes)}{(w.Dimensions.Length > 0 ? ", " + w.Dimensions : "")}.";
        var text = what + " It's copied in next to your other worlds; the original isn't changed." + (warn is null ? "" : "\n\n" + warn);
        if (!await Dialogs.Current.ConfirmAsync(warn is null ? "Add this world?" : "Add this world anyway?", text, "Add world", warn is not null)) return;

        string name;
        try { name = await Task.Run(() => WorldImporter.Import(R.Path, w, m => Ui.Post(() => Status = m))); }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); return; }
        Reload();
        var active = Properties.Load(R.Path).GetOr("level-name", "world");
        if (name == active) { Status = $"Added “{name}” — it's the world this server loads."; return; }
        Status = $"Added “{name}”. Use “Use this world” next to it to switch to it.";
        if (!IsRunning && await Dialogs.Current.ConfirmAsync("Use it now?", $"Switch this server to “{name}”? Your current world stays in its folder, and you can switch back any time.", "Use this world"))
        {
            var props = Properties.Load(R.Path); props.Set("level-name", name); props.Save();
            Status = $"“{name}” will load the next time the server starts.";
            Reload();
        }
    }

    async Task AddSingleplayerAsync()
    {
        var found = await Task.Run(() => WorldImporter.FindSingleplayerWorlds());
        if (found.Count == 0) { Status = $"No single-player worlds found in {WorldImporter.DefaultSavesFolder()}. Use “From a folder” and pick the world's folder instead."; return; }
        var rows = found.Select(f => $"{f.Name}  ·  {(f.McVersion is null ? "?" : f.McVersion)}  ·  played {(f.LastPlayedMs > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(f.LastPlayedMs).LocalDateTime.ToString("d MMM yyyy") : "?")}").ToList();
        if (await Dialogs.Current.PickFromListAsync("Your single-player worlds", "Pick one to copy onto this server. The single-player copy isn't changed.", rows, "Add") is { } i) await AddAsync(found[i].Source);
    }

    async Task ExportAsync()
    {
        var paused = false;
        try
        {
            if (IsRunning) { Status = "Saving the world…"; paused = await _server.Runtime.PauseSavesAsync(); }
            var zip = await Task.Run(() => WorldImporter.Export(R.Path, null, m => Ui.Post(() => Status = m)));
            Status = $"Saved {Path.GetFileName(zip)} to {Path.GetDirectoryName(zip)}. Add it to another server with “Add a world”.";
            ToastService.Shared.Show("World exported", Path.GetFileName(zip), "check-circle", "ok");
            Dialogs.Current.OpenFolder(Path.GetDirectoryName(zip)!);
        }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); }
        finally { if (paused) _server.Runtime.ResumeSaves(); }
    }
}
