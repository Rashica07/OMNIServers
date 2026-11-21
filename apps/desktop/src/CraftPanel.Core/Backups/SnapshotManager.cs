using System.Text.Json;
using System.Text.Json.Serialization;

namespace CraftPanel.Core.Backups;

public sealed class Snapshot
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("created_at")] public long CreatedAt { get; set; }
    /// <summary>"manual" or "scheduled".</summary>
    [JsonPropertyName("trigger")] public string Trigger { get; set; } = "manual";
    /// <summary>Bytes actually written fresh for this snapshot — hard-linked files don't count, so this is the real disk cost.</summary>
    [JsonPropertyName("new_bytes")] public long NewBytes { get; set; }
    [JsonPropertyName("file_count")] public long FileCount { get; set; }
    /// <summary>"world" for a snapshot of just the world save; absent on older snapshots, which mirror the whole server folder.</summary>
    [JsonPropertyName("scope")] public string? Scope { get; set; }
    [JsonIgnore] public bool IsWorld => Scope == "world";
    [JsonIgnore] public DateTimeOffset Created => DateTimeOffset.FromUnixTimeSeconds(CreatedAt);
}

/// <summary>
/// "Time Machine" snapshots: cheap, frequent rollback points in <c>craftpanel-snapshots/&lt;id&gt;/</c> (same layout and JSON
/// as the Mac app). A snapshot is the current state of the world save — not the server's jars, mods or configs, that's what
/// zip backups are for. Files unchanged since the previous snapshot are hard-linked (same data on disk), so only what
/// changed costs space, and restoring swaps just the world.
/// </summary>
public static class SnapshotManager
{
    static readonly JsonSerializerOptions Json = new();

    public static string Root(string dir) => Path.Combine(dir, BackupManager.SnapshotDirName);

    /// <summary>
    /// The folders that make up the active world: the <c>level-name</c> folder, Paper's separate <c>_nether</c> / <c>_the_end</c>
    /// folders, and Bedrock's <c>worlds/&lt;level-name&gt;</c>. Only ones that exist; relative to the server folder.
    /// </summary>
    public static List<string> WorldFolders(string dir)
    {
        var level = Properties.Load(dir).GetOr("level-name", "world");
        if (level.Length == 0 || level.IndexOfAny(['/', '\\']) >= 0 || level is "." or "..") level = "world";
        return new[] { level, level + "_nether", level + "_the_end", "worlds/" + level }.Where(r => Directory.Exists(Path.Combine(dir, r))).ToList();
    }

    /// <summary>Every file of the active world, as paths relative to the server folder.</summary>
    public static List<string> CollectWorld(string dir)
    {
        var files = new List<string>();
        foreach (var root in WorldFolders(dir))
            foreach (var f in Directory.EnumerateFiles(Path.Combine(dir, root), "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }))
            {
                var rel = Path.GetRelativePath(dir, f).Replace('\\', '/');
                if (!BackupManager.Excluded(rel)) files.Add(rel);
            }
        return files;
    }

    /// <summary>Same cheap "did it change" test as the Mac app: size and modified time, no hashing.</summary>
    static bool Unchanged(FileInfo cur, FileInfo prev) =>
        cur.Length == prev.Length && Math.Abs((cur.LastWriteTimeUtc - prev.LastWriteTimeUtc).TotalMilliseconds) < 2;

    /// <summary>Copies a file a running server may hold open (read sharing), keeping its modified time so the next snapshot can link it.</summary>
    static void CopyShared(string src, string dst)
    {
        using (var s = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var d = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None))
            s.CopyTo(d);
        File.SetLastWriteTimeUtc(dst, File.GetLastWriteTimeUtc(src));
    }

    public static Snapshot SnapshotNow(string dir, string trigger, Action<string>? progress = null)
    {
        if (!Directory.Exists(dir)) throw new ProvisionException($"Server folder is missing: {dir}");
        var root = Directory.CreateDirectory(Root(dir)).FullName;
        var latest = List(dir).FirstOrDefault();
        var prevDir = latest is not null ? Path.Combine(root, latest.Id) : null;

        // Strictly after the previous snapshot, so order (and "what changed since the last one") is never ambiguous.
        var ts = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeSeconds(), (latest?.CreatedAt ?? 0) + 1);
        var id = $"{ts}-{Guid.NewGuid().ToString("N")[..6]}";
        var newDir = Directory.CreateDirectory(Path.Combine(root, id)).FullName;

        try
        {
            progress?.Invoke("Collecting the world…");
            var files = CollectWorld(dir);
            if (files.Count == 0) throw new ProvisionException("There's no world to snapshot yet — start the server once so it creates one.");
            progress?.Invoke($"Snapshotting {files.Count} files…");

            long newBytes = 0, count = 0;
            foreach (var rel in files)
            {
                var src = Path.Combine(dir, rel);
                var dest = Path.Combine(newDir, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                try
                {
                    var linked = false;
                    if (prevDir is not null)
                    {
                        var prev = new FileInfo(Path.Combine(prevDir, rel));
                        if (prev.Exists && Unchanged(new FileInfo(src), prev)) linked = HardLink.TryCreate(prev.FullName, dest);
                    }
                    if (!linked) { CopyShared(src, dest); newBytes += new FileInfo(dest).Length; }
                    count++;
                }
                catch (IOException) { /* a file the server locked exclusively: leave it out rather than fail the snapshot */ }
            }

            var meta = new Snapshot { Id = id, CreatedAt = ts, Trigger = trigger, NewBytes = newBytes, FileCount = count, Scope = "world" };
            File.WriteAllText(Path.Combine(root, id + ".json"), JsonSerializer.Serialize(meta, Json));
            progress?.Invoke("Done.");
            return meta;
        }
        catch { try { Directory.Delete(newDir, true); } catch { } throw; }
    }

    public static List<Snapshot> List(string dir)
    {
        var root = Root(dir);
        var list = new List<Snapshot>();
        if (!Directory.Exists(root)) return list;
        foreach (var j in Directory.EnumerateFiles(root, "*.json"))
        {
            try
            {
                var m = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(j), Json);
                // a snapshot whose folder is gone isn't restorable, so don't list it
                if (m is not null && Directory.Exists(Path.Combine(root, BackupManager.SanitizeId(m.Id)))) list.Add(m);
            }
            catch { }
        }
        return list.OrderByDescending(s => s.CreatedAt).ToList();
    }

    public static void Delete(string dir, string id)
    {
        id = BackupManager.SanitizeId(id);
        var target = Path.Combine(Root(dir), id);
        if (!Directory.Exists(target)) throw new ProvisionException("That snapshot no longer exists.");
        // Safe however many snapshots share the files: deleting one link leaves the data other snapshots still point at.
        ClearReadOnly(target);
        Directory.Delete(target, true);
        try { File.Delete(Path.Combine(Root(dir), id + ".json")); } catch { }
    }

    static void ClearReadOnly(string folder)
    {
        foreach (var f in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories))
            try { var a = File.GetAttributes(f); if ((a & FileAttributes.ReadOnly) != 0) File.SetAttributes(f, a & ~FileAttributes.ReadOnly); } catch { }
    }

    /// <summary>Everything from the last <paramref name="recentHours"/> hours, then the newest per day for <paramref name="dailyDays"/> days; older ones go.</summary>
    public static void Prune(string dir, int recentHours, int dailyDays)
    {
        var all = List(dir);
        if (all.Count == 0) return;
        var keep = Retention.TieredKeepIds(all.Select(s => (s.Id, s.CreatedAt)), DateTimeOffset.UtcNow.ToUnixTimeSeconds(), recentHours, dailyDays);
        foreach (var s in all.Where(s => !keep.Contains(s.Id))) try { Delete(dir, s.Id); } catch { }
    }

    /// <summary>
    /// Restores a snapshot. The server must be stopped. A world snapshot swaps only the world: the current world folders are
    /// moved aside (nothing is deleted, so it's undoable) and the snapshot's copied back; mods, configs and everything else
    /// stay as they are. Older snapshots that mirror the whole server restore the whole server, after a zip backup. If
    /// anything fails, what was there is put back.
    /// </summary>
    public static void Restore(string dir, string id, Action<string>? progress = null)
    {
        id = BackupManager.SanitizeId(id);
        var src = Path.Combine(Root(dir), id);
        if (!Directory.Exists(src)) throw new ProvisionException("That snapshot no longer exists.");
        var meta = List(dir).FirstOrDefault(s => s.Id == id);
        if (meta is { IsWorld: true }) RestoreWorld(dir, src, progress); else RestoreWholeServer(dir, src, progress);
    }

    static void RestoreWorld(string dir, string src, Action<string>? progress)
    {
        var stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var aside = Path.Combine(dir, BackupManager.PreRestorePrefix + stamp);
        var roots = SnapshotWorldRoots(src).ToList();   // world, world_nether, worlds/Name…
        var existed = roots.Where(r => Directory.Exists(Path.Combine(dir, r))).ToHashSet();
        var moved = new List<(string From, string To)>();

        // Put things back: drop whatever the snapshot copy created, then return the world folders that were moved aside.
        // A folder that was never moved (still the original) is left alone.
        void Rollback()
        {
            foreach (var r in roots)
            {
                var cur = Path.Combine(dir, r);
                if (!existed.Contains(r)) { try { if (Directory.Exists(cur)) Directory.Delete(cur, true); } catch { } }
            }
            foreach (var (from, to) in moved)
            {
                try { if (Directory.Exists(from)) Directory.Delete(from, true); Move(to, from); } catch { }
            }
            try { if (Directory.Exists(aside) && !Directory.EnumerateFileSystemEntries(aside, "*", SearchOption.AllDirectories).Any()) Directory.Delete(aside, true); } catch { }
        }

        progress?.Invoke("Moving the current world aside…");
        Directory.CreateDirectory(aside);
        // Bedrock's snapshot holds "worlds/<name>"; move that sub-folder, not the whole worlds folder.
        foreach (var rel in roots)
        {
            var cur = Path.Combine(dir, rel);
            if (!Directory.Exists(cur)) continue;
            var to = Path.Combine(aside, rel);
            try { Directory.CreateDirectory(Path.GetDirectoryName(to)!); Move(cur, to); moved.Add((cur, to)); }
            catch (Exception e) { Rollback(); throw new ProvisionException($"couldn't move {rel} aside: {e.Message}", e); }
        }

        progress?.Invoke("Copying the snapshot back…");
        try
        {
            foreach (var f in Directory.EnumerateFiles(src, "*", SearchOption.AllDirectories))
            {
                var dest = Path.Combine(dir, Path.GetRelativePath(src, f));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                // A fresh copy, deliberately not another hard link: the restored world stands alone from here on.
                CopyShared(f, dest);
            }
        }
        catch (Exception e) { Rollback(); throw new ProvisionException($"{e.Message} — your world was put back as it was.", e); }
        progress?.Invoke($"Restored. The previous world is in {Path.GetFileName(aside)}");
    }

    /// <summary>The world folders a world snapshot holds, relative to the server folder (world, world_nether, worlds/Name…).</summary>
    static IEnumerable<string> SnapshotWorldRoots(string snapshotDir)
    {
        foreach (var d in Directory.EnumerateDirectories(snapshotDir))
        {
            var name = Path.GetFileName(d);
            if (name == "worlds") { foreach (var w in Directory.EnumerateDirectories(d)) yield return "worlds/" + Path.GetFileName(w); }
            else yield return name;
        }
    }

    static void RestoreWholeServer(string dir, string src, Action<string>? progress)
    {
        progress?.Invoke("Backing up the current state first…");
        BackupManager.BackupNow(dir, "before restore", "pre-restore", progress);

        progress?.Invoke("Moving the current folder aside…");
        var stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var aside = Directory.CreateDirectory(Path.Combine(dir, BackupManager.PreRestorePrefix + stamp)).FullName;
        static bool IsInfra(string n) => n == BackupManager.BackupDirName || n == BackupManager.SnapshotDirName || n.StartsWith(BackupManager.PreRestorePrefix);

        void Rollback()
        {
            var failed = Directory.CreateDirectory(Path.Combine(dir, $"{BackupManager.PreRestorePrefix}failed-{stamp}")).FullName;
            foreach (var e in Directory.EnumerateFileSystemEntries(dir).ToList())
            {
                var n = Path.GetFileName(e);
                if (IsInfra(n)) continue;
                try { Move(e, Path.Combine(failed, n)); } catch { }
            }
            foreach (var e in Directory.EnumerateFileSystemEntries(aside).ToList())
                try { Move(e, Path.Combine(dir, Path.GetFileName(e))); } catch { }
            try { if (!Directory.EnumerateFileSystemEntries(aside).Any()) Directory.Delete(aside); } catch { }
        }

        foreach (var entry in Directory.EnumerateFileSystemEntries(dir).ToList())
        {
            var name = Path.GetFileName(entry);
            if (IsInfra(name)) continue;
            try { Move(entry, Path.Combine(aside, name)); }
            catch (Exception e) { Rollback(); throw new ProvisionException($"couldn't move {name} aside: {e.Message}", e); }
        }

        progress?.Invoke("Copying the snapshot back…");
        try
        {
            foreach (var f in Directory.EnumerateFiles(src, "*", SearchOption.AllDirectories))
            {
                var dest = Path.Combine(dir, Path.GetRelativePath(src, f));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                CopyShared(f, dest);
            }
        }
        catch (Exception e) { Rollback(); throw new ProvisionException($"{e.Message} — your server folder was put back as it was.", e); }
        progress?.Invoke($"Restored. The previous state is in {Path.GetFileName(aside)}");
    }

    static void Move(string from, string to) { if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to); }
}
