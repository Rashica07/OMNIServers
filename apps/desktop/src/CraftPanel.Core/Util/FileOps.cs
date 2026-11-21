namespace CraftPanel.Core;

public static class FileOps
{
    /// <summary>A file name that's safe to create inside a folder: no separators, no traversal, no reserved names.</summary>
    public static string SafeFileName(string name)
    {
        var n = Path.GetFileName(name.Replace('\\', '/'));
        if (n.Length == 0 || n is "." or ".." || n.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || n != name.Trim())
            throw new ProvisionException($"Unsafe file name: {name}");
        return n;
    }

    /// <summary>Resolves <paramref name="relative"/> inside <paramref name="root"/>; throws if it escapes (.. or symlink-style tricks).</summary>
    public static string Confine(string root, string relative)
    {
        var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(Path.Combine(root, relative.TrimStart('/', '\\')));
        if (!(full + Path.DirectorySeparatorChar).StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
            throw new ProvisionException("That path is outside the server folder.");
        return full;
    }

    /// <summary>Moves into a trash folder next to it instead of deleting (never a hard delete).</summary>
    public static string MoveToTrash(string path, string trashDir)
    {
        Directory.CreateDirectory(trashDir);
        var dest = Path.Combine(trashDir, $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{Path.GetFileName(path)}");
        var i = 1;
        while (File.Exists(dest) || Directory.Exists(dest)) dest = Path.Combine(trashDir, $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{i++}-{Path.GetFileName(path)}");
        if (Directory.Exists(path)) Directory.Move(path, dest); else File.Move(path, dest);
        return dest;
    }
}
