namespace CraftPanel.Core;

/// <summary>How CraftPanel decided where to keep its files.</summary>
public enum DataMode
{
    /// <summary>The normal per-user folders (%APPDATA%\CraftPanel and %LOCALAPPDATA%\CraftPanel).</summary>
    Normal,
    /// <summary><c>portable.txt</c> sits next to the program: everything lives in <c>CraftPanelData</c> beside it (USB-stick friendly).</summary>
    Portable,
    /// <summary>The normal folders can't be written to (locked-down school/work PC), so <c>CraftPanelData</c> next to the program, or the temp folder, is used.</summary>
    Fallback,
    /// <summary>Set by a test or the <c>CRAFTPANEL_DATA</c> variable.</summary>
    Override,
}

/// <summary>Where CraftPanel keeps its own files. Tests point this at a temp folder.</summary>
public static class AppPaths
{
    public const string PortableMarker = "portable.txt";
    public const string PortableFolder = "CraftPanelData";

    /// <summary>Override for tests (set <c>CRAFTPANEL_DATA</c> or assign).</summary>
    public static string? DataOverride { get; set; } = Environment.GetEnvironmentVariable("CRAFTPANEL_DATA");

    /// <summary>
    /// Picks the data folder. Pure (everything the decision needs is passed in) so it can be tested:
    /// a <c>portable.txt</c> next to the program wins; else the per-user folder if it can be written; else a folder next
    /// to the program; else the temp folder as a last resort.
    /// </summary>
    public static (string Path, DataMode Mode) ChooseRoot(string perUserDir, string? exeDir, string tempDir, Func<string, bool> canWrite, Func<string, bool> fileExists)
    {
        if (exeDir is not null && fileExists(Path.Combine(exeDir, PortableMarker)))
            return (Path.Combine(exeDir, PortableFolder), DataMode.Portable);
        if (canWrite(perUserDir)) return (perUserDir, DataMode.Normal);
        if (exeDir is not null && canWrite(Path.Combine(exeDir, PortableFolder))) return (Path.Combine(exeDir, PortableFolder), DataMode.Fallback);
        return (Path.Combine(tempDir, PortableFolder), DataMode.Fallback);
    }

    /// <summary>Can files be created in this folder (creating it if needed)? Never throws.</summary>
    public static bool CanWrite(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var probe = Path.Combine(dir, ".write-test-" + Environment.ProcessId);
            File.WriteAllText(probe, "x");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    static (string Path, DataMode Mode)? _auto;
    static (string Path, DataMode Mode) Auto => _auto ??= ChooseRoot(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), FolderName),
        Path.GetDirectoryName(Environment.ProcessPath), Path.GetTempPath(), CanWrite, File.Exists);

    public static DataMode Mode => DataOverride is not null ? DataMode.Override : Auto.Mode;

    /// <summary>One line for the report and the health check: where files go and why.</summary>
    public static string ModeNote => Mode switch
    {
        DataMode.Portable => $"Portable mode ({PortableMarker} found next to the program): files are kept in {DataDir}.",
        DataMode.Fallback => $"This PC doesn't let CraftPanel write to its usual folders, so files are kept in {DataDir} instead.",
        DataMode.Override => $"Using a custom data folder: {DataDir}.",
        _ => $"Files are kept in {DataDir}.",
    };

    /// <summary>
    /// "CraftPanel" on Windows. Anywhere else (a Mac used for testing) a different name: on macOS .NET's AppData is
    /// ~/Library/Application Support, which is where the SwiftUI Mac app keeps its servers and its PIN lock.
    /// </summary>
    static string FolderName => OperatingSystem.IsMacOS() ? "CraftPanel Windows Edition" : "CraftPanel";

    /// <summary>Settings, server list, lock file: %APPDATA%\CraftPanel (or the portable/fallback folder).</summary>
    public static string DataDir => Ensure(DataOverride ?? Auto.Path);

    /// <summary>Big machine-local stuff (Java runtimes): %LOCALAPPDATA%\CraftPanel, or inside the data folder when portable/fallback.</summary>
    public static string LocalDir => Ensure(DataOverride is { } o ? Path.Combine(o, "local")
        : Auto.Mode == DataMode.Normal ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FolderName)
        : Path.Combine(Auto.Path, "local"));

    public static string JreRoot => Path.Combine(LocalDir, "jre");
    public static string ServersJson => Path.Combine(DataDir, "servers.json");
    public static string SettingsJson => Path.Combine(DataDir, "settings.json");
    public static string LogsDir => Ensure(Path.Combine(DataDir, "logs"));

    /// <summary>Where new servers go by default: Documents\CraftPanel Servers (or inside the data folder when that can't be written).</summary>
    public static string DefaultServersDir
    {
        get
        {
            if (Mode is DataMode.Portable or DataMode.Fallback) return Path.Combine(DataDir, "Servers");
            var docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) is { Length: > 0 } d ? Path.Combine(d, "CraftPanel Servers") : "";
            return docs.Length > 0 && CanWrite(docs) ? docs : Path.Combine(DataDir, "Servers");
        }
    }

    public static string Ensure(string dir) { Directory.CreateDirectory(dir); return dir; }
    public static string EnsureFolder(string dir) => Ensure(dir);

    /// <summary>Writes via a temp file + replace so a crash never leaves a half-written file.</summary>
    public static void WriteAtomic(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp-" + Environment.ProcessId;
        File.WriteAllText(tmp, text);
        File.Move(tmp, path, overwrite: true);
    }
}
