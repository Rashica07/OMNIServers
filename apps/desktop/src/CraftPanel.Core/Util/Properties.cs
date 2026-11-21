using System.Text;

namespace CraftPanel.Core;

/// <summary>
/// Line-preserving reader/writer for <c>server.properties</c>: only lines whose key actually
/// changed are rewritten; comments, blanks, ordering and untouched entries stay byte-for-byte.
/// Never touches <c>online-mode</c> or anything the caller didn't set.
/// </summary>
public sealed class Properties
{
    abstract record Line;
    sealed record Raw(string Text) : Line;
    sealed record Entry(string Key, string Value, string? Original) : Line;

    readonly string _dir;
    readonly List<Line> _lines;
    readonly bool _trailingNewline;
    public bool Existed { get; }
    string FilePath => Path.Combine(_dir, "server.properties");

    Properties(string dir, List<Line> lines, bool trailing, bool existed) { _dir = dir; _lines = lines; _trailingNewline = trailing; Existed = existed; }

    public static Properties Load(string dir)
    {
        var path = Path.Combine(dir, "server.properties");
        var existed = File.Exists(path);
        var text = existed ? File.ReadAllText(path) : "";
        var trailing = text.Length == 0 || text.EndsWith('\n');
        var lines = new List<Line>();
        if (text.Length > 0)
        {
            var parts = text.Split('\n').ToList();
            if (trailing && parts.Count > 0 && parts[^1] == "") parts.RemoveAt(parts.Count - 1);
            foreach (var p in parts)
            {
                var raw = p.EndsWith('\r') ? p[..^1] : p;
                var t = raw.TrimStart(' ', '\t');
                if (t.Length == 0 || t[0] is '#' or '!') { lines.Add(new Raw(raw)); continue; }
                var i = IndexOfSeparator(raw);
                if (i < 0) { lines.Add(new Raw(raw)); continue; }
                lines.Add(new Entry(raw[..i].Trim(), raw[(i + 1)..].TrimStart(), raw));
            }
        }
        return new Properties(dir, lines, trailing, existed);
    }

    static int IndexOfSeparator(string s)
    {
        for (var i = 0; i < s.Length; i++) if (s[i] is '=' or ':') return i;
        return -1;
    }

    public string? Get(string key)
    {
        for (var i = _lines.Count - 1; i >= 0; i--)
            if (_lines[i] is Entry e && e.Key == key) return e.Value;
        return null;
    }

    public string GetOr(string key, string fallback) => Get(key) ?? fallback;
    public int GetInt(string key, int fallback) => int.TryParse(Get(key), out var v) ? v : fallback;
    public bool GetBool(string key, bool fallback) => Get(key) is { } s ? s.Equals("true", StringComparison.OrdinalIgnoreCase) : fallback;

    /// <summary>Sets a value; returns false if it was already that value.</summary>
    public bool Set(string key, string value)
    {
        value = value.Replace("\r", "").Replace("\n", "");
        for (var i = _lines.Count - 1; i >= 0; i--)
        {
            if (_lines[i] is Entry e && e.Key == key)
            {
                if (e.Value == value) return false;
                _lines[i] = new Entry(key, value, null);
                return true;
            }
        }
        _lines.Add(new Entry(key, value, null));
        return true;
    }

    public IEnumerable<(string Key, string Value)> Entries() => _lines.OfType<Entry>().Select(e => (e.Key, e.Value));

    string Render()
    {
        var sb = new StringBuilder();
        for (var i = 0; i < _lines.Count; i++)
        {
            sb.Append(_lines[i] switch { Raw r => r.Text, Entry { Original: { } o } => o, Entry e => $"{e.Key}={e.Value}", _ => "" });
            if (i < _lines.Count - 1 || _trailingNewline) sb.Append('\n');
        }
        return sb.ToString();
    }

    public void Save() => AppPaths.WriteAtomic(FilePath, Render());
}
