using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;

namespace CraftPanel.App.ViewModels;

public sealed class FileRow(string fullPath, bool isDir)
{
    public string FullPath { get; } = fullPath;
    public string Name { get; } = Path.GetFileName(fullPath);
    public bool IsDir { get; } = isDir;
    public string Icon => IsDir ? "folder" : "file";
    public string SizeText { get; } = isDir ? "" : BackupRow.Format(new FileInfo(fullPath).Length);
    public string Modified { get; } = (isDir ? Directory.GetLastWriteTime(fullPath) : File.GetLastWriteTime(fullPath)).ToString("d MMM yyyy, HH:mm");
    public long Bytes { get; } = isDir ? 0 : new FileInfo(fullPath).Length;
}

/// <summary>A confined file browser for the server folder, with a small text editor for configs.</summary>
public sealed class FilesViewModel : ViewModelBase
{
    static readonly HashSet<string> TextExt = [".txt", ".properties", ".json", ".yml", ".yaml", ".toml", ".cfg", ".conf", ".log", ".md", ".mcmeta", ".xml", ".ini", ".sh", ".bat", ".cmd", ".json5", ".csv", ".lang"];
    const long MaxEditBytes = 2 * 1024 * 1024;

    readonly ServerItemViewModel _server;
    string _rel = "", _editText = "", _status = "";
    FileRow? _selected, _editing;
    bool _dirty;

    ServerRecord R => _server.Record;
    public ObservableCollection<FileRow> Entries { get; } = [];

    public FilesViewModel(ServerItemViewModel server)
    {
        _server = server;
        UpCommand = new RelayCommand(Up, () => _rel.Length > 0);
        OpenCommand = new RelayCommand(Open);
        RefreshCommand = new RelayCommand(Reload);
        NewFolderCommand = new AsyncCommand(NewFolderAsync);
        UploadCommand = new AsyncCommand(UploadAsync);
        RenameCommand = new AsyncCommand(RenameAsync);
        DeleteCommand = new AsyncCommand(DeleteAsync);
        SaveCommand = new AsyncCommand(SaveAsync, () => Dirty);
        CloseEditorCommand = new AsyncCommand(CloseEditorAsync);
        ExplorerCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(Current));
        Reload();
    }

    string Current => FileOps.Confine(R.Path, _rel);
    public string Location => "/" + _rel.Replace('\\', '/');
    public bool IsEmpty => Entries.Count == 0;
    public string Status { get => _status; private set { Set(ref _status, value); Raise(nameof(HasStatus)); } }
    public bool HasStatus => _status.Length > 0;

    public FileRow? Selected { get => _selected; set { Set(ref _selected, value); Raise(nameof(HasSelection)); } }
    public bool HasSelection => _selected is not null;

    public bool IsEditing => _editing is not null;
    public string EditingName => _editing?.Name ?? "";
    public string EditText { get => _editText; set { if (Set(ref _editText, value) && _editing is not null) Dirty = true; } }
    public bool Dirty { get => _dirty; private set { if (Set(ref _dirty, value)) SaveCommand.RaiseCanExecuteChanged(); Raise(nameof(EditingTitle)); } }
    public string EditingTitle => _editing is null ? "" : _editing.Name + (Dirty ? " •" : "");

    public RelayCommand UpCommand { get; }
    public RelayCommand OpenCommand { get; }
    public RelayCommand RefreshCommand { get; }
    public AsyncCommand NewFolderCommand { get; }
    public AsyncCommand UploadCommand { get; }
    public AsyncCommand RenameCommand { get; }
    public AsyncCommand DeleteCommand { get; }
    public AsyncCommand SaveCommand { get; }
    public AsyncCommand CloseEditorCommand { get; }
    public RelayCommand ExplorerCommand { get; }

    public void Reload()
    {
        Entries.Clear();
        try
        {
            var dir = Current;
            foreach (var d in Directory.EnumerateDirectories(dir).OrderBy(d => d, StringComparer.OrdinalIgnoreCase)) Entries.Add(new FileRow(d, true));
            foreach (var f in Directory.EnumerateFiles(dir).OrderBy(f => f, StringComparer.OrdinalIgnoreCase)) Entries.Add(new FileRow(f, false));
        }
        catch (Exception e) { Status = e.Message; }
        Raise(nameof(Location)); Raise(nameof(IsEmpty)); UpCommand.RaiseCanExecuteChanged();
    }

    void Up()
    {
        var parent = Path.GetDirectoryName(_rel.TrimEnd('/', '\\')) ?? "";
        _rel = parent; Selected = null; Reload();
    }

    void Open(object? p)
    {
        var row = p as FileRow ?? Selected;
        if (row is null) return;
        if (row.IsDir) { _rel = Path.GetRelativePath(R.Path, row.FullPath); Selected = null; Reload(); return; }
        _ = OpenFileAsync(row);
    }

    async Task OpenFileAsync(FileRow row)
    {
        if (_dirty && !await Dialogs.Current.ConfirmAsync("Discard your changes?", $"{_editing?.Name} has unsaved changes.", "Discard", true)) return;
        var ext = Path.GetExtension(row.Name).ToLowerInvariant();
        if (ext is ".dat" or ".dat_old" or ".nbt")
        {
            await Dialogs.Current.ShowNbtEditorAsync(row.FullPath, Path.GetRelativePath(R.Path, row.FullPath).Replace('\\', '/'), _server.IsRunning);
            return;
        }
        if (!TextExt.Contains(ext) || row.Bytes > MaxEditBytes)
        {
            Status = row.Bytes > MaxEditBytes ? "That file is too large to edit here." : "OMNIServers edits text files and NBT data (.dat, .nbt); other files open in their own program.";
            return;
        }
        try
        {
            _editing = row;
            _editText = await File.ReadAllTextAsync(row.FullPath);
            Dirty = false; Status = "";
            Raise(nameof(EditText)); Raise(nameof(IsEditing)); Raise(nameof(EditingName)); Raise(nameof(EditingTitle));
        }
        catch (Exception e) { Status = e.Message; _editing = null; Raise(nameof(IsEditing)); }
    }

    async Task SaveAsync()
    {
        if (_editing is null) return;
        try
        {
            var path = FileOps.Confine(R.Path, Path.GetRelativePath(R.Path, _editing.FullPath));
            AppPaths.WriteAtomic(path, _editText);
            Dirty = false;
            ToastService.Shared.Show($"{_editing.Name} saved", _server.IsRunning ? "Restart the server for config changes to apply." : "", "check-circle", "ok");
        }
        catch (Exception e) { ToastService.Shared.Error(e.Message); }
        await Task.CompletedTask;
    }

    async Task CloseEditorAsync()
    {
        if (_dirty && !await Dialogs.Current.ConfirmAsync("Discard your changes?", $"{_editing?.Name} has unsaved changes.", "Discard", true)) return;
        _editing = null; _editText = ""; Dirty = false;
        Raise(nameof(IsEditing)); Raise(nameof(EditText)); Raise(nameof(EditingTitle));
    }

    async Task NewFolderAsync()
    {
        var name = await Dialogs.Current.PromptAsync("New folder", "Folder name", null, "Create");
        if (name is null) return;
        try { Directory.CreateDirectory(FileOps.Confine(Current, FileOps.SafeFileName(name))); } catch (Exception e) { Status = e.Message; }
        Reload();
    }

    async Task UploadAsync()
    {
        var files = await Dialogs.Current.PickFilesAsync("Choose files to add here", true);
        foreach (var f in files)
        {
            try { File.Copy(f, Path.Combine(Current, FileOps.SafeFileName(Path.GetFileName(f))), overwrite: false); }
            catch (Exception e) { Status = e.Message; }
        }
        Reload();
    }

    async Task RenameAsync()
    {
        if (Selected is not { } row) return;
        var name = await Dialogs.Current.PromptAsync("Rename", "New name", row.Name, "Rename");
        if (name is null) return;
        try
        {
            var dest = FileOps.Confine(Current, FileOps.SafeFileName(name));
            if (row.IsDir) Directory.Move(row.FullPath, dest); else File.Move(row.FullPath, dest);
        }
        catch (Exception e) { Status = e.Message; }
        Reload();
    }

    async Task DeleteAsync()
    {
        if (Selected is not { } row) return;
        if (_server.IsRunning && (row.Name is "world" || row.Name.EndsWith(".jar"))) { Status = "Stop the server before removing that."; return; }
        if (!await Dialogs.Current.ConfirmAsync($"Remove {row.Name}?", "It's moved to a trash folder inside the server folder, not permanently deleted.", "Move to trash", true)) return;
        try { FileOps.MoveToTrash(row.FullPath, Path.Combine(R.Path, ".craftpanel-trash")); Status = ""; } catch (Exception e) { Status = e.Message; }
        Selected = null; Reload();
    }
}
