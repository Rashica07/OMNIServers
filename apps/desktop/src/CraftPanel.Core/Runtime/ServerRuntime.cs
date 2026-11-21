using CraftPanel.Core.Sharing;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Java;

namespace CraftPanel.Core.Runtime;

public enum LogStream { Stdout, Stderr, System }

public sealed record LogLine(long Id, LogStream Stream, string Text);

/// <summary>Written next to a running server so a restarted OMNIServers can re-adopt it instead of orphaning it.</summary>
public sealed record ServerSession(int Pid, long StartedAt, int? RconPort, string? RconPassword)
{
    const string FileName = ".craftpanel-session.json";
    public static ServerSession? Read(string dir)
    {
        try { return JsonSerializer.Deserialize<ServerSession>(File.ReadAllText(Path.Combine(dir, FileName))); } catch { return null; }
    }
    public static void Write(string dir, ServerSession s) { try { File.WriteAllText(Path.Combine(dir, FileName), JsonSerializer.Serialize(s)); } catch { } }
    public static void Clear(string dir) { try { File.Delete(Path.Combine(dir, FileName)); } catch { } }

    /// <summary>Is the pid still the same java process we started (not a recycled pid)?</summary>
    public static bool Alive(int pid, long startedAt)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            if (p.HasExited) return false;
            var started = new DateTimeOffset(p.StartTime).ToUnixTimeSeconds();
            return Math.Abs(started - startedAt) <= 10;
        }
        catch { return false; }
    }
}

/// <summary>Live state of one server's process: console ring, status, players and chat. Events fire on background threads.</summary>
public sealed class ServerRuntime
{
    public const int RingCapacity = 500;
    public const int ChatCapacity = 300;
    public static readonly TimeSpan GracefulStop = TimeSpan.FromSeconds(25);

    public Guid ServerId { get; }
    public string DisplayName { get; set; } = "Server";

    readonly object _gate = new();
    readonly List<LogLine> _lines = [];
    readonly List<ChatEntry> _chat = [];
    readonly List<string> _online = [];
    long _seq, _chatSeq;
    Process? _proc;
    CancellationTokenSource? _tailCts;
    ServerRecord? _record;
    (int Port, string Password)? _rcon;
    int? _adoptedPid;

    public ServerStatus Status { get; private set; } = ServerStatus.Stopped;
    public int? Pid { get; private set; }
    public DateTime? StartedAt { get; private set; }
    public int? ExitCode { get; private set; }
    public bool NeedsEula { get; private set; }
    public bool Reattached { get; private set; }
    public bool StopRequested { get; private set; }
    /// <summary>Set by the scheduler while it stops a server only to start it again (skips the backup-on-stop).</summary>
    public bool StopRequestedForRestart { get; set; }

    public event Action<LogLine>? LineAdded;
    public event Action? StateChanged;
    public event Action? PlayersChanged;
    public event Action<ChatEntry>? ChatAdded;
    /// <summary>Join/leave/chat/advancement, with the online count after it. Feeds notifications.</summary>
    public event Action<LiveEvent, int>? PlayerEvent;
    /// <summary>Raised once when the process ends: (record, crashed).</summary>
    public event Action<ServerRecord, bool>? Exited;

    public ServerRuntime(Guid id) => ServerId = id;

    public bool IsRunning => Status is ServerStatus.Starting or ServerStatus.Running or ServerStatus.Stopping;
    public List<LogLine> Lines() { lock (_gate) return [.. _lines]; }
    public List<string> Online() { lock (_gate) return [.. _online]; }
    public List<ChatEntry> Chat() { lock (_gate) return [.. _chat]; }

    // ---- console ---------------------------------------------------------------------

    public void Push(LogStream stream, string text)
    {
        LogLine line;
        LiveEvent? ev = null;
        lock (_gate)
        {
            line = new(++_seq, stream, text);
            _lines.Add(line);
            if (_lines.Count > RingCapacity) _lines.RemoveRange(0, _lines.Count - RingCapacity);
        }
        LineAdded?.Invoke(line);
        if (stream != LogStream.System && (ev = LiveEvent.Parse(text)) is not null) Apply(ev);
    }

    void Apply(LiveEvent ev)
    {
        int count;
        lock (_gate)
        {
            switch (ev)
            {
                case LiveEvent.Join j: if (!_online.Contains(j.Player)) _online.Add(j.Player); break;
                case LiveEvent.Leave l: _online.Remove(l.Player); break;
            }
            count = _online.Count;
        }
        switch (ev)
        {
            case LiveEvent.Join j: AddChat(ChatKind.Join, j.Player, "joined the game"); break;
            case LiveEvent.Leave l: AddChat(ChatKind.Leave, l.Player, "left the game"); break;
            case LiveEvent.Chat c: AddChat(ChatKind.Chat, c.From, c.Text); break;
            case LiveEvent.Broadcast b: AddChat(ChatKind.Broadcast, b.From, b.Text); break;
            case LiveEvent.Advancement a: AddChat(ChatKind.Advancement, a.Player, a.Title); break;
        }
        PlayersChanged?.Invoke();
        PlayerEvent?.Invoke(ev, count);
    }

    public void AddChat(ChatKind kind, string who, string text, DateTime? date = null)
    {
        ChatEntry e;
        lock (_gate)
        {
            e = new(++_chatSeq, date ?? DateTime.Now, kind, who, text);
            _chat.Add(e);
            if (_chat.Count > ChatCapacity) _chat.RemoveRange(0, _chat.Count - ChatCapacity);
        }
        ChatAdded?.Invoke(e);
    }

    /// <summary>Fills the Chat tab from latest.log the first time it opens.</summary>
    public async Task LoadChatHistoryAsync(string serverDir)
    {
        lock (_gate) if (_chat.Count > 0) return;
        var past = await Task.Run(() => ChatHistory.Load(serverDir));
        lock (_gate) if (_chat.Count > 0) return;
        foreach (var e in past) AddChat(e.Kind, e.Who, e.Text, e.Date);
    }

    void ClearOnline() { lock (_gate) _online.Clear(); PlayersChanged?.Invoke(); }

    void SetStatus(ServerStatus s) { Status = s; StateChanged?.Invoke(); }

    /// <summary>Test seam: puts the runtime in a state without a real process.</summary>
    internal void ForceStateForTest(ServerStatus s, bool reattached = false) { Reattached = reattached; SetStatus(s); }

    // ---- lifecycle -------------------------------------------------------------------

    public void Start(ServerRecord record, bool forceShareLease = false)
    {
        if (IsRunning) throw new InvalidOperationException("Already running.");
        if (!Directory.Exists(record.Path)) throw new ProvisionException($"The server folder is missing: {record.Path}");

        // A server folder shared between PCs: take the claim before anything touches the world. Throws LeaseHeldException
        // if another PC is running it (unless the user confirmed it's really off).
        var shared = ShareLease.IsShared(record.Path);
        if (shared) ShareLease.Claim(record.Path, ShareLease.ThisDeviceId, forceShareLease);

        if (record.ServerType.UsesJava() && JavaProbe.AutoResolve(record.JavaPath, record.McVersion) is { } resolved)
        {
            record.JavaPath = resolved;
            Push(LogStream.System, $"Using Java at {resolved}");
        }
        // The launch file must be there: a clear message beats Java's "Unable to access jarfile".
        if (record.ServerType.UsesJava() && record.LaunchTarget.EndsWith(".jar", StringComparison.OrdinalIgnoreCase) && !File.Exists(Path.Combine(record.Path, record.LaunchTarget)))
            throw new ProvisionException(StartupAdvice.MissingLaunchFile(record.LaunchTarget));
        RconService.Shared.EndShutdown(ServerId);
        _advised = false;
        _record = record;
        DisplayName = record.Name;

        _rcon = null;
        if (record.ServerType.UsesJava() && File.Exists(Path.Combine(record.Path, "server.properties")))
        {
            try { var (_, port) = RconService.Setup(record); _rcon = (port, Properties.Load(record.Path).Get("rcon.password") ?? ""); } catch { }
        }

        var cfg = new ServerConfig(record.Path, record.LaunchTarget, record.JavaPath, record.RamMB, record.ServerType,
            Network.CrossplayManager.LaunchJvmArgs(record.Path, record.ServerType, record.JvmArgs));   // adds Geyser's NetherNet flag when Geyser is installed
        if (!record.ServerType.IsOmniHost()) MinecraftAdapter.EnsureUserJvmArgs(cfg);
        if (record.ServerType.IsOmniHost()) OmniHostAdapter.PrepareFolder(record.Path);
        if (record.ServerType.IsGame())
        {
            if (!GameServers.IsPlatformSupported(record.ServerType))
                throw new ProvisionException($"{record.ServerType.Label()} has no server for this operating system. Use a Windows or Linux PC.");
            if (!File.Exists(Path.Combine(record.Path, record.LaunchTarget)))
                throw new ProvisionException($"The server program ({record.LaunchTarget}) is missing from {record.Path}.");
            GameServers.Fix(record.ServerType, record.Path, record.Name);
        }
        foreach (var b in GameServers.Banner(record.ServerType.IsGame() ? record.ServerType.Label() : "Minecraft")) Push(LogStream.System, b);
        var spec = record.ServerType.IsOmniHost()
            ? OmniHostAdapter.StartCommand(cfg) ?? throw new ProvisionException(OmniHostAdapter.MissingEngineReason)
            : record.ServerType.IsGame() ? GameServers.StartCommand(cfg) : MinecraftAdapter.StartCommand(cfg);
        var psi = new ProcessStartInfo(spec.FileName)
        {
            WorkingDirectory = spec.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in spec.Args) psi.ArgumentList.Add(a);

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        ExitCode = null; StopRequested = false; NeedsEula = false; Reattached = false;
        ClearOnline();
        SetStatus(ServerStatus.Starting);
        try { p.Start(); }
        catch (Exception e)
        {
            if (shared) ShareLease.Release(record.Path, ShareLease.ThisDeviceId);
            SetStatus(ServerStatus.Crashed);
            throw new ProvisionException(!record.ServerType.UsesJava()
                ? $"Couldn't start the server: {e.Message}"
                : $"Couldn't start Java ({spec.FileName}): {e.Message}. Install Java from Settings → Java.", e);
        }
        _proc = p;
        _tailCts?.Cancel();
        _adoptedPid = null;
        Pid = p.Id;
        StartedAt = DateTime.Now;
        Push(LogStream.System, $"Launched pid {p.Id}: {spec.FileName} {string.Join(' ', spec.Args)}");
        ServerSession.Write(record.Path, new(p.Id, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), _rcon?.Port, _rcon?.Password));

        p.OutputDataReceived += (_, e) => OnLine(LogStream.Stdout, e.Data, record.ServerType);
        p.ErrorDataReceived += (_, e) => OnLine(LogStream.Stderr, e.Data, record.ServerType);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        _ = Task.Run(() => Monitor(p, record));
        if (shared) KeepLease(record.Path);
    }

    CancellationTokenSource? _leaseCts;

    /// <summary>While the server runs, refresh our claim every half minute so another PC sees it as busy.</summary>
    void KeepLease(string dir)
    {
        _leaseCts?.Cancel();
        var cts = _leaseCts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try { await Task.Delay(ShareLease.HeartbeatEvery, cts.Token); } catch { return; }
                ShareLease.Heartbeat(dir, ShareLease.ThisDeviceId);
            }
        });
    }

    void ReleaseLease(string dir)
    {
        _leaseCts?.Cancel(); _leaseCts = null;
        if (ShareLease.IsShared(dir)) ShareLease.Release(dir, ShareLease.ThisDeviceId);
    }

    bool _advised;

    void OnLine(LogStream stream, string? text, ServerType type)
    {
        if (text is null) return;
        if (!_advised && StartupAdvice.Classify(text) is { } advice) { _advised = true; Push(LogStream.System, "[OMNIServers] " + advice); }
        if (text.Contains("You need to agree to the EULA")) { NeedsEula = true; StateChanged?.Invoke(); }
        if (Status == ServerStatus.Starting)
        {
            var s = type.IsOmniHost() ? OmniHostAdapter.ParseStatus(text) : type.IsGame() ? GameServers.ParseStatus(type, text) : type.IsBedrock() ? BedrockAdapter.ParseStatus(text) : MinecraftAdapter.ParseStatus(text);
            if (s == ServerStatus.Running) SetStatus(ServerStatus.Running);
        }
        if (type.IsOmniHost())
        {
            // The engine's own console is long and names the engine; show OMNIHost's short version.
            if (OmniHostLog.Simplify(text) is { } shown) Push(stream, shown);
            return;
        }
        Push(stream, text);
    }

    void Monitor(Process p, ServerRecord record)
    {
        p.WaitForExit();   // also waits for the output pipes to drain
        var code = p.ExitCode;
        ExitCode = code;
        Pid = null;
        var crashed = !StopRequested && code != 0;
        Push(LogStream.System, $"Process ended (exit code {code}) — {(crashed ? "crash" : "stopped")}");
        RconService.Shared.Drop(ServerId);
        ServerSession.Clear(record.Path);
        ReleaseLease(record.Path);
        ClearOnline();
        SetStatus(crashed ? ServerStatus.Crashed : ServerStatus.Stopped);
        p.Dispose();
        Exited?.Invoke(record, crashed);
    }

    /// <summary>Re-attaches to a server that kept running while OMNIServers was closed.</summary>
    public bool Adopt(ServerRecord record)
    {
        if (IsRunning || ServerSession.Read(record.Path) is not { } s || !ServerSession.Alive(s.Pid, s.StartedAt)) return false;
        _record = record; DisplayName = record.Name;
        Pid = s.Pid; StartedAt = DateTimeOffset.FromUnixTimeSeconds(s.StartedAt).LocalDateTime;
        ExitCode = null; StopRequested = false; NeedsEula = false; Reattached = true; _adoptedPid = s.Pid;
        _rcon = s.RconPort is { } port && s.RconPassword is { } pw ? (port, pw) : null;
        SetStatus(ServerStatus.Running);
        if (ShareLease.IsShared(record.Path)) KeepLease(record.Path);
        Push(LogStream.System, $"Reattached to this server (pid {s.Pid}) after a OMNIServers restart. Following its log file for new output; commands go over RCON.");

        _tailCts?.Cancel();
        var cts = _tailCts = new CancellationTokenSource();
        var tail = new LogTailer(record.Path);   // starts at the current end of the log, before we return
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try { await Task.Delay(1000, cts.Token); } catch { return; }
                foreach (var l in tail.Poll()) Push(LogStream.Stdout, l);
                if (!ServerSession.Alive(s.Pid, s.StartedAt))
                {
                    Push(LogStream.System, "Reattached server exited.");
                    Pid = null; _adoptedPid = null;
                    ServerSession.Clear(record.Path);
                    ReleaseLease(record.Path);
                    ClearOnline();
                    SetStatus(StopRequested ? ServerStatus.Stopped : ServerStatus.Stopped);
                    Exited?.Invoke(record, false);
                    return;
                }
            }
        });
        if (_rcon is not null)
            _ = Task.Run(async () =>
            {
                try
                {
                    var (_, _, players) = await RconService.Shared.PlayersAsync(record);
                    lock (_gate) { _online.Clear(); _online.AddRange(players); }
                    PlayersChanged?.Invoke();
                }
                catch { }
            });
        return true;
    }

    /// <summary>Graceful stop: send "stop", and force-kill if it hasn't exited after <see cref="GracefulStop"/>.</summary>
    public void Stop()
    {
        if (!IsRunning) return;
        StopRequested = true;
        SetStatus(ServerStatus.Stopping);
        if (_adoptedPid is not null && _record is { } rec)
        {
            // OMNIHost has no RCON: ask it to save and stop with an interrupt (Unix); Windows has no clean equivalent, so it is ended.
            if (rec.ServerType.IsOmniHost()) { if (!TryInterrupt(_adoptedPid.Value)) Kill(); }
            else
            // A re-attached server only has RCON: send "stop" over it, THEN close our connection so the shutdown isn't held up.
            _ = Task.Run(async () =>
            {
                try { await RconService.Shared.RunAsync(rec, "stop"); }
                catch (Exception e) { Push(LogStream.System, "Couldn't send stop over RCON (" + e.Message + ") — force-killing."); Kill(); }
                finally { RconService.Shared.BeginShutdown(ServerId); }
            });
        }
        else
        {
            RconService.Shared.BeginShutdown(ServerId);        // close our RCON connection first: Minecraft waits for it to hang up
            try { SendCommand(GameServers.StopCommand(_record?.ServerType ?? ServerType.Vanilla)); }
            catch { Kill(); return; }
        }
        var pid = Pid;
        _ = Task.Run(async () =>
        {
            var deadline = DateTime.UtcNow + GracefulStop;
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(500);
                if (!IsRunning) return;
            }
            if (IsRunning && Pid == pid)
            {
                Push(LogStream.System, "Didn't stop in time — force-killing.");
                Kill();
                // A big Java process can take a few seconds to disappear; only report a problem if it really won't go.
                for (var i = 0; i < 20 && IsRunning && Pid == pid; i++) await Task.Delay(500);
                if (IsRunning && Pid == pid) Push(LogStream.System, $"Process {pid} is still there after a force-kill — end it in Task Manager (Details tab).");
            }
        });
    }

    /// <summary>SIGINT: Pumpkin saves the world and exits. False where that isn't possible (Windows).</summary>
    static bool TryInterrupt(int pid)
    {
        if (OperatingSystem.IsWindows()) return false;
        try
        {
            using var p = Process.Start(new ProcessStartInfo("kill", ["-INT", pid.ToString()]) { UseShellExecute = false, CreateNoWindow = true });
            p?.WaitForExit(3000);
            return p?.ExitCode == 0;
        }
        catch { return false; }
    }

    public void Kill()
    {
        StopRequested = true;
        if (Pid is { } pid) Proc.KillTree(pid);
    }

    /// <summary>Writes a console command (stdin), or over RCON for a re-adopted server.</summary>
    public void SendCommand(string command)
    {
        if (!IsRunning) throw new InvalidOperationException("The server isn't running.");
        if (_adoptedPid is not null)
        {
            if (_record is null) throw new InvalidOperationException("The server isn't running.");
            var r = _record;
            _ = RconService.Shared.RunAsync(r, command).ContinueWith(t => Push(LogStream.System, t.IsFaulted ? t.Exception!.GetBaseException().Message : t.Result.Trim()));
            return;
        }
        var p = _proc ?? throw new InvalidOperationException("The server isn't running.");
        try { p.StandardInput.WriteLine(command); p.StandardInput.Flush(); }
        catch (Exception) { throw new InvalidOperationException("The server isn't accepting commands (it may have just stopped)."); }
    }

    /// <summary>Sends chat to everyone in-game as "&lt;name&gt; message" (tellraw) and shows it in the Chat tab.</summary>
    public void SendChat(string message, string name)
    {
        SendCommand($"tellraw @a {ChatHistory.TellrawJson(name, message)}");
        AddChat(ChatKind.Mine, name, message);
    }

    /// <summary>Flush the world and pause autosave so a backup isn't a torn copy. Returns false if it couldn't (not running / re-adopted).</summary>
    public async Task<bool> PauseSavesAsync(TimeSpan? timeout = null)
    {
        if (Status != ServerStatus.Running || _adoptedPid is not null) return false;
        long mark;
        lock (_gate) mark = _seq;
        try { SendCommand("save-off"); SendCommand("save-all flush"); } catch { return false; }
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(10));
        while (DateTime.UtcNow < deadline)
        {
            lock (_gate) if (_lines.Any(l => l.Id > mark && l.Text.Contains("Saved the game"))) break;
            await Task.Delay(200);
        }
        return true;
    }

    public void ResumeSaves() { try { if (IsRunning && _adoptedPid is null) SendCommand("save-on"); } catch { } }
}
