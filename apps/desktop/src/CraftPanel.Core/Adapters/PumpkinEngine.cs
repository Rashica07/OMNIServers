using System.Runtime.InteropServices;
using System.Text;

namespace CraftPanel.Core.Adapters;

/// <summary>
/// The engine behind OMNIHost: PumpkinMC, a native Rust Minecraft server (GPLv3). OMNIServers does not bundle it:
/// it downloads one pinned release from Pumpkin's GitHub releases, checks the SHA-256 in that release's
/// <c>checksums.sha256</c>, and keeps it under <c>engines/pumpkin/&lt;tag&gt;/</c> in the local data folder. A server records the
/// absolute path of the binary it was made with, so a later engine update never changes an existing server by surprise.
/// </summary>
public static class PumpkinEngine
{
    /// <summary>The release that was run and checked by hand (2026-11-19). Newer tags are opt-in.</summary>
    public const string PinnedTag = "0.2.2+26.3-26.60";
    /// <summary>The Java Minecraft version this release speaks.</summary>
    public const string MinecraftVersion = "26.3";
    public const string ReleasesBase = "https://github.com/Pumpkin-MC/Pumpkin/releases/download";

    // ---- which file ------------------------------------------------------------------

    /// <summary>The release asset for a computer, null where Pumpkin ships no build. <paramref name="os"/> is windows, linux or macOS; <paramref name="arch"/> is x64 or arm64.</summary>
    public static string? AssetName(string os, string arch) => (os, arch) switch
    {
        ("macOS", "arm64") => "pumpkin-ARM64-macOS",
        ("linux", "arm64") => "pumpkin-ARM64-Linux",
        ("linux", "x64") => "pumpkin-X64-Linux",
        ("windows", "arm64") => "pumpkin-ARM64-Windows.exe",
        ("windows", "x64") => "pumpkin-X64-Windows.exe",
        _ => null,   // no Intel Mac build
    };

    public static string CurrentOs => OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macOS" : "linux";
    public static string CurrentArch => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
    public static string? CurrentAsset => AssetName(CurrentOs, CurrentArch);

    /// <summary>The program's file name inside the install folder.</summary>
    public static string BinaryName => OperatingSystem.IsWindows() ? "pumpkin.exe" : "pumpkin";

    /// <summary><c>+</c> in a tag must be percent-encoded in a download URL.</summary>
    public static string DownloadUrl(string tag, string file) => $"{ReleasesBase}/{tag.Replace("+", "%2B")}/{file}";

    /// <summary><c>checksums.sha256</c> lines are <c>&lt;64 hex&gt;  &lt;file name&gt;</c>.</summary>
    public static Dictionary<string, string> ParseChecksums(string text)
    {
        var map = new Dictionary<string, string>();
        foreach (var raw in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = raw.Trim().Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2 || parts[0].Length != 64 || !parts[0].All(Uri.IsHexDigit)) continue;
            map[parts[1].TrimStart('*')] = parts[0].ToLowerInvariant();
        }
        return map;
    }

    // ---- where it lives --------------------------------------------------------------

    public static string Root => Path.Combine(AppPaths.LocalDir, "engines", "pumpkin");

    public static string BinaryPath(string tag, string? root = null) => Path.Combine(root ?? Root, tag, BinaryName);

    static bool Runnable(string path) => File.Exists(path);

    /// <summary>The pinned engine when installed, else the newest installed one, else null.</summary>
    public static string? InstalledBinary(string? root = null)
    {
        root ??= Root;
        var pinned = BinaryPath(PinnedTag, root);
        if (Runnable(pinned)) return pinned;
        if (!Directory.Exists(root)) return null;
        foreach (var tag in Directory.EnumerateDirectories(root).Select(Path.GetFileName).OrderByDescending(t => t, StringComparer.Ordinal))
        {
            var b = BinaryPath(tag!, root);
            if (Runnable(b)) return b;
        }
        return null;
    }

    // ---- install ---------------------------------------------------------------------

    /// <summary>Puts a downloaded file in place if (and only if) its SHA-256 is the expected one. The download is never run before this check passes.</summary>
    public static string Place(string downloaded, string expectedSha256, string tag, string? root = null)
    {
        var actual = Http.Sha256Hex(downloaded);
        if (!actual.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
            throw new ProvisionException("The OMNIHost engine download didn't match the checksum published with it, so OMNIServers deleted it rather than run it. Try again.");
        var dest = BinaryPath(tag, root);
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        File.Copy(downloaded, dest, overwrite: true);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(dest, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
        return dest;
    }

    /// <summary>Downloads and verifies the pinned engine unless it is already installed.</summary>
    public static async Task<string> EnsureInstalledAsync(IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        if (InstalledBinary() is { } have)
        {
            progress?.Report(new("done", "OMNIHost engine is ready.", 100));
            return have;
        }
        var asset = CurrentAsset ?? throw new ProvisionException($"OMNIHost has no engine for this computer yet (Pumpkin ships no {CurrentOs} {CurrentArch} build).");
        progress?.Report(new("fetch", "Finding the OMNIHost engine…", null));
        Dictionary<string, string> sums;
        try { sums = ParseChecksums(await Http.Client.GetStringAsync(DownloadUrl(PinnedTag, "checksums.sha256"), ct)); }
        catch (Exception e) when (e is not OperationCanceledException) { throw new ProvisionException("Couldn't read the engine's checksum list from GitHub: " + e.Message, e); }
        if (!sums.TryGetValue(asset, out var expected)) throw new ProvisionException("Couldn't read the engine's checksum list from GitHub.");
        var tmp = Path.Combine(Path.GetTempPath(), "cp-" + asset + "-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            await Http.DownloadAsync(DownloadUrl(PinnedTag, asset), tmp, "the OMNIHost engine (about 100 MB, once)", progress, ct);
            progress?.Report(new("verify", "Verifying checksum…", null));
            var placed = await Task.Run(() => Place(tmp, expected, PinnedTag), ct);
            progress?.Report(new("done", "OMNIHost engine installed.", 100));
            return placed;
        }
        finally { try { File.Delete(tmp); } catch { } }
    }
}

/// <summary><c>pumpkin.toml</c>: the settings OMNIServers writes before a server's first start. Pumpkin fills in every other key itself.</summary>
public static class PumpkinConfig
{
    public const string FileName = "pumpkin.toml";
    public const string IconFile = "server-icon.png";

    public sealed record Settings
    {
        public string Motd { get; init; } = "A Minecraft Server";
        public int Port { get; init; } = 25565;
        public int MaxPlayers { get; init; } = 20;
        public string Gamemode { get; init; } = "survival";
        public string Difficulty { get; init; } = "normal";
        public string Seed { get; init; } = "";
        /// <summary>Mojang sign-in for players. On unless the user knowingly turns it off.</summary>
        public bool OnlineMode { get; init; } = true;
        /// <summary>Folder name of the world. <c>world</c> unless a transferred server used another.</summary>
        public string LevelName { get; init; } = "world";
        public int? ViewDistance { get; init; }
        public int? SimulationDistance { get; init; }
        public bool Whitelist { get; init; }
        public bool EnforceWhitelist { get; init; }
        public bool Hardcore { get; init; }
        public bool AllowNether { get; init; } = true;
        public int SpawnProtection { get; init; } = 16;
        public bool ForceGamemode { get; init; }
        public int OpPermissionLevel { get; init; } = 4;
        public bool Pvp { get; init; } = true;
        public string ResourcePackUrl { get; init; } = "";
        public string ResourcePackSha1 { get; init; } = "";
        public bool ResourcePackForce { get; init; }
        public string ResourcePackPrompt { get; init; } = "";
    }

    /// <summary><c>survival</c> to <c>Survival</c>: Pumpkin wants the capitalised names.</summary>
    public static string TitleCase(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..].ToLowerInvariant();

    /// <summary>A TOML basic string: quotes, backslashes and line breaks escaped.</summary>
    public static string Quoted(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in s)
            sb.Append(c switch { '\\' => "\\\\", '"' => "\\\"", '\n' or '\r' => " ", _ => c.ToString() });
        return sb.Append('"').ToString();
    }

    static string B(bool v) => v ? "true" : "false";

    public static string Render(Settings s)
    {
        var players = Math.Clamp(s.MaxPlayers, 1, 1000);
        var l = new List<string>();
        var seed = s.Seed.Trim();
        if (seed.Length > 0) l.Add($"seed = {Quoted(seed)}");
        l.Add($"default_difficulty = {Quoted(TitleCase(s.Difficulty))}");
        l.Add($"default_gamemode = {Quoted(TitleCase(s.Gamemode))}");
        if (s.LevelName != "world") l.Add($"default_level_name = {Quoted(s.LevelName)}");
        if (s.Whitelist) l.Add("white_list = true");
        if (s.EnforceWhitelist) l.Add("enforce_whitelist = true");
        if (s.Hardcore) l.Add("hardcore = true");
        if (!s.AllowNether) l.Add("allow_nether = false");
        if (s.SpawnProtection != 16) l.Add($"spawn_protection = {Math.Clamp(s.SpawnProtection, 0, 1000)}");
        if (s.ForceGamemode) l.Add("force_gamemode = true");
        if (s.OpPermissionLevel != 4) l.Add($"op_permission_level = {Math.Clamp(s.OpPermissionLevel, 0, 4)}");
        l.Add($"favicon_path = \"{IconFile}\"");
        // Pumpkin sends anonymous heartbeats to its own server by default. Off for our users.
        l.AddRange(["", "[telemetry]", "enabled = false", "", "[logging]", "color = false", "", "[networking.java]"]);
        l.Add($"address = \"0.0.0.0:{s.Port}\"");
        l.Add($"online_mode = {B(s.OnlineMode)}");
        // Without this the engine still asks players to encrypt, which needs a Mojang sign-in (checked).
        l.Add($"encryption = {B(s.OnlineMode)}");
        l.Add($"max_players = {players}");
        if (s.ViewDistance is { } vd) l.Add($"view_distance = {Math.Clamp(vd, 2, 32)}");
        if (s.SimulationDistance is { } sd) l.Add($"simulation_distance = {Math.Clamp(sd, 2, 32)}");
        l.Add($"motd = {Quoted(s.Motd.Length == 0 ? "A Minecraft Server" : s.Motd)}");
        // Bedrock listens on 19132 by default. Off until there is a switch for it.
        l.AddRange(["", "[networking.bedrock]", "enabled = false"]);
        if (!s.Pvp) l.AddRange(["", "[pvp]", "enabled = false"]);
        var pack = s.ResourcePackUrl.Trim();
        if (pack.Length > 0)
        {
            l.AddRange(["", "[resource_pack.java]", "enabled = true", $"url = {Quoted(pack)}", $"sha1 = {Quoted(s.ResourcePackSha1.Trim())}",
                $"prompt_message = {Quoted(s.ResourcePackPrompt)}", $"force = {B(s.ResourcePackForce)}"]);
        }
        return string.Join("\n", l) + "\n";
    }

    /// <summary>The Java port in <c>pumpkin.toml</c> text (<c>[networking.java]</c> <c>address = "host:port"</c>).</summary>
    public static int? JavaPort(string toml)
    {
        var inJava = false;
        foreach (var raw in toml.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith('[')) { inJava = line == "[networking.java]"; continue; }
            if (!inJava || !line.StartsWith("address")) continue;
            var q1 = line.IndexOf('"');
            var q2 = q1 < 0 ? -1 : line.IndexOf('"', q1 + 1);
            if (q2 < 0) return null;
            var addr = line[(q1 + 1)..q2];
            var colon = addr.LastIndexOf(':');
            return colon >= 0 && int.TryParse(addr[(colon + 1)..], out var p) && p is > 0 and <= 65535 ? p : null;
        }
        return null;
    }

    public static int? JavaPortOf(string serverDir) =>
        File.Exists(Path.Combine(serverDir, FileName)) ? JavaPort(File.ReadAllText(Path.Combine(serverDir, FileName))) : null;

    // ---- editing an existing file ----------------------------------------------------

    /// <summary>What Settings can change on a server. Everything else in <c>pumpkin.toml</c> is left alone.</summary>
    public sealed record Editable(bool OnlineMode, string Motd, int MaxPlayers, string Gamemode, string Difficulty);

    const string JavaSection = "networking.java";

    static string? HeaderName(string line)
    {
        var t = line.Trim();
        return t.StartsWith('[') && t.EndsWith(']') && !t.StartsWith("[[") ? t[1..^1].Trim() : null;
    }

    static string? KeyName(string line)
    {
        var t = line.Trim();
        if (t.StartsWith('#')) return null;
        var eq = t.IndexOf('=');
        return eq < 0 ? null : t[..eq].Trim();
    }

    /// <summary>The raw text after <c>key =</c> in <paramref name="section"/> ("" is the top of the file), without a trailing comment.</summary>
    public static string? RawValue(string toml, string section, string key)
    {
        var current = "";
        foreach (var line in toml.Split('\n'))
        {
            if (HeaderName(line) is { } h) { current = h; continue; }
            if (current != section || KeyName(line) != key) continue;
            var v = line[(line.IndexOf('=') + 1)..].Trim();
            if (!v.StartsWith('"') && v.IndexOf('#') is var hash and >= 0) v = v[..hash].Trim();
            return v;
        }
        return null;
    }

    public static string Unquote(string raw)
    {
        if (raw.Length < 2 || !raw.StartsWith('"') || !raw.EndsWith('"')) return raw;
        var sb = new StringBuilder();
        var escaped = false;
        foreach (var c in raw[1..^1])
        {
            if (escaped) { sb.Append(c); escaped = false; }
            else if (c == '\\') escaped = true;
            else sb.Append(c);
        }
        return sb.ToString();
    }

    /// <summary><paramref name="toml"/> with <c>key = raw</c> set in <paramref name="section"/>: the line is replaced where it is, or added at the end of the section (or the section is added). Every other line stays byte for byte.</summary>
    public static string Setting(string toml, string section, string key, string raw)
    {
        var lines = toml.Split('\n').ToList();
        var current = "";
        int? sectionStart = null, lastInSection = null;
        for (var i = 0; i < lines.Count; i++)
        {
            if (HeaderName(lines[i]) is { } h)
            {
                current = h;
                if (h == section) { sectionStart = i; lastInSection = i; }
                continue;
            }
            if (current != section) continue;
            if (KeyName(lines[i]) == key) { lines[i] = $"{key} = {raw}"; return string.Join("\n", lines); }
            if (lines[i].Trim().Length > 0) lastInSection = i;
        }
        var entry = $"{key} = {raw}";
        if (section.Length == 0)
        {
            // Top-level keys must come before the first [section].
            var first = lines.FindIndex(l => HeaderName(l) is not null);
            lines.Insert(first < 0 ? lines.Count : first, entry);
        }
        else if (sectionStart is not null && lastInSection is { } last) lines.Insert(last + 1, entry);
        else
        {
            while (lines.Count > 0 && lines[^1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
            lines.AddRange(["", $"[{section}]", entry, ""]);
        }
        return string.Join("\n", lines);
    }

    public static Editable? Read(string serverDir) =>
        File.Exists(Path.Combine(serverDir, FileName)) ? ReadToml(File.ReadAllText(Path.Combine(serverDir, FileName))) : null;

    public static Editable ReadToml(string t) => new(
        (RawValue(t, JavaSection, "online_mode") ?? "true") != "false",
        RawValue(t, JavaSection, "motd") is { } m ? Unquote(m) : "",
        int.TryParse(RawValue(t, JavaSection, "max_players"), out var mp) ? mp : 20,
        (RawValue(t, "", "default_gamemode") is { } g ? Unquote(g) : "Survival").ToLowerInvariant(),
        (RawValue(t, "", "default_difficulty") is { } d ? Unquote(d) : "Normal").ToLowerInvariant());

    /// <summary>Writes the editable settings into the server's <c>pumpkin.toml</c>.</summary>
    public static void Apply(Editable e, string serverDir)
    {
        var path = Path.Combine(serverDir, FileName);
        var t = File.Exists(path) ? File.ReadAllText(path) : "";
        t = Setting(t, JavaSection, "online_mode", B(e.OnlineMode));
        t = Setting(t, JavaSection, "encryption", B(e.OnlineMode));
        t = Setting(t, JavaSection, "motd", Quoted(e.Motd.Length == 0 ? "A Minecraft Server" : e.Motd));
        t = Setting(t, JavaSection, "max_players", Math.Clamp(e.MaxPlayers, 1, 1000).ToString());
        t = Setting(t, "", "default_gamemode", Quoted(TitleCase(e.Gamemode)));
        t = Setting(t, "", "default_difficulty", Quoted(TitleCase(e.Difficulty)));
        File.WriteAllText(path, t);
    }

    /// <summary>Servers made before the OMNIHost icon existed: point the favicon at <c>server-icon.png</c>.</summary>
    public static void EnsureFavicon(string serverDir)
    {
        var path = Path.Combine(serverDir, FileName);
        if (!File.Exists(path)) return;
        var t = File.ReadAllText(path);
        if (RawValue(t, "", "favicon_path") is not null) return;
        File.WriteAllText(path, Setting(t, "", "favicon_path", Quoted(IconFile)));
    }
}
