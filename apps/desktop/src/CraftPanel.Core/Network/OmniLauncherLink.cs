using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CraftPanel.Core.Network;

/// <summary>
/// The hand-off from OMNIServers to OMNI Launcher (the Minecraft launcher). Servers live here; playing lives there.
/// The app writes <c>join-request.json</c> into the launcher's data folder; the launcher, when it is open, picks it up
/// within a second and answers with its Join popup.
/// </summary>
public static class OmniLauncherLink
{
    public const string RequestFile = "join-request.json";

    /// <summary>What OMNIServers asks the launcher to join. Field names are the launcher's (<c>public_address</c>).</summary>
    public sealed record JoinRequest(string Name, string Address, string? PublicAddress, string Minecraft, long Created);

    public static string Encode(JoinRequest r)
    {
        var o = new JsonObject { ["name"] = r.Name, ["address"] = r.Address };
        if (!string.IsNullOrWhiteSpace(r.PublicAddress)) o["public_address"] = r.PublicAddress;
        o["minecraft"] = r.Minecraft;
        o["created"] = r.Created;
        return o.ToJsonString();
    }

    /// <summary>The launcher's data folder, the same one the launcher itself picks (<c>dirs::data_dir()/omni-launcher</c>). <c>HORIZON_LAUNCHER_HOME</c> overrides it, as it does there.</summary>
    public static string DataDir(string? home = null, string? xdgDataHome = null, string? appData = null, string? launcherHomeEnv = null)
    {
        launcherHomeEnv ??= Environment.GetEnvironmentVariable("HORIZON_LAUNCHER_HOME");
        if (!string.IsNullOrEmpty(launcherHomeEnv)) return launcherHomeEnv;
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (OperatingSystem.IsWindows())
            return Path.Combine(appData ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "omni-launcher");
        if (OperatingSystem.IsMacOS()) return Path.Combine(home, "Library", "Application Support", "omni-launcher");
        xdgDataHome ??= Environment.GetEnvironmentVariable("XDG_DATA_HOME");
        return Path.Combine(string.IsNullOrEmpty(xdgDataHome) ? Path.Combine(home, ".local", "share") : xdgDataHome, "omni-launcher");
    }

    /// <summary>A launcher started from source keeps its data in <c>~/.omni-launcher-dev</c>. It watches that folder, so requests go there too when it exists.</summary>
    public static string? DevDir(string? home = null)
    {
        var dir = Path.Combine(home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".omni-launcher-dev");
        return Directory.Exists(dir) ? dir : null;
    }

    /// <summary>Every folder a launcher may be watching.</summary>
    public static List<string> RequestDirs(string? home = null, string? xdgDataHome = null, string? appData = null, string? launcherHomeEnv = null)
    {
        var dirs = new List<string> { DataDir(home, xdgDataHome, appData, launcherHomeEnv) };
        if (DevDir(home) is { } dev && !dirs.Contains(dev)) dirs.Add(dev);
        return dirs;
    }

    /// <summary>Where the launcher program may be, best guess first. <c>OMNI_LAUNCHER_PATH</c> wins.</summary>
    public static List<string> CandidatePaths(string? home = null, string? localAppData = null, string? programFiles = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var list = new List<string>();
        if (Environment.GetEnvironmentVariable("OMNI_LAUNCHER_PATH") is { Length: > 0 } env) list.Add(env);
        if (OperatingSystem.IsWindows())
        {
            localAppData ??= Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            programFiles ??= Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            foreach (var root in new[] { Path.Combine(localAppData, "Programs"), programFiles, Path.Combine(home, "Downloads") })
                foreach (var folder in new[] { "OMNI Launcher", "OMNILauncher", "omni-launcher" })
                    list.Add(Path.Combine(root, folder, "omni-launcher.exe"));
        }
        else if (OperatingSystem.IsMacOS())
        {
            foreach (var root in new[] { "/Applications", Path.Combine(home, "Applications") })
                list.Add(Path.Combine(root, "OMNI Launcher.app"));
        }
        else
        {
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(':', StringSplitOptions.RemoveEmptyEntries))
                list.Add(Path.Combine(dir, "omni-launcher"));
            foreach (var root in new[] { Path.Combine(home, ".local", "bin"), Path.Combine(home, "Applications"), "/opt/omni-launcher", "/usr/local/bin", Path.Combine(home, "omni-launcher") })
                list.Add(Path.Combine(root, "omni-launcher"));
        }
        return list;
    }

    public static string? InstalledPath(Func<string, bool>? exists = null, IEnumerable<string>? candidates = null)
    {
        exists ??= p => File.Exists(p) || Directory.Exists(p);
        return (candidates ?? CandidatePaths()).FirstOrDefault(exists);
    }

    /// <summary>True while a launcher process is running, installed or started from source.</summary>
    public static bool IsRunning()
    {
        try { return Process.GetProcessesByName("omni-launcher").Length > 0; } catch { return false; }
    }

    /// <summary>Whether Play can go through the launcher: it is installed or running, and the server has a Minecraft version.</summary>
    public static bool CanPlay(string? minecraft, bool? installed = null) =>
        (installed ?? (InstalledPath() is not null || IsRunning())) && !string.IsNullOrWhiteSpace(minecraft);

    /// <summary>Writes the request into one folder, atomically so the launcher never reads half a file.</summary>
    public static void Write(JoinRequest r, string dir)
    {
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, RequestFile);
        var tmp = path + ".tmp-" + Environment.ProcessId;
        File.WriteAllText(tmp, Encode(r));
        File.Move(tmp, path, overwrite: true);
    }

    /// <summary>Writes the request to every folder a launcher may be watching. Throws only if none worked.</summary>
    public static void WriteEverywhere(JoinRequest r, IEnumerable<string>? dirs = null)
    {
        Exception? first = null;
        var wrote = false;
        foreach (var d in dirs ?? RequestDirs())
        {
            try { Write(r, d); wrote = true; } catch (Exception e) { first ??= e; }
        }
        if (!wrote && first is not null) throw first;
    }

    /// <summary>Opens the launcher program. False when it isn't installed (or won't start), so the caller can say so.</summary>
    public static bool Open()
    {
        if (InstalledPath() is not { } path) return false;
        try
        {
            if (OperatingSystem.IsMacOS()) Process.Start(new ProcessStartInfo("open", [path]) { UseShellExecute = false });
            else if (Directory.Exists(path)) return false;
            else Process.Start(new ProcessStartInfo(path) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(path) ?? "" });
            return true;
        }
        catch { return false; }
    }

    /// <summary>Asks the launcher to join this server and opens it. False when it could not be done, so the caller can fall back to showing the address.</summary>
    public static bool Play(string name, string address, string? publicAddress, string minecraft)
    {
        var request = new JoinRequest(name, address, publicAddress, minecraft, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        try { WriteEverywhere(request); } catch { return false; }
        return Open() || IsRunning();
    }
}
