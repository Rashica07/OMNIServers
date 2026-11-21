using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;

namespace CraftPanel.Core.Runtime;

public sealed class RconException(string message) : Exception(message);

/// <summary>Minimal Source-RCON client. Multi-packet replies are collected with a sentinel request.</summary>
public sealed class RconClient : IDisposable
{
    TcpClient? _tcp;
    NetworkStream? _s;
    int _nextId = 1;

    public static async Task<RconClient> ConnectAsync(string host, int port, string password, CancellationToken ct = default)
    {
        var c = new RconClient();
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(5));
            c._tcp = new TcpClient { NoDelay = true };
            await c._tcp.ConnectAsync(host, port, cts.Token);
            c._s = c._tcp.GetStream();
            var id = c._nextId++;
            await c.SendAsync(id, 3, password, cts.Token);
            // The server may send an empty type-0 packet before the auth reply.
            for (var i = 0; i < 2; i++)
            {
                var (rid, type, _, _) = await c.ReadAsync(cts.Token);
                if (type == 2) { if (rid == -1) throw new RconException("RCON password was rejected."); return c; }
            }
            throw new RconException("RCON handshake failed.");
        }
        catch (Exception e) when (e is not RconException)
        {
            c.Dispose();
            throw new RconException($"Couldn't reach RCON on port {port}: {e.Message}");
        }
    }

    /// <summary>
    /// Sends one command and returns the reply. Minecraft's RCON reads exactly one packet per socket read (two packets sent
    /// together make it drop the connection), so there is no pipelining and no sentinel: a reply is split into 4096-byte
    /// chunks, and a chunk shorter than that is the last one.
    /// </summary>
    public async Task<string> CommandAsync(string command, CancellationToken ct = default)
    {
        if (_s is null) throw new RconException("RCON is closed.");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(10));
        var id = _nextId++;
        await SendAsync(id, 2, command, cts.Token);
        var sb = new StringBuilder();
        while (true)
        {
            var (rid, _, body, byteLen) = await ReadAsync(cts.Token);
            if (rid == id) sb.Append(body);
            if (byteLen < 4096) break;
        }
        return sb.ToString();
    }

    async Task SendAsync(int id, int type, string body, CancellationToken ct)
    {
        var b = Encoding.UTF8.GetBytes(body);
        var buf = new byte[4 + 4 + 4 + b.Length + 2];
        BinaryPrimitives.WriteInt32LittleEndian(buf, 4 + 4 + b.Length + 2);
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(4), id);
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(8), type);
        b.CopyTo(buf, 12);
        await _s!.WriteAsync(buf, ct);
    }

    async Task<(int id, int type, string body, int byteLen)> ReadAsync(CancellationToken ct)
    {
        var head = new byte[4];
        await ReadExactAsync(head, ct);
        var len = BinaryPrimitives.ReadInt32LittleEndian(head);
        if (len is < 10 or > 8192) throw new RconException("Bad RCON packet.");
        var rest = new byte[len];
        await ReadExactAsync(rest, ct);
        return (BinaryPrimitives.ReadInt32LittleEndian(rest), BinaryPrimitives.ReadInt32LittleEndian(rest.AsSpan(4)), Encoding.UTF8.GetString(rest, 8, len - 10), len - 10);
    }

    async Task ReadExactAsync(byte[] buf, CancellationToken ct)
    {
        var got = 0;
        while (got < buf.Length)
        {
            var n = await _s!.ReadAsync(buf.AsMemory(got), ct);
            if (n == 0) throw new RconException("RCON connection closed.");
            got += n;
        }
    }

    public void Dispose() { _s?.Dispose(); _tcp?.Dispose(); _s = null; }

    /// <summary>"There are 2 of a max of 20 players online: Alice, Bob"</summary>
    public static (int Online, int Max, List<string> Players) ParsePlayerList(string output)
    {
        var m = System.Text.RegularExpressions.Regex.Match(output, @"There are (\d+) of a max of (\d+) players online:?\s*(.*)", System.Text.RegularExpressions.RegexOptions.Singleline);
        if (!m.Success) return (0, 0, []);
        var names = m.Groups[3].Value.Split([',', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
        return (int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), names);
    }
}

public sealed record RconEndpoint(int Port, string Password);

/// <summary>Per-server RCON: reads the endpoint from server.properties, keeps one connection, reconnects on failure.</summary>
public sealed class RconService
{
    public static RconService Shared { get; } = new();
    readonly Dictionary<Guid, (RconClient Client, SemaphoreSlim Gate)> _pool = [];
    readonly Dictionary<Guid, DateTime> _stopping = [];
    readonly object _lock = new();

    /// <summary>How long after "stop" new RCON connections are refused (a restart clears it sooner).</summary>
    public static readonly TimeSpan ShutdownWindow = TimeSpan.FromMinutes(2);

    /// <summary>
    /// A server that's shutting down waits for every RCON client thread to finish; a client that stays connected (ours, kept
    /// alive for the Players tab) stalls the shutdown until it's killed. So: close our connection now and don't reconnect.
    /// </summary>
    public void BeginShutdown(Guid id)
    {
        lock (_lock) _stopping[id] = DateTime.UtcNow;
        Drop(id);
    }

    public void EndShutdown(Guid id) { lock (_lock) _stopping.Remove(id); }

    public bool IsShuttingDown(Guid id)
    {
        lock (_lock) return _stopping.TryGetValue(id, out var t) && DateTime.UtcNow - t < ShutdownWindow;
    }

    public static RconEndpoint Endpoint(ServerRecord r)
    {
        var p = Properties.Load(r.Path);
        if (!p.Existed) throw new RconException("This server has no server.properties yet — start it once first.");
        if (p.GetOr("enable-rcon", "false") != "true") throw new RconException("RCON isn't enabled for this server. Turn on RCON in Settings.");
        if (!int.TryParse(p.GetOr("rcon.port", "25575"), out var port)) throw new RconException("rcon.port in server.properties isn't a number");
        var pw = p.Get("rcon.password") ?? "";
        if (pw.Length == 0) throw new RconException("rcon.password is blank — turn on RCON in Settings to generate one.");
        return new(port, pw);
    }

    public async Task<string> RunAsync(ServerRecord r, string command, CancellationToken ct = default)
    {
        if (IsShuttingDown(r.Id)) throw new RconException("The server is shutting down.");
        var ep = Endpoint(r);
        SemaphoreSlim gate;
        lock (_lock)
        {
            if (!_pool.TryGetValue(r.Id, out var e)) _pool[r.Id] = (null!, gate = new SemaphoreSlim(1, 1));
            else gate = e.Gate;
        }
        await gate.WaitAsync(ct);
        try
        {
            for (var attempt = 0; ; attempt++)
            {
                RconClient? c;
                lock (_lock) c = _pool[r.Id].Client;
                try
                {
                    c ??= await RconClient.ConnectAsync("127.0.0.1", ep.Port, ep.Password, ct);
                    lock (_lock) _pool[r.Id] = (c, gate);
                    return await c.CommandAsync(command, ct);
                }
                catch (Exception e) when (e is RconException or IOException or SocketException or OperationCanceledException && !ct.IsCancellationRequested)
                {
                    c?.Dispose();
                    lock (_lock) _pool[r.Id] = (null!, gate);
                    if (attempt >= 1) throw e is RconException ? e : new RconException(e.Message);
                }
            }
        }
        finally { gate.Release(); }
    }

    public void Drop(Guid id)
    {
        lock (_lock) { if (_pool.Remove(id, out var e)) e.Client?.Dispose(); }
    }

    public async Task<(int Online, int Max, List<string> Players)> PlayersAsync(ServerRecord r, CancellationToken ct = default) =>
        RconClient.ParsePlayerList(await RunAsync(r, "list", ct));

    /// <summary>Typed, validated player operations keyed on username.</summary>
    public async Task<string> PlayerActionAsync(ServerRecord r, string action, string player, string? arg = null, CancellationToken ct = default)
    {
        player = player.Trim();
        if (!LiveEvent.IsValidName(player)) throw new RconException("Invalid player name.");
        string cmd;
        switch (action)
        {
            case "kick":
                var reason = arg?.Trim() ?? "";
                if (reason.Length > 0 && !reason.All(c => char.IsAscii(c) && (char.IsLetterOrDigit(c) || " .,!?_-'".Contains(c))))
                    throw new RconException("Kick reason has unsupported characters.");
                cmd = reason.Length > 0 ? $"kick {player} {reason}" : $"kick {player}"; break;
            case "ban": cmd = $"ban {player}"; break;
            case "pardon": cmd = $"pardon {player}"; break;
            case "op": cmd = $"op {player}"; break;
            case "deop": cmd = $"deop {player}"; break;
            case "whitelist-add": cmd = $"whitelist add {player}"; break;
            case "whitelist-remove": cmd = $"whitelist remove {player}"; break;
            case "gamemode":
                if (arg is not ("survival" or "creative" or "adventure" or "spectator")) throw new RconException("Unknown gamemode.");
                cmd = $"gamemode {arg} {player}"; break;
            default: throw new RconException($"Unknown action: {action}");
        }
        return await RunAsync(r, cmd, ct);
    }

    /// <summary>Turns RCON on (enable-rcon, a port, a generated password). Line-preserving.</summary>
    public static (List<string> Changed, int Port) Setup(ServerRecord r)
    {
        var p = Properties.Load(r.Path);
        if (!p.Existed) throw new RconException("No server.properties yet. Start the server once so it generates its config, then enable RCON.");
        var changed = new List<string>();
        if (p.Set("enable-rcon", "true")) changed.Add("enable-rcon=true");
        if (!int.TryParse(p.GetOr("rcon.port", ""), out _)) { p.Set("rcon.port", "25575"); changed.Add("rcon.port=25575"); }
        if ((p.Get("rcon.password") ?? "").Length == 0)
        {
            p.Set("rcon.password", Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(12)));
            changed.Add("rcon.password=(generated)");
        }
        if (p.Set("broadcast-rcon-to-ops", "true")) changed.Add("broadcast-rcon-to-ops=true");
        if (changed.Count > 0) p.Save();
        return (changed, p.GetInt("rcon.port", 25575));
    }
}
