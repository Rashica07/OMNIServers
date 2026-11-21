using System.Diagnostics;
using System.IO.Compression;
using System.Text.RegularExpressions;

namespace CraftPanel.Core.Network;

public sealed record TunnelStatus(bool Running = false, string? Address = null, string? Error = null);

/// <summary>
/// A free tunnel with no account and no browser: runs the <c>bore</c> client (github.com/ekzhang/bore, MIT), which gives the
/// server a <c>bore.pub:&lt;port&gt;</c> address that works from anywhere. The address is stable while the tunnel runs and
/// changes if it's restarted. The client is downloaded once and checked against a pinned SHA-256 before it's ever run.
/// </summary>
public sealed class TunnelManager
{
    public static TunnelManager Shared { get; } = new();

    public const string BoreVersion = "v0.6.0";
    /// <summary>SHA-256 of the official release archive (published by GitHub for v0.6.0).</summary>
    const string WindowsX64Sha256 = "01709c64fe2787cdc9a21d7030b0f08ad72dff0c36b7ecb72f4f667a55a34b4f";
    const string WindowsX64Asset = "x86_64-pc-windows-msvc.zip";

    readonly Dictionary<Guid, Process> _procs = [];
    readonly Dictionary<Guid, TunnelStatus> _status = [];
    readonly object _lock = new();

    /// <summary>Raised (from any thread) whenever a tunnel's state changes.</summary>
    public event Action<Guid>? Changed;

    /// <summary>For tests: run this program instead of downloading bore.</summary>
    public string? ExecutableOverride { get; set; }
    string? _binDir;
    public string BinDir { get => _binDir ?? Path.Combine(AppPaths.LocalDir, "bore"); set => _binDir = value; }

    public TunnelStatus Status(Guid id) { lock (_lock) return _status.GetValueOrDefault(id) ?? new(); }

    void Set(Guid id, Func<TunnelStatus, TunnelStatus> f)
    {
        lock (_lock) _status[id] = f(_status.GetValueOrDefault(id) ?? new());
        Changed?.Invoke(id);
    }

    /// <summary>Downloads bore if it isn't here yet (Windows only; the x64 build also runs on Windows-on-ARM).</summary>
    public async Task<string> EnsureBoreAsync(IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        if (ExecutableOverride is { } o) return o;
        if (!OperatingSystem.IsWindows()) throw new ProvisionException("The built-in tunnel is only available on Windows for now. On Linux, use your own tunnel or port forwarding.");
        var exe = Path.Combine(BinDir, "bore.exe");
        if (File.Exists(exe)) return exe;

        Directory.CreateDirectory(BinDir);
        var zip = Path.Combine(BinDir, "bore.zip");
        await Http.DownloadAsync($"https://github.com/ekzhang/bore/releases/download/{BoreVersion}/bore-{BoreVersion}-{WindowsX64Asset}", zip, "the tunnel client", progress, ct);
        if (!Http.Sha256Hex(zip).Equals(WindowsX64Sha256, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(zip);
            throw new ProvisionException("The tunnel client failed its integrity check, so OMNIServers deleted it rather than run it.");
        }
        try
        {
            using var z = ZipFile.OpenRead(zip);
            var entry = z.Entries.FirstOrDefault(e => e.Name.Equals("bore.exe", StringComparison.OrdinalIgnoreCase))
                ?? throw new ProvisionException("The tunnel client archive didn't contain bore.exe.");
            entry.ExtractToFile(exe, overwrite: true);   // only that one named entry is ever extracted
        }
        finally { try { File.Delete(zip); } catch { } }
        return exe;
    }

    public async Task StartAsync(Guid id, int port, IProgress<ProvisionProgress>? progress = null)
    {
        lock (_lock) if (_procs.ContainsKey(id)) return;
        try
        {
            var bore = await EnsureBoreAsync(progress);
            var psi = new ProcessStartInfo(bore) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "local", port.ToString(), "--to", "bore.pub" }) psi.ArgumentList.Add(a);
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (_, e) => OnLine(id, e.Data);
            p.ErrorDataReceived += (_, e) => OnLine(id, e.Data);
            p.Exited += (_, _) => OnExited(id, p);
            lock (_lock) _procs[id] = p;
            Set(id, _ => new(Running: true));
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }
        catch (Exception e)
        {
            lock (_lock) _procs.Remove(id);
            Set(id, _ => new(Running: false, Error: e.Message));
        }
    }

    static readonly Regex Ansi = new("\u001b\\[[0-9;]*[A-Za-z]", RegexOptions.Compiled);
    static readonly Regex Listening = new(@"listening at (\S+)", RegexOptions.Compiled);

    /// <summary>bore logs to stderr; the address is on the "listening at bore.pub:NNNNN" line.</summary>
    internal void OnLine(Guid id, string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return;
        var line = Ansi.Replace(raw, "").Trim();
        if (Listening.Match(line) is { Success: true } m) Set(id, s => s with { Address = m.Groups[1].Value, Error = null });
        else if (line.Contains("error", StringComparison.OrdinalIgnoreCase) || line.Contains("failed", StringComparison.OrdinalIgnoreCase) || line.Contains("refused", StringComparison.OrdinalIgnoreCase))
            Set(id, s => s with { Error = line });
    }

    void OnExited(Guid id, Process p)
    {
        lock (_lock) { if (!_procs.TryGetValue(id, out var cur) || cur != p) return; _procs.Remove(id); }
        Set(id, s => s with { Running = false, Address = null });
    }

    public void Stop(Guid id)
    {
        Process? p;
        lock (_lock) { _procs.Remove(id, out p); }
        try { p?.Kill(entireProcessTree: true); } catch { }
        Set(id, _ => new());
    }

    /// <summary>On app exit — a bore child would otherwise keep running with nothing to show for it.</summary>
    public void StopAll()
    {
        List<Guid> ids;
        lock (_lock) ids = [.. _procs.Keys];
        foreach (var id in ids) Stop(id);
    }
}
