using System.Text.Json;
using System.Text.Json.Serialization;

namespace CraftPanel.Core.Sharing;

/// <summary>The marker that says "this server folder is shared" (written once, never changes).</summary>
public sealed class ShareInfo
{
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("created_by")] public string CreatedBy { get; set; } = "";
}

/// <summary>Who is running the shared server right now. Rewritten while it runs, deleted when it stops.</summary>
public sealed class Lease
{
    /// <summary>A stable id for the PC.</summary>
    [JsonPropertyName("holder")] public string Holder { get; set; } = "";
    /// <summary>The PC's name, for the "in use on …" message.</summary>
    [JsonPropertyName("hostname")] public string Hostname { get; set; } = "";
    [JsonPropertyName("claimed_at")] public long ClaimedAt { get; set; }
    [JsonPropertyName("expires_at")] public long ExpiresAt { get; set; }
}

public sealed record ShareView(bool Shared, string? Code, bool Locked, bool HeldByUs, string? HolderName, long? ExpiresIn);

/// <summary>Raised when another PC is running the shared server; <see cref="Holder"/> and <see cref="MinutesLeft"/> say who and for how long.</summary>
public sealed class LeaseHeldException(string holder, long minutesLeft)
    : ProvisionException($"In use on \"{holder}\" — its claim has about {minutesLeft} min left. Start anyway only if that PC is really off.")
{
    public string Holder { get; } = holder;
    public long MinutesLeft { get; } = minutesLeft;
}

/// <summary>
/// Take-turns hosting: a server folder that lives somewhere two PCs can both open (a USB stick, a network drive, a OneDrive /
/// Google Drive / Dropbox folder) is claimed by exactly one PC at a time through a small lease file, so the world is never
/// run by two PCs at once. It's advisory — it relies on the PCs seeing each other's file promptly — and it expires, so a PC
/// that was switched off doesn't hold the server forever.
///
/// The two JSON files and their field names are exactly the Mac app's and the original app's (<c>craftpanel-share.json</c>:
/// code/name/created_by; <c>craftpanel-lease.json</c>: holder/hostname/claimed_at/expires_at), so a Mac and a Windows PC can share one folder.
/// </summary>
public static class ShareLease
{
    public const string ShareFile = "craftpanel-share.json";
    public const string LeaseFile = "craftpanel-lease.json";
    /// <summary>A running PC refreshes its claim well inside this window.</summary>
    public const long LeaseTtlSecs = 120;

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    /// <summary>Seconds since 1970; tests replace it to move time.</summary>
    public static Func<long> Now { get; set; } = () => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    public static TimeSpan HeartbeatEvery { get; set; } = TimeSpan.FromSeconds(30);

    public static string Hostname() => Environment.MachineName;

    /// <summary>This PC's stable id, kept in OMNIServers's data folder.</summary>
    public static string ThisDeviceId => DeviceId(AppPaths.DataDir);

    public static string DeviceId(string configDir)
    {
        var path = Path.Combine(configDir, "device-id");
        try { var t = File.ReadAllText(path).Trim(); if (t.Length > 0) return t; } catch { }
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        try { Directory.CreateDirectory(configDir); File.WriteAllText(path, id); } catch { }
        return id;
    }

    /// <summary>An 8-character code with no vowels or look-alikes (0/O, 1/I), like ABCD-EFGH.</summary>
    public static string GenCode()
    {
        const string alphabet = "23456789BCDFGHJKMNPQRSTVWXZ";
        var bytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(8);
        var sb = new System.Text.StringBuilder();
        for (var i = 0; i < 8; i++) { if (i == 4) sb.Append('-'); sb.Append(alphabet[bytes[i] % alphabet.Length]); }
        return sb.ToString();
    }

    static T? Read<T>(string file) where T : class
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(file), Json); } catch { return null; }
    }

    public static ShareInfo? ReadShare(string dir) => Read<ShareInfo>(Path.Combine(dir, ShareFile));
    public static Lease? ReadLease(string dir) => Read<Lease>(Path.Combine(dir, LeaseFile));
    public static bool IsShared(string dir) => ReadShare(dir) is not null;

    static void Write(string path, object value) => AppPaths.WriteAtomic(path, JsonSerializer.Serialize(value, value.GetType(), Json));

    /// <summary>Marks the folder as shared. Throws if it already is.</summary>
    public static ShareInfo CreateShare(string dir, string name)
    {
        if (File.Exists(Path.Combine(dir, ShareFile))) throw new ProvisionException("This server is already shared.");
        var info = new ShareInfo { Code = GenCode(), Name = name, CreatedBy = Hostname() };
        Write(Path.Combine(dir, ShareFile), info);
        return info;
    }

    public static ShareView View(string dir, string deviceId)
    {
        if (ReadShare(dir) is not { } info) return new(false, null, false, false, null, null);
        if (ReadLease(dir) is not { } lease) return new(true, info.Code, false, false, null, null);
        var remaining = lease.ExpiresAt - Now();
        return new(true, info.Code, remaining > 0, lease.Holder == deviceId, lease.Hostname, remaining);
    }

    /// <summary>
    /// Takes the claim before the server touches the world. Throws <see cref="LeaseHeldException"/> if another PC holds a live
    /// one, unless <paramref name="force"/> (the user confirmed that PC is really off). A folder that isn't shared needs no claim.
    /// </summary>
    public static Lease Claim(string dir, string deviceId, bool force)
    {
        var now = Now();
        if (ReadShare(dir) is null) return new Lease { Holder = deviceId, Hostname = Hostname(), ClaimedAt = now, ExpiresAt = now + LeaseTtlSecs };
        if (ReadLease(dir) is { } existing && existing.Holder != deviceId && existing.ExpiresAt > now && !force)
            throw new LeaseHeldException(existing.Hostname, Math.Max((existing.ExpiresAt - now) / 60, 0));
        var lease = new Lease { Holder = deviceId, Hostname = Hostname(), ClaimedAt = now, ExpiresAt = now + LeaseTtlSecs };
        Write(Path.Combine(dir, LeaseFile), lease);
        return lease;
    }

    /// <summary>Extends our claim. Does nothing if someone else holds it now.</summary>
    public static void Heartbeat(string dir, string deviceId)
    {
        if (ReadShare(dir) is null || ReadLease(dir) is not { } lease || lease.Holder != deviceId) return;
        lease.ExpiresAt = Now() + LeaseTtlSecs;
        try { Write(Path.Combine(dir, LeaseFile), lease); } catch { }
    }

    /// <summary>Gives the claim back (only if it's ours).</summary>
    public static void Release(string dir, string deviceId)
    {
        if (ReadLease(dir) is not { } lease || lease.Holder != deviceId) return;
        try { File.Delete(Path.Combine(dir, LeaseFile)); } catch { }
    }

    /// <summary>Stops sharing. Refused while another PC is running the server.</summary>
    public static void Unshare(string dir, string deviceId)
    {
        var v = View(dir, deviceId);
        if (v.Locked && !v.HeldByUs) throw new ProvisionException("It's in use on another PC right now — try again when it's free.");
        try { File.Delete(Path.Combine(dir, LeaseFile)); } catch { }
        File.Delete(Path.Combine(dir, ShareFile));
    }

    /// <summary>Whether this folder is on a drive another PC could open (a removable stick or a network drive), for a gentle hint.</summary>
    public static string? LocationNote(string dir)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(dir));
            if (root is null) return null;
            var lower = dir.ToLowerInvariant();
            if (lower.Contains("onedrive") || lower.Contains("google drive") || lower.Contains("googledrive") || lower.Contains("dropbox") || lower.Contains("icloud")) return null;
            if (root.StartsWith(@"\\")) return null;
            var type = new DriveInfo(root).DriveType;
            if (type is DriveType.Network or DriveType.Removable) return null;
            return $"This server is on {root.TrimEnd('\\')} (this PC's own disk). For another PC to use it, move the folder to a USB stick, a network drive, or a synced folder (OneDrive, Google Drive, Dropbox) first, then add it from there.";
        }
        catch { return null; }
    }
}

/// <summary>Small checks that help someone work out why friends can't join.</summary>
public static class LanTools
{
    /// <summary>Does something answer on this address and port? (A running server does; a stopped one, or a firewall that drops it, doesn't.)</summary>
    public static async Task<bool> CanConnectAsync(string host, int port, TimeSpan? timeout = null)
    {
        try
        {
            using var c = new System.Net.Sockets.TcpClient();
            using var cts = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(2));
            await c.ConnectAsync(host, port, cts.Token);
            return c.Connected;
        }
        catch { return false; }
    }

    /// <summary>A precise request a student can copy to school/work IT without needing administrator access.</summary>
    public static string NetworkAccessRequest(int port, bool udp = false)
    {
        var protocol = udp ? "TCP and UDP" : "TCP";   // Bedrock 26.60 signs in over TCP and plays over UDP
        return $"Could you allow devices on this network to connect to my PC on {protocol} port {port} for a Minecraft server? Please disable client/AP isolation for this connection if it is enabled. I do not need administrator access or an internet port forward.";
    }
}
