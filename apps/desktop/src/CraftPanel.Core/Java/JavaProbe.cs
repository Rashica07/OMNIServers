namespace CraftPanel.Core.Java;

public sealed record JavaInfo(string Path, string Raw, uint Major, bool Is64Bit);

/// <summary>Java runtime detection and Minecraft-version compatibility checks.</summary>
public static class JavaProbe
{
    /// <summary>Probe a Java executable (<c>java</c> = off PATH). Null on any failure — no JDK is a normal state.</summary>
    public static async Task<JavaInfo?> ProbeAsync(string? exe = null, CancellationToken ct = default)
    {
        exe = string.IsNullOrWhiteSpace(exe) ? "java" : exe;
        var r = await Proc.RunAsync(exe, ["-version"], timeout: TimeSpan.FromSeconds(10), ct: ct);
        if (r is null) return null;
        // `java -version` prints to stderr.
        var text = r.StdErr.Length > 0 ? r.StdErr : r.StdOut;
        var major = ParseMajor(text);
        if (major is null) return null;
        var first = text.Split('\n').FirstOrDefault()?.Trim() ?? "";
        return new JavaInfo(exe, first, major.Value, text.Contains("64-Bit"));
    }

    /// <summary><c>1.8.0_361</c> → 8, <c>17.0.8</c> → 17, <c>21</c> → 21.</summary>
    public static uint? ParseMajor(string text)
    {
        var q1 = text.IndexOf('"');
        if (q1 < 0) return null;
        var rest = text[(q1 + 1)..];
        var q2 = rest.IndexOf('"');
        if (q2 < 0) return null;
        var parts = rest[..q2].Split('.', '_', '-', '+');
        if (parts.Length == 0) return null;
        if (parts[0] == "1") return parts.Length > 1 && uint.TryParse(parts[1], out var s) ? s : null;
        return uint.TryParse(parts[0], out var m) ? m : null;
    }

    /// <summary>Minimum Java feature version Mojang requires for a Minecraft version (year-based 26.x needs 25).</summary>
    public static uint RequiredJava(string mcVersion)
    {
        var (major, minor, patch) = ParseMc(mcVersion);
        if (major != 1) return major >= 26 ? 25u : 21u;
        return minor switch
        {
            <= 16 => 8,
            17 => 16,
            18 or 19 => 17,
            20 => patch <= 4 ? 17u : 21u,
            _ => 21,
        };
    }

    public static string? CompatibilityWarning(JavaInfo java, string? mcVersion)
    {
        if (mcVersion is null) return null;
        var need = RequiredJava(mcVersion);
        if (java.Major < need)
            return $"Minecraft {mcVersion} needs Java {need}+, but the detected runtime is Java {java.Major}. The server will fail to start until you install a newer JDK.";
        if (java.Major > need + 4 && need <= 8)
            return $"Minecraft {mcVersion} expects Java {need}. Java {java.Major} usually still works but is untested by Mojang for this version.";
        return null;
    }

    static (uint, uint, uint) ParseMc(string v)
    {
        var p = v.Trim().Split('.').Select(s => uint.TryParse(new string(s.TakeWhile(char.IsAsciiDigit).ToArray()), out var n) ? n : 0u).ToArray();
        return (p.Length > 0 ? p[0] : 0, p.Length > 1 ? p[1] : 0, p.Length > 2 ? p[2] : 0);
    }

    // ---- finding installed runtimes ------------------------------------------------

    /// <summary>Candidate java executables: CraftPanel-managed, JAVA_HOME, then the usual vendor folders.</summary>
    public static IEnumerable<string> CandidatePaths()
    {
        foreach (var f in JavaInstaller.Features)
            if (JavaInstaller.InstalledPath(f) is { } p) yield return p;
        if (Environment.GetEnvironmentVariable("JAVA_HOME") is { Length: > 0 } jh)
        {
            var e = Path.Combine(jh, "bin", "java" + Platform.ExeSuffix);
            if (File.Exists(e)) yield return e;
        }
        if (Platform.IsWindows)
        {
            var roots = new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 }
                .Select(Environment.GetFolderPath)
                .Concat([Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs")]);
            var vendors = new[] { "Eclipse Adoptium", "Java", "Microsoft", "Zulu", "Amazon Corretto", "BellSoft", "Semeru", "AdoptOpenJDK", "Eclipse Foundation" };
            foreach (var root in roots)
                foreach (var v in vendors)
                {
                    var dir = Path.Combine(root, v);
                    if (!Directory.Exists(dir)) continue;
                    foreach (var sub in Directory.EnumerateDirectories(dir))
                    {
                        var e = Path.Combine(sub, "bin", "java.exe");
                        if (File.Exists(e)) yield return e;
                    }
                }
        }
        else if (Platform.IsMac)
        {
            const string jvms = "/Library/Java/JavaVirtualMachines";
            if (Directory.Exists(jvms))
                foreach (var d in Directory.EnumerateDirectories(jvms))
                {
                    var e = Path.Combine(d, "Contents", "Home", "bin", "java");
                    if (File.Exists(e)) yield return e;
                }
        }
    }

    public static async Task<List<JavaInfo>> ListRuntimesAsync(CancellationToken ct = default)
    {
        var found = new List<JavaInfo>();
        foreach (var p in CandidatePaths().Distinct(StringComparer.OrdinalIgnoreCase))
            if (await ProbeAsync(p, ct) is { } i) found.Add(i);
        if (await ProbeAsync("java", ct) is { } onPath && found.All(f => f.Major != onPath.Major)) found.Add(onPath);
        return found.OrderByDescending(j => j.Major).ToList();
    }

    /// <summary>An installed runtime that meets <paramref name="required"/> (smallest sufficient major), or null.</summary>
    public static async Task<string?> FindCompatibleAsync(uint required, CancellationToken ct = default)
    {
        var all = await ListRuntimesAsync(ct);
        return all.Where(j => j.Major >= required).OrderBy(j => j.Major).FirstOrDefault()?.Path;
    }

    /// <summary>
    /// Cheap, synchronous pick right before a launch: when a server is set to the generic <c>java</c>
    /// (or a path that no longer exists), return a matching managed runtime. Null = leave as is.
    /// </summary>
    public static string? AutoResolve(string javaPath, string? mcVersion)
    {
        var generic = string.IsNullOrWhiteSpace(javaPath) || javaPath == "java";
        var missing = !generic && Path.IsPathRooted(javaPath) && !File.Exists(javaPath);
        if ((!generic && !missing) || mcVersion is null) return null;
        var need = RequiredJava(mcVersion);
        foreach (var f in JavaInstaller.Features.Where(f => f >= need).OrderBy(f => f))
            if (JavaInstaller.InstalledPath(f) is { } p) return p;
        foreach (var p in CandidatePaths())
            if (ReadMajorFromRelease(p) is { } m && m >= need) return p;
        return null;
    }

    /// <summary>Reads JAVA_VERSION from the runtime's <c>release</c> file without launching it.</summary>
    public static uint? ReadMajorFromRelease(string javaExe)
    {
        try
        {
            var home = Path.GetDirectoryName(Path.GetDirectoryName(javaExe))!;
            var rel = Path.Combine(home, "release");
            if (!File.Exists(rel)) return null;
            foreach (var line in File.ReadLines(rel))
                if (line.StartsWith("JAVA_VERSION=")) return ParseMajor("\"" + line["JAVA_VERSION=".Length..].Trim('"') + "\"");
        }
        catch { }
        return null;
    }
}
