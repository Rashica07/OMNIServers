using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CraftPanel.Core.Backups;

public sealed class Backup
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("created_at")] public long CreatedAt { get; set; }
    [JsonPropertyName("size_bytes")] public long SizeBytes { get; set; }
    [JsonPropertyName("label")] public string? Label { get; set; }
    [JsonPropertyName("trigger")] public string Trigger { get; set; } = "manual";
    [JsonPropertyName("verified")] public bool? Verified { get; set; }
    /// <summary>SHA-256 of the zip as it was when imported from elsewhere; lets us refuse the same file twice. Absent on backups made here.</summary>
    [JsonPropertyName("source_sha256")] public string? SourceSha256 { get; set; }
    [JsonIgnore] public DateTimeOffset Created => DateTimeOffset.FromUnixTimeSeconds(CreatedAt);
}

/// <summary>Backups are zips in <c>craftpanel-backups/</c> with a JSON sidecar — the same layout the Mac app uses.</summary>
public static class BackupManager
{
    public const string BackupDirName = "craftpanel-backups";
    public const string SnapshotDirName = "craftpanel-snapshots";
    public const string PreRestorePrefix = ".craftpanel-pre-restore-";
    static readonly JsonSerializerOptions Json = new();

    public static string Root(string dir) => Path.Combine(dir, BackupDirName);

    /// <summary>What a backup leaves out: our own backup/snapshot folders, logs, crash reports, lock files, trash and staging.</summary>
    public static bool Excluded(string rel)
    {
        var l = rel.Replace('\\', '/').ToLowerInvariant();
        return l == BackupDirName || l.StartsWith(BackupDirName + "/") || l == SnapshotDirName || l.StartsWith(SnapshotDirName + "/")
            || l.StartsWith(PreRestorePrefix) || l == "logs" || l.StartsWith("logs/") || l == "crash-reports" || l.StartsWith("crash-reports/")
            || l.StartsWith(".craftpanel-trash/") || l.StartsWith(".craftpanel-staging-") || l == ".craftpanel-session.json"
            || l.EndsWith(".lock") || l.EndsWith("/.ds_store") || l == ".ds_store" || l == "thumbs.db";
    }

    public static List<string> Collect(string dir)
    {
        var files = new List<string>();
        foreach (var f in Directory.EnumerateFiles(dir, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }))
        {
            var rel = Path.GetRelativePath(dir, f).Replace('\\', '/');
            if (rel.Length > 0 && !Excluded(rel)) files.Add(rel);
        }
        return files;
    }

    static string NewId(long ts) => $"{ts}-{Guid.NewGuid().ToString("N")[..6]}";

    public static string SanitizeId(string id)
    {
        if (id.Length == 0 || !id.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')) throw new ProvisionException("Invalid backup id.");
        return id;
    }

    public static Backup BackupNow(string dir, string? label, string trigger, Action<string>? progress = null)
    {
        if (!Directory.Exists(dir)) throw new ProvisionException($"Server folder is missing: {dir}");
        var root = Directory.CreateDirectory(Root(dir)).FullName;
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var id = NewId(ts);
        progress?.Invoke("Collecting files…");
        var files = Collect(dir);
        progress?.Invoke($"Compressing {files.Count} files…");
        var zipPath = Path.Combine(root, id + ".zip");
        try
        {
            using (var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create))
                foreach (var rel in files)
                {
                    try
                    {
                        // FileShare.ReadWrite: a running server holds its world files open.
                        using var src = new FileStream(Path.Combine(dir, rel), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                        var e = zip.CreateEntry(rel, CompressionLevel.Optimal);
                        e.LastWriteTime = File.GetLastWriteTime(Path.Combine(dir, rel));
                        using var dst = e.Open();
                        src.CopyTo(dst);
                    }
                    catch (IOException) { /* a file the server locked exclusively: skip it rather than fail the whole backup */ }
                }
        }
        catch { try { File.Delete(zipPath); } catch { } throw; }
        var meta = new Backup { Id = id, CreatedAt = ts, SizeBytes = new FileInfo(zipPath).Length, Label = string.IsNullOrWhiteSpace(label) ? null : label, Trigger = trigger };
        WriteSidecar(root, meta);
        progress?.Invoke("Done.");
        return meta;
    }

    // ---- import (a backup made somewhere else: another PC, another person) ------------------------------------

    /// <summary>What's inside a zip, found out before anything is copied.</summary>
    public sealed record ZipInspection(int Entries, long UncompressedBytes, bool HasServerProperties, bool HasWorld, int Mods, int Plugins, string? UnsafeEntry)
    {
        public bool LooksLikeAServer => HasServerProperties || HasWorld || Mods > 0 || Plugins > 0;
    }

    /// <summary>An entry name that could write outside the server folder, or into OMNIServers's own folders. Null if it's fine.</summary>
    internal static bool IsUnsafeEntry(string name)
    {
        var n = name.Replace('\\', '/');
        if (n.StartsWith('/') || n.Contains(':') || n.Contains('\0')) return true;
        var segs = n.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segs.Any(x => x == "..")) return true;
        var first = segs.FirstOrDefault() ?? "";
        return first.Equals(BackupDirName, StringComparison.OrdinalIgnoreCase) || first.Equals(SnapshotDirName, StringComparison.OrdinalIgnoreCase)
            || first.StartsWith(PreRestorePrefix, StringComparison.OrdinalIgnoreCase);
    }

    public static ZipInspection InspectZip(string zipPath)
    {
        try
        {
            using var zip = ZipFile.OpenRead(zipPath);
            long bytes = 0; int mods = 0, plugins = 0; bool props = false, world = false; string? bad = null;
            foreach (var e in zip.Entries)
            {
                if (IsUnsafeEntry(e.FullName)) bad ??= e.FullName;
                bytes += e.Length;
                var n = e.FullName.Replace('\\', '/').ToLowerInvariant();
                if (n == "server.properties") props = true;
                if (n.EndsWith("/level.dat") || n == "level.dat" || n.StartsWith("world/") || n.StartsWith("worlds/")) world = true;
                if (n.StartsWith("mods/") && n.EndsWith(".jar")) mods++;
                if (n.StartsWith("plugins/") && n.EndsWith(".jar")) plugins++;
            }
            return new ZipInspection(zip.Entries.Count, bytes, props, world, mods, plugins, bad);
        }
        catch (InvalidDataException) { throw new ProvisionException("That file isn't a valid .zip backup."); }
        catch (IOException e) { throw new ProvisionException("Couldn't read that file: " + e.Message, e); }
    }

    /// <summary>The timestamp, label and so on a backup's .json says about it; tolerant of a missing, damaged or odd file.</summary>
    static Backup? ReadSidecarLeniently(string? jsonPath)
    {
        if (jsonPath is null || !File.Exists(jsonPath) || new FileInfo(jsonPath).Length > 64 * 1024) return null;
        try { return JsonSerializer.Deserialize<Backup>(File.ReadAllText(jsonPath), Json); } catch { return null; }
    }

    /// <summary>The .json that goes with a zip, if it's next to it under the same name.</summary>
    public static string? SiblingJson(string zipPath)
    {
        var j = Path.ChangeExtension(zipPath, ".json");
        return File.Exists(j) ? j : null;
    }

    /// <summary>
    /// Adds a backup made elsewhere (its .zip, and its .json if there is one) to this server's list. The zip is checked for
    /// unsafe paths and for being a real archive, copied in under a fresh id, and listed as "imported". Nothing about the
    /// server changes until you restore it. Importing the same file twice is refused.
    /// </summary>
    public static Backup ImportBackup(string dir, string zipPath, string? jsonPath = null, Action<string>? progress = null)
    {
        if (!Directory.Exists(dir)) throw new ProvisionException($"Server folder is missing: {dir}");
        if (!File.Exists(zipPath)) throw new ProvisionException("That backup file doesn't exist.");
        progress?.Invoke("Checking the backup…");
        var info = InspectZip(zipPath);
        if (info.UnsafeEntry is { } bad) throw new ProvisionException($"This backup contains a file that would land outside the server folder ({bad}), so OMNIServers won't import it.");
        if (info.Entries == 0 || !info.LooksLikeAServer) throw new ProvisionException("That zip doesn't look like a Minecraft server backup (no server.properties, world, mods or plugins in it).");

        var hash = Http.Sha256Hex(zipPath);
        if (List(dir).FirstOrDefault(b => b.SourceSha256 == hash) is { } dup)
            throw new ProvisionException($"You've already imported this backup ({dup.Created.LocalDateTime:d MMM yyyy, HH:mm}).");

        var root = Directory.CreateDirectory(Root(dir)).FullName;
        var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(root))!).AvailableFreeSpace;
        var size = new FileInfo(zipPath).Length;
        if (free < size + (256L << 20)) throw new ProvisionException($"Not enough free disk space to import this backup ({size / 1048576} MB needed).");

        var side = ReadSidecarLeniently(jsonPath);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        // Keep the time it was originally made (so the list stays in order) if the .json gives a believable one; else the file's own date.
        var created = side is { CreatedAt: > 946_684_800 } s && s.CreatedAt <= now + 86400 ? s.CreatedAt : new DateTimeOffset(File.GetLastWriteTimeUtc(zipPath)).ToUnixTimeSeconds();
        var id = NewId(created);
        var dest = Path.Combine(root, id + ".zip");
        progress?.Invoke("Copying it in…");
        try { File.Copy(zipPath, dest, overwrite: false); }
        catch { try { File.Delete(dest); } catch { } throw; }

        var label = side?.Label is { Length: > 0 } l ? new string(l.Where(c => !char.IsControl(c)).Take(80).ToArray()) : null;
        var meta = new Backup { Id = id, CreatedAt = created, SizeBytes = size, Label = string.IsNullOrWhiteSpace(label) ? null : label, Trigger = "imported", SourceSha256 = hash };
        WriteSidecar(root, meta);
        progress?.Invoke("Checking it's not damaged…");
        VerifyAndRecord(dir, id);
        progress?.Invoke("Done.");
        return List(dir).First(b => b.Id == id);
    }

    static void WriteSidecar(string root, Backup m) => File.WriteAllText(Path.Combine(root, m.Id + ".json"), JsonSerializer.Serialize(m, Json));

    public static List<Backup> List(string dir)
    {
        var root = Root(dir);
        var list = new List<Backup>();
        if (!Directory.Exists(root)) return list;
        foreach (var j in Directory.EnumerateFiles(root, "*.json"))
        {
            try
            {
                var m = JsonSerializer.Deserialize<Backup>(File.ReadAllText(j), Json);
                var zip = Path.Combine(root, m!.Id + ".zip");
                if (!File.Exists(zip)) continue;
                m.SizeBytes = new FileInfo(zip).Length;
                list.Add(m);
            }
            catch { }
        }
        return list.OrderByDescending(b => b.CreatedAt).ToList();
    }

    public static void Delete(string dir, string id)
    {
        id = SanitizeId(id);
        var zip = Path.Combine(Root(dir), id + ".zip");
        if (!File.Exists(zip)) throw new ProvisionException("That backup no longer exists.");
        File.Delete(zip);
        try { File.Delete(Path.Combine(Root(dir), id + ".json")); } catch { }
    }

    public static void Prune(string dir, int keep)
    {
        if (keep <= 0) return;
        foreach (var old in List(dir).Where(b => b.Trigger is not ("pre-restore" or "imported")).Skip(keep)) try { Delete(dir, old.Id); } catch { }
    }

    public static void PruneTiered(string dir, int recentHours, int dailyDays, long? now = null)
    {
        var prunable = List(dir).Where(b => b.Trigger is not ("pre-restore" or "imported")).ToList();
        var keep = Retention.TieredKeepIds(prunable.Select(b => (b.Id, b.CreatedAt)), now ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds(), recentHours, dailyDays);
        foreach (var b in prunable.Where(b => !keep.Contains(b.Id))) try { Delete(dir, b.Id); } catch { }
    }

    public static void ApplyRetention(string dir, AppSettings s)
    {
        if (s.BackupTiered) PruneTiered(dir, 24, 7); else Prune(dir, s.BackupKeep);
    }

    /// <summary>Reads every entry to make sure the archive isn't corrupt, and records the result in the sidecar.</summary>
    public static bool VerifyAndRecord(string dir, string id)
    {
        id = SanitizeId(id);
        var root = Root(dir);
        var ok = true;
        try
        {
            using var zip = ZipFile.OpenRead(Path.Combine(root, id + ".zip"));
            var buf = new byte[81920];
            foreach (var e in zip.Entries)
            {
                using var s = e.Open();
                while (s.Read(buf, 0, buf.Length) > 0) { }
            }
        }
        catch { ok = false; }
        var sidecar = Path.Combine(root, id + ".json");
        try
        {
            var m = JsonSerializer.Deserialize<Backup>(File.ReadAllText(sidecar), Json)!;
            m.Verified = ok;
            WriteSidecar(root, m);
        }
        catch { }
        return ok;
    }

    /// <summary>
    /// Restores a backup: backs up the current state first, moves the current files aside, extracts, and rolls back if anything fails.
    /// </summary>
    public static void Restore(string dir, string id, Action<string>? progress = null)
    {
        id = SanitizeId(id);
        var zipPath = Path.Combine(Root(dir), id + ".zip");
        if (!File.Exists(zipPath)) throw new ProvisionException("That backup no longer exists.");

        progress?.Invoke("Backing up the current state first…");
        BackupNow(dir, "before restore", "pre-restore", progress);

        progress?.Invoke("Moving the current folder aside…");
        var stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var aside = Directory.CreateDirectory(Path.Combine(dir, PreRestorePrefix + stamp)).FullName;
        bool IsInfra(string name) => name == BackupDirName || name == SnapshotDirName || name.StartsWith(PreRestorePrefix);

        void Rollback()
        {
            var failed = Directory.CreateDirectory(Path.Combine(dir, $"{PreRestorePrefix}failed-{stamp}")).FullName;
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

        progress?.Invoke("Extracting the backup…");
        try { ZipFile.ExtractToDirectory(zipPath, dir, overwriteFiles: true); }
        catch (Exception e) { Rollback(); throw new ProvisionException($"{e.Message} — your server folder was put back as it was.", e); }
        progress?.Invoke($"Restored. The previous state is in {Path.GetFileName(aside)}");
    }

    static void Move(string from, string to) { if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to); }
}

public static class Retention
{
    /// <summary>Everything from the last <paramref name="recentHours"/>, plus the newest one per day for <paramref name="dailyDays"/> days.</summary>
    public static HashSet<string> TieredKeepIds(IEnumerable<(string Id, long CreatedAt)> items, long now, int recentHours, int dailyDays)
    {
        var recentCutoff = now - recentHours * 3600L;
        var nowDay = FloorDiv(now, 86400);
        var keep = new HashSet<string>();
        var bestPerDay = new Dictionary<long, (string Id, long CreatedAt)>();
        foreach (var s in items)
        {
            if (s.CreatedAt >= recentCutoff) { keep.Add(s.Id); continue; }
            var day = FloorDiv(s.CreatedAt, 86400);
            if (nowDay - day > dailyDays) continue;
            if (bestPerDay.TryGetValue(day, out var cur) && cur.CreatedAt >= s.CreatedAt) continue;
            bestPerDay[day] = s;
        }
        foreach (var b in bestPerDay.Values) keep.Add(b.Id);
        return keep;
    }

    public static long FloorDiv(long a, long b) { var q = a / b; return a % b != 0 && (a < 0) != (b < 0) ? q - 1 : q; }
}
