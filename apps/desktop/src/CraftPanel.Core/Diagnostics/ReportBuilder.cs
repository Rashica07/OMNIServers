using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace CraftPanel.Core.Diagnostics;

/// <summary>Takes personal details and secrets out of text before it goes into a report someone will send to another person.</summary>
public sealed partial class Redactor
{
    readonly List<(string Find, string With)> _literals = [];

    public Redactor(string? userName = null, string? machineName = null, string? userProfile = null)
    {
        void Add(string? find, string with) { if (!string.IsNullOrWhiteSpace(find) && find.Length >= 3) _literals.Add((find, with)); }
        // longest first, so the full profile path is replaced before the bare user name inside it
        Add(userProfile, "%USERPROFILE%");
        Add(userName ?? Environment.UserName, "<user>");
        Add(machineName ?? Environment.MachineName, "<pc>");
        _literals.Sort((a, b) => b.Find.Length.CompareTo(a.Find.Length));
    }

    public string Apply(string text)
    {
        foreach (var (find, with) in _literals) text = text.Replace(find, with, StringComparison.OrdinalIgnoreCase);
        text = Secret().Replace(text, "$1=<hidden>");
        text = Ip().Replace(text, m => m.Value is "127.0.0.1" or "0.0.0.0" ? m.Value : "<ip>");
        return text;
    }

    [GeneratedRegex(@"(?i)\b(password|passwd|passphrase|secret|token|api[-_ ]?key|license[-_ ]?key|rcon\.password)\b\s*[=:]\s*\S+")] private static partial Regex Secret();
    [GeneratedRegex(@"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")] private static partial Regex Ip();
}

public sealed record ReportServer(string Name, string Type, string? McVersion, uint RamMB, bool Running, IReadOnlyList<string> ConsoleLines);

/// <summary>Everything that goes into a problem report. The app fills it in; <see cref="ReportBuilder"/> turns it into text and a zip.</summary>
public sealed class ReportInput
{
    public string Description { get; set; } = "";
    public string AppVersion { get; set; } = "?";
    public bool IsWine { get; set; }
    public string RenderMode { get; set; } = "auto";
    public List<DoctorCheck> Checks { get; } = [];
    public List<ReportServer> Servers { get; } = [];
    /// <summary>Only this server's console is attached (the one that's misbehaving), if any.</summary>
    public string? ConsoleOf { get; set; }
    public string? Error { get; set; }
}

public static class ReportBuilder
{
    public const int MaxConsoleLines = 500;

    /// <summary>A few lines about this PC, safe to show or send.</summary>
    public static string Environment_(ReportInput i)
    {
        var mem = SystemMemory.Current();
        var sb = new StringBuilder();
        sb.AppendLine($"OMNIServers {i.AppVersion}{(i.IsWine ? " (under Wine/CrossOver)" : "")}");
        sb.AppendLine($"Windows/OS: {System.Environment.OSVersion} · {RuntimeInformation.OSArchitecture} · {RuntimeInformation.FrameworkDescription}");
        sb.AppendLine($"Memory: {mem.TotalMB} MB total, {mem.AvailableMB} MB free · CPU cores: {mem.Cores}{(mem.IsWeak ? " (a weak PC for servers)" : "")}");
        sb.AppendLine($"Drawing: {i.RenderMode}");
        sb.AppendLine($"Files: {AppPaths.ModeNote}");
        try { sb.AppendLine($"Free disk where OMNIServers keeps files: {new DriveInfo(Path.GetPathRoot(Path.GetFullPath(AppPaths.DataDir))!).AvailableFreeSpace / 1_048_576} MB"); } catch { }
        sb.AppendLine($"Running from: {Path.GetDirectoryName(System.Environment.ProcessPath) ?? "?"}");
        return sb.ToString();
    }

    /// <summary>The human-readable report (also what the "copy summary" and GitHub-issue buttons use). Already redacted.</summary>
    public static string BuildSummary(ReportInput i, Redactor? redactor = null)
    {
        redactor ??= new Redactor(userProfile: System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile));
        var sb = new StringBuilder();
        sb.AppendLine("What happened");
        sb.AppendLine(string.IsNullOrWhiteSpace(i.Description) ? "(nothing written)" : i.Description.Trim());
        if (!string.IsNullOrWhiteSpace(i.Error)) { sb.AppendLine(); sb.AppendLine("Error"); sb.AppendLine(i.Error.Trim()); }
        sb.AppendLine(); sb.AppendLine("This PC"); sb.Append(Environment_(i));
        if (i.Checks.Count > 0)
        {
            sb.AppendLine(); sb.AppendLine("Health check");
            foreach (var c in i.Checks) sb.AppendLine($"[{c.Level}] {c.Name}: {c.Detail}");
        }
        if (i.Servers.Count > 0)
        {
            sb.AppendLine(); sb.AppendLine("Servers");
            foreach (var s in i.Servers) sb.AppendLine($"- {s.Name}: {s.Type} {s.McVersion ?? "?"}, {s.RamMB} MB{(s.Running ? ", running" : "")}");
        }
        return redactor.Apply(sb.ToString());
    }

    /// <summary>For tests: save somewhere other than the Desktop.</summary>
    public static string? OutputFolderOverride { get; set; }

    /// <summary>Where the report zip goes: the Desktop, else Documents, else the temp folder.</summary>
    public static string DefaultFolder()
    {
        if (OutputFolderOverride is { } o) return o;
        foreach (var f in new[] { System.Environment.SpecialFolder.DesktopDirectory, System.Environment.SpecialFolder.MyDocuments })
        {
            var p = System.Environment.GetFolderPath(f);
            if (p.Length > 0 && AppPaths.CanWrite(p)) return p;
        }
        return Path.GetTempPath();
    }

    /// <summary>
    /// Writes <c>CraftPanel-report-&lt;date&gt;.zip</c>: report.txt, the crash log, and the console of the chosen server.
    /// Everything in it is redacted (user name, PC name, IP addresses, anything that looks like a password or key).
    /// license keys (none exist now), the app-lock PIN and settings files are never included.
    /// </summary>
    public static string Save(ReportInput i, string? folder = null, Redactor? redactor = null)
    {
        redactor ??= new Redactor(userProfile: System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile));
        folder ??= DefaultFolder();
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"CraftPanel-report-{DateTime.Now:yyyy-MM-dd-HHmmss}.zip");
        using (var zip = ZipFile.Open(path, ZipArchiveMode.Create))
        {
            Add(zip, "report.txt", BuildSummary(i, redactor));
            foreach (var name in new[] { "crash.log", "crash.log.old" })
            {
                try
                {
                    var f = Path.Combine(AppPaths.LogsDir, name);
                    if (File.Exists(f)) Add(zip, name, redactor.Apply(ReadTail(f, 256 * 1024)));
                }
                catch { /* an unreadable log shouldn't stop the report */ }
            }
            if (i.ConsoleOf is { } who && i.Servers.FirstOrDefault(s => s.Name == who) is { } srv)
                Add(zip, "console.txt", redactor.Apply(string.Join("\n", srv.ConsoleLines.TakeLast(MaxConsoleLines))));
        }
        return path;
    }

    static void Add(ZipArchive zip, string name, string text)
    {
        var e = zip.CreateEntry(name, CompressionLevel.Optimal);
        using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
        w.Write(text);
    }

    static string ReadTail(string file, int maxBytes)
    {
        using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (fs.Length > maxBytes) fs.Seek(-maxBytes, SeekOrigin.End);
        using var r = new StreamReader(fs, Encoding.UTF8);
        return r.ReadToEnd();
    }

    /// <summary>A prefilled "new issue" address for the OMNIServers repo. Only the summary (never the zip) travels in it, and it's kept short enough for a link.</summary>
    public static string IssueUrl(string title, string summary)
    {
        var body = summary.Length > 4000 ? summary[..4000] + "\n…(shortened — attach the report .zip)" : summary;
        return "https://github.com/Rashica07/OMNIServers/issues/new?title=" + Uri.EscapeDataString(title) + "&body=" + Uri.EscapeDataString(body);
    }

    /// <summary>The last lines of a log file with personal details removed, or "" if there is no such file.</summary>
    public static string RedactedTail(string file, int maxLines = 40)
    {
        try
        {
            if (!File.Exists(file)) return "";
            var lines = ReadTail(file, 64 * 1024).Replace("\r", "").Split('\n').Where(l => l.Length > 0).TakeLast(maxLines);
            return new Redactor().Apply(string.Join("\n", lines));
        }
        catch { return ""; }
    }

    const int MaxIssueUrl = 7000;

    /// <summary>The quick "Report an issue" address: version, OS and the redacted tail of the logs, for the person to describe whatever they like. The logs are cut back until the whole link is short enough for GitHub.</summary>
    public static string NewIssueUrl(string appVersion, string crashLog = "", string serverLog = "")
    {
        string Build(int keep)
        {
            static string Cut(string t, int n) => t.Length <= n ? t : "…" + t[^n..];
            var body = "**What happened? / what do you want?**\n\n\n\n---\nCraftPanel " + appVersion + " · " + System.Environment.OSVersion + " · " + RuntimeInformation.OSArchitecture + "\n";
            if (crashLog.Length > 0) body += "\n<details><summary>OMNIServers crash.log (personal details removed)</summary>\n\n```\n" + Cut(crashLog, keep) + "\n```\n</details>\n";
            if (serverLog.Length > 0) body += "\n<details><summary>Server latest.log (personal details removed)</summary>\n\n```\n" + Cut(serverLog, keep) + "\n```\n</details>\n";
            return "https://github.com/Rashica07/OMNIServers/issues/new?body=" + Uri.EscapeDataString(body);
        }
        var n = 4000;
        var url = Build(n);
        while (url.Length > MaxIssueUrl && n > 100) { n = n * 2 / 3; url = Build(n); }
        return url;
    }
}
