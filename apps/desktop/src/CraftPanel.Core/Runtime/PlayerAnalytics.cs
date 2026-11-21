using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace CraftPanel.Core.Runtime;

public sealed record PlayerStats(string Name, DateTime FirstSeen, DateTime LastSeen, TimeSpan TotalTime, int Sessions, string? LastIp, bool Online);

/// <summary>Who has played, and for how long, rebuilt from the server's own logs (latest.log plus the dated .log / .log.gz files).</summary>
public static partial class PlayerAnalytics
{
    [GeneratedRegex(@"^(\d{4}-\d{2}-\d{2})")]
    private static partial Regex DatePrefix();
    [GeneratedRegex(@"\]: (?<n>[A-Za-z0-9_.*]{1,17})\[/(?<ip>[0-9a-fA-F:.]+):\d+\] logged in")]
    private static partial Regex LoginIp();

    public static List<PlayerStats> Load(string serverDir, bool serverOnline)
    {
        var logs = Path.Combine(serverDir, "logs");
        if (!Directory.Exists(logs)) return [];
        var sources = new List<(DateTime Day, string Path)>();
        foreach (var f in Directory.EnumerateFiles(logs))
        {
            var name = Path.GetFileName(f);
            if (name == "latest.log") sources.Add((File.GetLastWriteTime(f).Date, f));
            else if (DatePrefix().Match(name) is { Success: true } m && DateTime.TryParseExact(m.Groups[1].Value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                     && (name.EndsWith(".log") || name.EndsWith(".log.gz")))
                sources.Add((d, f));
        }
        var open = new Dictionary<string, DateTime>();
        var acc = new Dictionary<string, (DateTime First, DateTime Last, TimeSpan Total, int Sessions, string? Ip)>();
        var pendingIp = new Dictionary<string, string>();

        // oldest file first; within a day, dated files (…-1, -2) precede latest.log
        foreach (var (day0, path) in sources.OrderBy(s => s.Day).ThenBy(s => Path.GetFileName(s.Path) == "latest.log" ? 1 : 0).ThenBy(s => s.Path, StringComparer.Ordinal))
        {
            string text;
            try { text = ReadAll(path); } catch { continue; }
            var day = day0; var prev = TimeSpan.MinValue;
            foreach (var raw in text.Split('\n'))
            {
                var line = raw.TrimEnd('\r');
                if (TimeOfDay(line) is not { } tod) continue;
                if (prev != TimeSpan.MinValue && tod + TimeSpan.FromHours(1) < prev) day = day.AddDays(1);
                prev = tod;
                var ts = day + tod;
                if (LoginIp().Match(line) is { Success: true } lm) pendingIp[lm.Groups["n"].Value] = lm.Groups["ip"].Value;
                switch (LiveEvent.Parse(line))
                {
                    case LiveEvent.Join j:
                        open[j.Player] = ts;
                        var a = acc.GetValueOrDefault(j.Player, (ts, ts, TimeSpan.Zero, 0, null));
                        acc[j.Player] = (a.Item1 == default ? ts : a.Item1, ts, a.Item3, a.Item4, pendingIp.Remove(j.Player, out var ip) ? ip : a.Item5);
                        break;
                    case LiveEvent.Leave l when open.Remove(l.Player, out var start):
                        var b = acc.GetValueOrDefault(l.Player, (start, ts, TimeSpan.Zero, 0, null));
                        acc[l.Player] = (b.Item1, ts, b.Item3 + (ts > start ? ts - start : TimeSpan.Zero), b.Item4 + 1, b.Item5);
                        break;
                }
            }
        }
        // Someone still inside a session counts up to now, and comes first.
        return acc.Select(kv =>
            {
                var online = serverOnline && open.ContainsKey(kv.Key);
                var total = kv.Value.Total + (online ? DateTime.Now - open[kv.Key] : TimeSpan.Zero);
                return new PlayerStats(kv.Key, kv.Value.First, online ? DateTime.Now : kv.Value.Last, total, kv.Value.Sessions + (online ? 1 : 0), kv.Value.Ip, online);
            })
            .OrderByDescending(p => p.Online).ThenByDescending(p => p.LastSeen).ToList();
    }

    static string ReadAll(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (path.EndsWith(".gz")) { using var gz = new GZipStream(fs, CompressionMode.Decompress); using var r = new StreamReader(gz, Encoding.UTF8); return r.ReadToEnd(); }
        using var sr = new StreamReader(fs, Encoding.UTF8); return sr.ReadToEnd();
    }

    static TimeSpan? TimeOfDay(string line) =>
        line.Length >= 9 && line[0] == '[' && line[3] == ':' && line[6] == ':'
        && int.TryParse(line.AsSpan(1, 2), out var h) && int.TryParse(line.AsSpan(4, 2), out var m) && int.TryParse(line.AsSpan(7, 2), out var s)
            ? new TimeSpan(h, m, s) : null;

    public static string FormatDuration(TimeSpan t) => t.TotalHours >= 1 ? $"{(int)t.TotalHours} h {t.Minutes} min" : t.TotalMinutes >= 1 ? $"{(int)t.TotalMinutes} min" : "under a minute";
}
