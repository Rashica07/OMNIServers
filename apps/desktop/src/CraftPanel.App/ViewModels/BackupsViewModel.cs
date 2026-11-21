using System.Collections.ObjectModel;
using CraftPanel.App.Services;
using CraftPanel.Core;
using CraftPanel.Core.Backups;

namespace CraftPanel.App.ViewModels;

public sealed class BackupRow(Backup b)
{
    public Backup Backup { get; } = b;
    public string Id => Backup.Id;
    public string Title => Backup.Label ?? (Backup.Trigger switch { "pre-restore" => "Before a restore", "auto" => "Automatic backup", "scheduled" => "Scheduled backup", "imported" => "Imported backup", _ => "Backup" });
    public string When => Backup.Created.LocalDateTime.ToString("ddd d MMM yyyy, HH:mm");
    public string Size => Format(Backup.SizeBytes);
    public string TriggerLabel => Backup.Trigger;
    public bool IsImported => Backup.Trigger == "imported";
    public bool IsVerified => Backup.Verified == true;
    public bool IsBad => Backup.Verified == false;
    public bool IsUnverified => Backup.Verified is null;
    public static string Format(long b) => b >= 1L << 30 ? $"{b / (double)(1L << 30):0.0} GB" : b >= 1 << 20 ? $"{b / (double)(1 << 20):0.0} MB" : $"{Math.Max(1, b / 1024)} KB";
}

public sealed class SnapshotRow(Snapshot s)
{
    public string Id => s.Id;
    public string When => s.Created.LocalDateTime.ToString("ddd d MMM yyyy, HH:mm");
    public string Detail => $"{s.FileCount} files  ·  {(s.NewBytes == 0 ? "0 KB (linked)" : BackupRow.Format(s.NewBytes) + " new")}";
    public string Trigger => s.Trigger;
    public bool IsScheduled => s.Trigger == "scheduled";
    public bool IsWorld => s.IsWorld;
    /// <summary>Older snapshots mirror the whole server folder; say so, since restoring one replaces more than the world.</summary>
    public bool IsLegacy => !s.IsWorld;
}

public sealed class BackupsViewModel : ViewModelBase
{
    readonly ServerItemViewModel _server;
    string _status = "", _label = "";
    bool _busy;
    double _keep;

    public ObservableCollection<BackupRow> Backups { get; } = [];
    public ObservableCollection<SnapshotRow> Snapshots { get; } = [];
    ServerRecord R => _server.Record;

    public BackupsViewModel(ServerItemViewModel server)
    {
        _server = server;
        _keep = AppServices.Settings.BackupKeep;
        BackupNowCommand = new AsyncCommand(BackupNowAsync, () => !_busy);
        RestoreCommand = new AsyncCommand(RestoreAsync, _ => !_busy);
        VerifyCommand = new AsyncCommand(VerifyAsync, _ => !_busy);
        DeleteCommand = new AsyncCommand(DeleteAsync, _ => !_busy);
        OpenFolderCommand = new RelayCommand(() => Dialogs.Current.OpenFolder(BackupManager.Root(R.Path)));
        ImportCommand = new AsyncCommand(ImportAsync, () => !_busy);
        SnapshotNowCommand = new AsyncCommand(SnapshotNowAsync, () => !_busy);
        RestoreSnapshotCommand = new AsyncCommand(RestoreSnapshotAsync, _ => !_busy);
        DeleteSnapshotCommand = new AsyncCommand(DeleteSnapshotAsync, _ => !_busy);
        server.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ServerItemViewModel.IsRunning)) Raise(nameof(IsRunning)); };
        Reload();
    }

    public bool IsRunning => _server.IsRunning;
    public bool IsEmpty => Backups.Count == 0;
    public string Status { get => _status; private set { Set(ref _status, value); Raise(nameof(HasStatus)); } }
    public bool HasStatus => _status.Length > 0;
    public bool Busy { get => _busy; private set { if (Set(ref _busy, value)) { BackupNowCommand.RaiseCanExecuteChanged(); RestoreCommand.RaiseCanExecuteChanged(); VerifyCommand.RaiseCanExecuteChanged(); DeleteCommand.RaiseCanExecuteChanged(); ImportCommand.RaiseCanExecuteChanged(); SnapshotNowCommand.RaiseCanExecuteChanged(); RestoreSnapshotCommand.RaiseCanExecuteChanged(); DeleteSnapshotCommand.RaiseCanExecuteChanged(); } } }
    public bool NoSnapshots => Snapshots.Count == 0;
    public string SnapshotHint => "Snapshots of the world as it is right now. Files that haven't changed cost nothing, so this can run every few minutes — and a restore swaps only the world; your mods and settings stay. Set the schedule in the server's Settings.";
    public string Label { get => _label; set => Set(ref _label, value); }
    public double Keep { get => _keep; set { if (Set(ref _keep, value)) { AppServices.Settings.BackupKeep = (int)value; AppServices.Settings.Save(); } } }
    public string TotalSize => BackupRow.Format(Backups.Sum(b => b.Backup.SizeBytes));

    public AsyncCommand BackupNowCommand { get; }
    public AsyncCommand RestoreCommand { get; }
    public AsyncCommand VerifyCommand { get; }
    public AsyncCommand DeleteCommand { get; }
    public RelayCommand OpenFolderCommand { get; }
    public AsyncCommand ImportCommand { get; }
    public AsyncCommand SnapshotNowCommand { get; }
    public AsyncCommand RestoreSnapshotCommand { get; }
    public AsyncCommand DeleteSnapshotCommand { get; }

    public void Reload()
    {
        Snapshots.Clear();
        foreach (var sn in SnapshotManager.List(R.Path)) Snapshots.Add(new SnapshotRow(sn));
        Raise(nameof(NoSnapshots)); Raise(nameof(SnapshotHint));
        Backups.Clear();
        foreach (var b in BackupManager.List(R.Path)) Backups.Add(new BackupRow(b));
        Raise(nameof(IsEmpty)); Raise(nameof(TotalSize));
    }

    async Task BackupNowAsync()
    {
        Busy = true;
        var paused = false;
        try
        {
            if (IsRunning) { Status = "Saving the world…"; paused = await _server.Runtime.PauseSavesAsync(); }
            var label = string.IsNullOrWhiteSpace(Label) ? null : Label.Trim();
            var meta = await Task.Run(() => BackupManager.BackupNow(R.Path, label, "manual", m => Ui.Post(() => Status = m)));
            if (paused) { _server.Runtime.ResumeSaves(); paused = false; }
            Status = "Checking the backup…";
            var ok = await Task.Run(() => BackupManager.VerifyAndRecord(R.Path, meta.Id));
            await Task.Run(() => BackupManager.ApplyRetention(R.Path, AppServices.Settings));
            Label = "";
            Status = ok ? "Backup created and verified." : "Backup created, but verification failed — try again.";
            ToastService.Shared.Show(ok ? "Backup created" : "Backup may be damaged", R.Name, ok ? "check-circle" : "alert", ok ? "ok" : "warn");
        }
        catch (Exception e) { Status = "Backup failed: " + e.Message; ToastService.Shared.Error(Status); }
        finally { if (paused) _server.Runtime.ResumeSaves(); Busy = false; Reload(); }
    }

    async Task RestoreAsync(object? p)
    {
        if (p is not string id) return;
        if (IsRunning) { ToastService.Shared.Error("Stop the server before restoring a backup."); return; }
        if (!await Dialogs.Current.ConfirmAsync("Restore this backup?", "The server's current files are backed up first and moved aside, then this backup is extracted over them. If anything goes wrong, everything is put back.", "Restore", true)) return;
        Busy = true;
        try
        {
            await Task.Run(() => BackupManager.Restore(R.Path, id, m => Ui.Post(() => Status = m)));
            ToastService.Shared.Show("Backup restored", R.Name, "check-circle", "ok");
        }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); }
        finally { Busy = false; Reload(); }
    }

    async Task VerifyAsync(object? p)
    {
        if (p is not string id) return;
        Busy = true; Status = "Checking…";
        try { var ok = await Task.Run(() => BackupManager.VerifyAndRecord(R.Path, id)); Status = ok ? "This backup is intact." : "This backup is damaged."; }
        finally { Busy = false; Reload(); }
    }

    async Task DeleteAsync(object? p)
    {
        if (p is not string id) return;
        if (!await Dialogs.Current.ConfirmAsync("Delete this backup?", "This can't be undone.", "Delete", true)) return;
        try { BackupManager.Delete(R.Path, id); } catch (Exception e) { ToastService.Shared.Error(e.Message); }
        Reload();
    }

    async Task SnapshotNowAsync()
    {
        Busy = true;
        var paused = false;
        try
        {
            if (IsRunning) { Status = "Saving the world…"; paused = await _server.Runtime.PauseSavesAsync(); }
            await Task.Run(() => SnapshotManager.SnapshotNow(R.Path, "manual", m => Ui.Post(() => Status = m)));
            if (paused) { _server.Runtime.ResumeSaves(); paused = false; }
            Status = "Snapshot taken.";
            ToastService.Shared.Show("Snapshot taken", R.Name, "check-circle", "ok");
        }
        catch (Exception e) { Status = "Snapshot failed: " + e.Message; ToastService.Shared.Error(Status); }
        finally { if (paused) _server.Runtime.ResumeSaves(); Busy = false; Reload(); }
    }

    async Task RestoreSnapshotAsync(object? p)
    {
        if (p is not string id) return;
        if (IsRunning) { ToastService.Shared.Error("Stop the server before restoring a snapshot."); return; }
        var legacy = Snapshots.FirstOrDefault(x => x.Id == id)?.IsLegacy == true;
        var text = legacy
            ? "This older snapshot holds the whole server. The server's current files are backed up first and moved aside, then the snapshot is copied over them. If anything goes wrong, everything is put back."
            : "Only the world goes back. The current world is moved aside (not deleted) and this snapshot is copied in; your mods, plugins and settings stay as they are. If anything goes wrong, the current world is put back.";
        if (!await Dialogs.Current.ConfirmAsync("Go back to this snapshot?", text, "Restore", true)) return;
        Busy = true;
        try
        {
            await Task.Run(() => SnapshotManager.Restore(R.Path, id, m => Ui.Post(() => Status = m)));
            ToastService.Shared.Show("Snapshot restored", R.Name, "check-circle", "ok");
        }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); }
        finally { Busy = false; Reload(); }
    }

    async Task DeleteSnapshotAsync(object? p)
    {
        if (p is not string id) return;
        if (!await Dialogs.Current.ConfirmAsync("Delete this snapshot?", "Other snapshots aren't affected. This can't be undone.", "Delete", true)) return;
        try { await Task.Run(() => SnapshotManager.Delete(R.Path, id)); } catch (Exception e) { ToastService.Shared.Error(e.Message); }
        Reload();
    }

    /// <summary>
    /// Adds a backup someone else made (their .zip, ideally with its .json) to this server's list. You can pick both files
    /// together, or just the zip; a .json sitting next to it is found automatically.
    /// </summary>
    async Task ImportAsync()
    {
        var picked = await Dialogs.Current.PickFilesAsync("Choose the backup .zip (and its .json if you have it)", true);
        if (picked.Count == 0) return;
        var zip = picked.FirstOrDefault(f => f.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));
        if (zip is null) { ToastService.Shared.Error("Pick the backup's .zip file."); return; }
        var json = picked.FirstOrDefault(f => f.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) ?? BackupManager.SiblingJson(zip);

        BackupManager.ZipInspection info;
        try { info = await Task.Run(() => BackupManager.InspectZip(zip)); }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); return; }
        if (info.UnsafeEntry is not null || !info.LooksLikeAServer) { /* ImportBackup explains exactly why */ }
        else
        {
            var what = string.Join(", ", new[] { info.HasWorld ? "a world" : null, info.Mods > 0 ? $"{info.Mods} mods" : null, info.Plugins > 0 ? $"{info.Plugins} plugins" : null, info.HasServerProperties ? "server settings" : null }.Where(x => x is not null));
            var note = json is null ? "There's no .json with it, so it will be dated by the file." : "";
            if (!await Dialogs.Current.ConfirmAsync("Import this backup?",
                $"{Path.GetFileName(zip)}: {info.Entries} files, {BackupRow.Format(info.UncompressedBytes)} unpacked, with {what}. It's added to your list below; nothing changes on this server until you press Restore. {note}".Trim(), "Import")) return;
        }

        Busy = true;
        try
        {
            var meta = await Task.Run(() => BackupManager.ImportBackup(R.Path, zip, json, m => Ui.Post(() => Status = m)));
            Status = $"Imported. Press Restore next to it to put it on this server (your current files are backed up first).";
            ToastService.Shared.Show("Backup imported", meta.Verified == false ? "It may be damaged — check it before restoring." : "Verified. Press Restore to use it.", meta.Verified == false ? "alert" : "check-circle", meta.Verified == false ? "warn" : "ok");
        }
        catch (Exception e) { Status = e.Message; ToastService.Shared.Error(e.Message); }
        finally { Busy = false; Reload(); }
    }
}
