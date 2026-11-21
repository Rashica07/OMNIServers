using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CraftPanel.Core.Runtime;

/// <summary>Something a player did, read from the server's console output.</summary>
public abstract record LiveEvent
{
    public sealed record Join(string Player) : LiveEvent;
    public sealed record Leave(string Player) : LiveEvent;
    public sealed record Chat(string From, string Text) : LiveEvent;
    /// <summary><c>/say</c> from the console or RCON: "[Server] hi".</summary>
    public sealed record Broadcast(string From, string Text) : LiveEvent;
    public sealed record Advancement(string Player, string Title) : LiveEvent;

    static readonly Regex Ansi = new("\u001b\\[[0-9;]*m", RegexOptions.Compiled);

    /// <summary>
    /// Parses one console line. Handles vanilla/Fabric (<c>[12:00:00] [Server thread/INFO]: …</c>), Paper (<c>[12:00:00 INFO]: …</c>) and
    /// Forge prefixes, ANSI colour codes and 1.19+'s "[Not Secure]". Names are validated so a chat message can't forge a join.
    /// </summary>
    public static LiveEvent? Parse(string raw)
    {
        var line = Ansi.Replace(raw, "");
        var i = line.IndexOf("]: ", StringComparison.Ordinal);
        if (i < 0) return null;
        var rest = line[(i + 3)..].Trim();
        if (rest.StartsWith("[Not Secure] ")) rest = rest["[Not Secure] ".Length..];

        if (rest.StartsWith('<') && rest.IndexOf('>') is var close and > 0)
        {
            var name = rest[1..close];
            var text = rest[(close + 1)..].Trim();
            return IsValidName(name) && text.Length > 0 ? new Chat(name, text) : null;
        }
        if (rest.StartsWith('[') && rest.IndexOf(']') is var c2 and > 0)
        {
            var who = rest[1..c2];
            if (who is "Server" or "Rcon")
            {
                var text = rest[(c2 + 1)..].Trim();
                return text.Length == 0 ? null : new Broadcast(who, text);
            }
            return null;
        }
        foreach (var suffix in new[] { " joined the game", " left the game" })
            if (rest.EndsWith(suffix))
            {
                var name = rest[..^suffix.Length];
                if (!IsValidName(name)) return null;
                return suffix == " joined the game" ? new Join(name) : new Leave(name);
            }
        foreach (var verb in new[] { " has made the advancement [", " has completed the challenge [", " has reached the goal [" })
        {
            var v = rest.IndexOf(verb, StringComparison.Ordinal);
            if (v >= 0 && rest.EndsWith(']'))
            {
                var name = rest[..v];
                if (!IsValidName(name)) return null;
                return new Advancement(name, rest[(v + verb.Length)..^1]);
            }
        }
        return null;
    }

    /// <summary>Java names (1–16 of A–Z, 0–9, _) plus Geyser/Floodgate's "." or "*" prefix for Bedrock players.</summary>
    public static bool IsValidName(string n)
    {
        if (n.Length > 0 && n[0] is '.' or '*') n = n[1..];
        return n.Length is >= 1 and <= 16 && n.All(c => char.IsAscii(c) && (char.IsLetterOrDigit(c) || c == '_'));
    }
}

public enum ChatKind { Chat, Broadcast, Join, Leave, Advancement, Mine }

public sealed record ChatEntry(long Id, DateTime Date, ChatKind Kind, string Who, string Text);

/// <summary>Tails <c>logs/latest.log</c> for a server we re-adopted (no stdout pipe then). Starts at the current end and follows rotation.</summary>
public sealed class LogTailer
{
    readonly string _file;
    long _offset;
    byte[] _partial = [];

    public LogTailer(string serverDir)
    {
        _file = Path.Combine(serverDir, "logs", "latest.log");
        _offset = File.Exists(_file) ? new FileInfo(_file).Length : 0;
    }

    /// <summary>New complete lines since the last call.</summary>
    public List<string> Poll()
    {
        var lines = new List<string>();
        try
        {
            if (!File.Exists(_file)) return lines;
            var size = new FileInfo(_file).Length;
            if (size < _offset) { _offset = 0; _partial = []; }   // rotated
            if (size <= _offset) return lines;
            using var fs = new FileStream(_file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            fs.Seek(_offset, SeekOrigin.Begin);
            var buf = new byte[Math.Min(size - _offset, 1 << 20)];
            var n = fs.Read(buf, 0, buf.Length);
            _offset += n;
            var all = _partial.Concat(buf.Take(n)).ToArray();
            var last = Array.LastIndexOf(all, (byte)'\n');
            if (last < 0) { _partial = all; return lines; }
            _partial = all[(last + 1)..];
            lines.AddRange(Encoding.UTF8.GetString(all, 0, last).Split('\n').Select(l => l.TrimEnd('\r')));
        }
        catch (IOException) { }
        return lines;
    }
}

public static class ChatHistory
{
    /// <summary>Chat/joins/advancements from the tail of <c>logs/latest.log</c> (today's session), oldest first.</summary>
    public static List<ChatEntry> Load(string serverDir, int maxBytes = 256 * 1024, int max = 300)
    {
        var file = Path.Combine(serverDir, "logs", "latest.log");
        var result = new List<ChatEntry>();
        try
        {
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (fs.Length > maxBytes) fs.Seek(-maxBytes, SeekOrigin.End);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            var text = sr.ReadToEnd();
            var day = File.GetLastWriteTime(file).Date;
            long id = 0;
            foreach (var line in text.Split('\n'))
            {
                var ev = LiveEvent.Parse(line.TrimEnd('\r'));
                if (ev is null) continue;
                var date = TimeOf(line) is { } t ? day + t : day;
                result.Add(ev switch
                {
                    LiveEvent.Join j => new ChatEntry(++id, date, ChatKind.Join, j.Player, "joined the game"),
                    LiveEvent.Leave l => new ChatEntry(++id, date, ChatKind.Leave, l.Player, "left the game"),
                    LiveEvent.Chat c => new ChatEntry(++id, date, ChatKind.Chat, c.From, c.Text),
                    LiveEvent.Broadcast b => new ChatEntry(++id, date, ChatKind.Broadcast, b.From, b.Text),
                    LiveEvent.Advancement a => new ChatEntry(++id, date, ChatKind.Advancement, a.Player, a.Title),
                    _ => throw new InvalidOperationException(),
                });
            }
        }
        catch (IOException) { }
        return result.TakeLast(max).ToList();
    }

    static TimeSpan? TimeOf(string line) =>
        line.Length >= 9 && line[0] == '[' && line[3] == ':' && line[6] == ':'
        && int.TryParse(line.AsSpan(1, 2), out var h) && int.TryParse(line.AsSpan(4, 2), out var m) && int.TryParse(line.AsSpan(7, 2), out var s)
            ? new TimeSpan(h, m, s) : null;

    /// <summary><c>["",{"text":"&lt;Host&gt; ","color":"gold"},{"text":"hi"}]</c> — JSON-encoded so quotes/backslashes/newlines can't break out.</summary>
    public static string TellrawJson(string name, string message)
    {
        var clean = message.Replace("\n", " ").Replace("\r", " ");
        object[] parts = ["", new { text = $"<{name}> ", color = "gold" }, new { text = clean }];
        return JsonSerializer.Serialize(parts, new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    }
}
