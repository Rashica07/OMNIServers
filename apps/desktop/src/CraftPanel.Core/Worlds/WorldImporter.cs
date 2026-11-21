using System.IO.Compression;
using System.Text;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Nbt;

namespace CraftPanel.Core.Worlds;

/// <summary>A world found in a folder or a zip, before anything is copied.</summary>
public sealed record FoundWorld(string Name, string Source, bool IsZip, string Root, string? McVersion, bool HasNether, bool HasEnd, long Bytes, long LastPlayedMs = 0)
{
    public string Dimensions => HasNether || HasEnd ? "with separate Nether/End folders" : "";
}

/// <summary>
/// Puts a world from somewhere else into a server: a folder, a .zip, or a single-player save. It finds the real world even
/// when it's one or two folders down (a zip with a top folder, <c>.minecraft\saves\Name</c>), copies it (never moves or
/// changes the original) under a safe, unused name, and says if it was made in a newer Minecraft than the server runs.
/// </summary>
public static class WorldImporter
{
    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "mods", "plugins", "config", "logs", "libraries", "versions", "crash-reports", "worlds", "cache", "datapacks",
        BackupManager.BackupDirName, BackupManager.SnapshotDirName,
    };
    const int MaxDepth = 2;

    // ---- looking inside ------------------------------------------------------------------------

    /// <summary>Works out what world a folder or zip holds. Throws a plain-language <see cref="ProvisionException"/> if it isn't one.</summary>
    public static FoundWorld Inspect(string path)
    {
        if (Directory.Exists(path)) return InspectFolder(path);
        if (File.Exists(path) && path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) return InspectZip(path);
        if (File.Exists(path) && path.EndsWith(".mcworld", StringComparison.OrdinalIgnoreCase)) throw new ProvisionException("That's a Bedrock world (.mcworld). OMNIServers only adds Java worlds to Java servers.");
        throw new ProvisionException("Pick a world folder, or a .zip with a world in it.");
    }

    static FoundWorld InspectFolder(string folder)
    {
        var roots = new List<string>();
        void Look(string dir, int depth)
        {
            if (File.Exists(Path.Combine(dir, "level.dat"))) { roots.Add(dir); return; }
            if (depth >= MaxDepth) return;
            try { foreach (var d in Directory.EnumerateDirectories(dir)) if (!Path.GetFileName(d).StartsWith('.')) Look(d, depth + 1); } catch { }
        }
        Look(folder, 0);
        roots = DropDimensionCompanions(roots, r => Path.GetFileName(r.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)));
        if (roots.Count == 0) throw new ProvisionException("There's no world in that folder (no level.dat). Pick the folder that has level.dat directly inside it — usually named after the world.");
        if (roots.Count > 1) throw new ProvisionException($"That folder holds {roots.Count} worlds ({string.Join(", ", roots.Take(4).Select(Path.GetFileName))}…). Pick the one world you want.");
        var root = roots[0];
        var name = Path.GetFileName(root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        var parent = Path.GetDirectoryName(root) ?? root;
        var (ver, played) = ReadLevel(File.ReadAllBytes(Path.Combine(root, "level.dat")));
        return new FoundWorld(name, folder, false, root, ver, Directory.Exists(Path.Combine(parent, name + "_nether")), Directory.Exists(Path.Combine(parent, name + "_the_end")), FolderBytes(root), played);
    }

    /// <summary>A Paper server folder has world, world_nether and world_the_end side by side; the last two aren't separate worlds.</summary>
    static List<string> DropDimensionCompanions(List<string> roots, Func<string, string> nameOf)
    {
        var names = roots.Select(nameOf).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return roots.Where(r => { var n = nameOf(r); return !((n.EndsWith("_nether", StringComparison.OrdinalIgnoreCase) && names.Contains(n[..^7])) || (n.EndsWith("_the_end", StringComparison.OrdinalIgnoreCase) && names.Contains(n[..^8]))); }).ToList();
    }

    static FoundWorld InspectZip(string zipPath)
    {
        BackupManager.ZipInspection insp;
        try { insp = BackupManager.InspectZip(zipPath); }
        catch (ProvisionException) { throw new ProvisionException("That file isn't a valid .zip."); }
        if (insp.UnsafeEntry is { } bad) throw new ProvisionException($"This zip contains a file that would land outside the server folder ({bad}), so OMNIServers won't use it.");
        using var zip = ZipFile.OpenRead(zipPath);
        var levels = zip.Entries.Where(e => e.FullName.Replace('\\', '/').EndsWith("level.dat", StringComparison.OrdinalIgnoreCase) && (e.FullName.Replace('\\', '/') == "level.dat" || e.FullName.Replace('\\', '/').EndsWith("/level.dat", StringComparison.OrdinalIgnoreCase)))
            .Select(e => (Entry: e, Dir: string.Join('/', e.FullName.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries)[..^1])))
            .Where(x => x.Dir.Split('/', StringSplitOptions.RemoveEmptyEntries).Length <= MaxDepth).ToList();
        var keep = DropDimensionCompanions(levels.Select(l => l.Dir).ToList(), d => d.Split('/')[^1]);
        levels = levels.Where(l => keep.Contains(l.Dir)).ToList();
        if (levels.Count == 0) throw new ProvisionException("There's no world in that zip (no level.dat). A world zip has a folder with level.dat inside.");
        var shallowest = levels.Min(l => l.Dir.Length == 0 ? 0 : l.Dir.Split('/').Length);
        var top = levels.Where(l => (l.Dir.Length == 0 ? 0 : l.Dir.Split('/').Length) == shallowest).ToList();
        if (top.Count > 1) throw new ProvisionException($"That zip holds {top.Count} worlds ({string.Join(", ", top.Take(4).Select(t => t.Dir))}…). Unzip it and pick the one world you want.");
        var root = top[0].Dir;
        var name = root.Length == 0 ? Path.GetFileNameWithoutExtension(zipPath) : root.Split('/')[^1];
        byte[] data;
        using (var s = top[0].Entry.Open()) { using var ms = new MemoryStream(); s.CopyTo(ms); data = ms.ToArray(); }
        var (ver, played) = ReadLevel(data);
        var parent = root.Contains('/') ? root[..root.LastIndexOf('/')] + "/" : "";
        bool Has(string suffix) => zip.Entries.Any(e => e.FullName.Replace('\\', '/').StartsWith(parent + name + suffix + "/", StringComparison.OrdinalIgnoreCase));
        return new FoundWorld(name, zipPath, true, root, ver, root.Length > 0 && Has("_nether"), root.Length > 0 && Has("_the_end"), insp.UncompressedBytes, played);
    }

    /// <summary>The Minecraft version and last-played time out of <c>level.dat</c> (null/0 when it can't be read).</summary>
    static (string? Version, long LastPlayed) ReadLevel(byte[] levelDat)
    {
        try
        {
            var f = Nbt.Nbt.ReadBytes(levelDat);
            var data = f.Root.Entries.FirstOrDefault(e => e.Key == "Data").Value as NbtCompound;
            string? ver = null; long played = 0;
            if (data?.Entries.FirstOrDefault(e => e.Key == "Version").Value is NbtCompound v && v.Entries.FirstOrDefault(e => e.Key == "Name").Value is NbtString n) ver = n.Value;
            if (data?.Entries.FirstOrDefault(e => e.Key == "LastPlayed").Value is NbtLong lp) played = lp.Value;
            return (ver, played);
        }
        catch { throw new ProvisionException("That world's level.dat can't be read, so it may be damaged."); }
    }

    static long FolderBytes(string dir)
    {
        long n = 0;
        try { foreach (var f in Directory.EnumerateFiles(dir, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint })) n += new FileInfo(f).Length; } catch { }
        return n;
    }

    // ---- versions ------------------------------------------------------------------------------

    /// <summary>Plain "1.21.4" / "26.2" style numbers as comparable parts; null for snapshots and anything else odd.</summary>
    public static int[]? ParseVersion(string? v)
    {
        if (string.IsNullOrWhiteSpace(v)) return null;
        var parts = v.Trim().Split('.');
        var nums = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++) if (!int.TryParse(parts[i], out nums[i])) return null;
        return nums;
    }

    /// <summary>A warning when the world was last saved by a newer Minecraft than the server runs (it won't open); null otherwise.</summary>
    public static string? VersionWarning(string? worldVersion, string? serverVersion)
    {
        var w = ParseVersion(worldVersion); var s = ParseVersion(serverVersion);
        if (w is null || s is null) return null;
        for (var i = 0; i < Math.Max(w.Length, s.Length); i++)
        {
            var a = i < w.Length ? w[i] : 0; var b = i < s.Length ? s[i] : 0;
            if (a > b) return $"This world was saved by Minecraft {worldVersion}, which is newer than this server ({serverVersion}). It won't open until you update the server (⋯ menu → Change version).";
            if (a < b) return null;
        }
        return null;
    }

    // ---- importing -----------------------------------------------------------------------------

    /// <summary>A folder name that's safe on Windows and not already taken in the server folder.</summary>
    public static string UniqueName(string serverDir, string wanted)
    {
        var sb = new StringBuilder();
        foreach (var c in wanted.Trim()) sb.Append(char.IsLetterOrDigit(c) || c is ' ' or '-' or '_' or '.' or '(' or ')' ? c : '_');
        var name = sb.ToString().Trim().Trim('.');
        if (name.Length == 0) name = "imported-world";
        if (name.Length > 60) name = name[..60].TrimEnd();
        if (Reserved.Contains(name) || name.StartsWith(BackupManager.PreRestorePrefix)) name += "-world";
        var final = name; var n = 2;
        while (Directory.Exists(Path.Combine(serverDir, final)) || File.Exists(Path.Combine(serverDir, final))
               || Directory.Exists(Path.Combine(serverDir, final + "_nether")) || Directory.Exists(Path.Combine(serverDir, final + "_the_end"))) final = $"{name}-{n++}";
        return final;
    }

    /// <summary>
    /// Copies the world into <paramref name="serverDir"/> and returns the folder name it got. Nothing is overwritten:
    /// if the name is taken, a number is added. Paper-style Nether/End folders next to it come along.
    /// </summary>
    public static string Import(string serverDir, FoundWorld w, Action<string>? progress = null)
    {
        if (!Directory.Exists(serverDir)) throw new ProvisionException($"Server folder is missing: {serverDir}");
        var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(serverDir))!).AvailableFreeSpace;
        if (free < w.Bytes + (w.Bytes / 10) + (200L << 20)) throw new ProvisionException($"Not enough free disk space to add this world ({w.Bytes / 1_048_576} MB needed).");
        var name = UniqueName(serverDir, w.Name);
        var made = new List<string>();
        try
        {
            progress?.Invoke("Copying the world…");
            if (w.IsZip) ExtractZip(w, serverDir, name, made); else CopyFolder(w, serverDir, name, made);
        }
        catch { foreach (var m in made) try { Directory.Delete(m, true); } catch { } throw; }
        return name;
    }

    static void CopyFolder(FoundWorld w, string serverDir, string name, List<string> made)
    {
        var parent = Path.GetDirectoryName(w.Root) ?? w.Root;
        foreach (var (from, to) in new[] { (w.Root, name), (Path.Combine(parent, w.Name + "_nether"), name + "_nether"), (Path.Combine(parent, w.Name + "_the_end"), name + "_the_end") })
        {
            if (!Directory.Exists(from)) continue;
            var dest = Path.Combine(serverDir, to);
            made.Add(dest);
            CopyTree(from, dest);
        }
    }

    static void CopyTree(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var d in Directory.EnumerateDirectories(from))
        {
            if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) != 0) continue;          // never follow links out of the folder
            CopyTree(d, Path.Combine(to, Path.GetFileName(d)));
        }
        foreach (var f in Directory.EnumerateFiles(from))
        {
            var n = Path.GetFileName(f);
            if (n is "session.lock" or ".DS_Store" or "Thumbs.db" || (File.GetAttributes(f) & FileAttributes.ReparsePoint) != 0) continue;
            using var src = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var dst = new FileStream(Path.Combine(to, n), FileMode.CreateNew, FileAccess.Write);
            src.CopyTo(dst);
        }
    }

    static void ExtractZip(FoundWorld w, string serverDir, string name, List<string> made)
    {
        using var zip = ZipFile.OpenRead(w.Source);
        var prefix = w.Root.Length == 0 ? "" : w.Root + "/";
        var parent = w.Root.Contains('/') ? w.Root[..w.Root.LastIndexOf('/')] + "/" : "";
        var maps = new List<(string From, string To)> { (prefix, name) };
        if (w.Root.Length > 0) { maps.Add((parent + w.Name + "_nether/", name + "_nether")); maps.Add((parent + w.Name + "_the_end/", name + "_the_end")); }
        foreach (var e in zip.Entries)
        {
            var n = e.FullName.Replace('\\', '/');
            if (n.EndsWith('/') || e.Name is "session.lock" or ".DS_Store" or "Thumbs.db") continue;
            foreach (var (from, to) in maps)
            {
                if (!n.StartsWith(from, StringComparison.OrdinalIgnoreCase)) continue;
                var rel = n[from.Length..];
                var dest = FileOps.Confine(Path.Combine(serverDir, to), rel);       // refuses anything that climbs out
                var top = Path.Combine(serverDir, to);
                if (!made.Contains(top)) made.Add(top);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                e.ExtractToFile(dest, overwrite: false);
                break;
            }
        }
    }

    // ---- single-player worlds ------------------------------------------------------------------

    public static string DefaultSavesFolder()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return OperatingSystem.IsWindows() ? Path.Combine(appData, ".minecraft", "saves")
            : OperatingSystem.IsMacOS() ? Path.Combine(appData, "minecraft", "saves") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".minecraft", "saves");
    }

    /// <summary>Worlds in the normal Minecraft (single-player) saves folder, newest first. Empty if there isn't one.</summary>
    public static List<FoundWorld> FindSingleplayerWorlds(string? savesDir = null)
    {
        var list = new List<FoundWorld>();
        savesDir ??= DefaultSavesFolder();
        if (!Directory.Exists(savesDir)) return list;
        foreach (var d in Directory.EnumerateDirectories(savesDir))
        {
            try { if (File.Exists(Path.Combine(d, "level.dat"))) list.Add(InspectFolder(d)); } catch (ProvisionException) { }
        }
        return list.OrderByDescending(w => w.LastPlayedMs).ToList();
    }

    // ---- exporting -----------------------------------------------------------------------------

    /// <summary>
    /// Zips the active world (plus Paper's Nether/End folders) to <paramref name="folder"/> (default: the Desktop). The zip
    /// has the world folder at its top, so it can be added to another server with "Add a world" as it is.
    /// </summary>
    public static string Export(string serverDir, string? folder = null, Action<string>? progress = null)
    {
        var roots = SnapshotManager.WorldFolders(serverDir);
        if (roots.Count == 0) throw new ProvisionException("There's no world to export yet — start the server once so it creates one.");
        folder ??= Diagnostics.ReportBuilder.DefaultFolder();
        Directory.CreateDirectory(folder);
        var level = roots[0].Contains('/') ? roots[0][(roots[0].IndexOf('/') + 1)..] : roots[0];
        var path = Path.Combine(folder, $"{level}-{DateTime.Now:yyyy-MM-dd-HHmm}.zip");
        progress?.Invoke("Zipping the world…");
        try
        {
            using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
            foreach (var rel in SnapshotManager.CollectWorld(serverDir))
            {
                try
                {
                    using var src = new FileStream(Path.Combine(serverDir, rel), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    var e = zip.CreateEntry(rel, CompressionLevel.Optimal);
                    e.LastWriteTime = File.GetLastWriteTime(Path.Combine(serverDir, rel));
                    using var dst = e.Open();
                    src.CopyTo(dst);
                }
                catch (IOException) { /* a file the server holds exclusively: skip it rather than fail */ }
            }
        }
        catch { try { File.Delete(path); } catch { } throw; }
        return path;
    }
}
