using CraftPanel.Cluster.Discovery;
using CraftPanel.Cluster.Identity;

namespace CraftPanel.Cluster;

/// <summary>What the UI is allowed to know about the cluster. The app project talks to this interface and nothing deeper.</summary>
public interface IClusterController
{
    string Hostname { get; }
    string InstanceId { get; }
    ClusterRole Role { get; }
    IReadOnlyList<DiscoveredPeer> Peers { get; }
    /// <summary>Set when discovery couldn't start (for example, the port is in use).</summary>
    string? Problem { get; }
    /// <summary>Set when discovery is running but has heard nothing at all, which on Windows usually means the firewall.</summary>
    FirewallAdvice? Firewall { get; }
    void SetRole(ClusterRole role);
    Task<bool> AllowFirewallAsync();
    event Action? Changed;
}

/// <summary>Owns this PC's cluster state: the saved role and the running discovery service.</summary>
public sealed class ClusterHost : IClusterController, IDisposable
{
    public static ClusterHost Shared { get; } = new();

    static readonly TimeSpan SilenceBeforeFirewallHint = TimeSpan.FromSeconds(12);

    readonly ClusterSettingsStore _store;
    readonly Func<IDiscoveryService> _factory;
    readonly Func<DateTimeOffset> _now;
    readonly object _lock = new();
    ClusterSettings _settings;
    IDiscoveryService? _discovery;
    string? _problem;
    Timer? _watch;

    public ClusterHost(ClusterSettingsStore? store = null, Func<IDiscoveryService>? discoveryFactory = null, Func<DateTimeOffset>? clock = null)
    {
        _store = store ?? new ClusterSettingsStore();
        _factory = discoveryFactory ?? (() => new MdnsDiscoveryService(new UdpMulticastTransport(), new SystemLocalNetwork()));
        _now = clock ?? (() => DateTimeOffset.UtcNow);
        _settings = _store.Load();
    }

    public event Action? Changed;

    public string Hostname => Environment.MachineName;
    public string InstanceId => _settings.InstanceId;
    public ClusterRole Role => _settings.Role;
    public string? Problem => _problem;
    public IReadOnlyList<DiscoveredPeer> Peers => _discovery?.Peers ?? [];

    public FirewallAdvice? Firewall
    {
        get
        {
            if (_discovery is not MdnsDiscoveryService m || !m.IsRunning || !ClusterFirewall.Supported) return null;
            var quiet = m.StartedAt is { } t && _now() - t >= SilenceBeforeFirewallHint;
            return quiet && m.PacketsHeard == 0 ? ClusterFirewall.Advice() : null;
        }
    }

    LocalAdvert Advert() => new(_settings.InstanceId, Hostname, _settings.Role, AppVersion(), _settings.AgentPort);

    static string AppVersion()
    {
        var v = typeof(ClusterHost).Assembly.GetName().Version;
        return v is null ? "?" : $"{v.Major}.{v.Minor}.{v.Build}";
    }

    /// <summary>Called once the app is up: starts discovery if this PC was left in a cluster role.</summary>
    public void Resume() { if (_settings.Role != ClusterRole.Off) StartDiscovery(); }

    public void SetRole(ClusterRole role)
    {
        lock (_lock)
        {
            if (_settings.Role == role && (role == ClusterRole.Off) == (_discovery is null)) return;
            _settings.Role = role;
            _store.Save(_settings);
        }
        if (role == ClusterRole.Off) StopDiscovery();
        else if (_discovery is { IsRunning: true } d) d.Update(Advert());
        else StartDiscovery();
        Changed?.Invoke();
    }

    void StartDiscovery()
    {
        lock (_lock)
        {
            if (_discovery is not null) return;
            try
            {
                var d = _factory();
                d.PeerChanged += _ => Changed?.Invoke();
                d.PeerLost += _ => Changed?.Invoke();
                d.Start(Advert());
                _discovery = d; _problem = null;
                // The firewall hint appears on its own once enough silence has passed.
                _watch = new Timer(_ => Changed?.Invoke(), null, SilenceBeforeFirewallHint + TimeSpan.FromSeconds(1), Timeout.InfiniteTimeSpan);
            }
            catch (Exception e)
            {
                _discovery = null;
                _problem = $"Couldn't start looking for other PCs: {e.Message}";
            }
        }
        Changed?.Invoke();
    }

    void StopDiscovery()
    {
        IDiscoveryService? d;
        lock (_lock) { d = _discovery; _discovery = null; _problem = null; _watch?.Dispose(); _watch = null; }
        d?.Dispose();
    }

    public async Task<bool> AllowFirewallAsync()
    {
        var ok = await ClusterFirewall.AddRuleAsync();
        Changed?.Invoke();
        return ok;
    }

    /// <summary>On app exit: tells the network we're leaving so peers drop us at once.</summary>
    public void Shutdown() => StopDiscovery();

    public void Dispose() => StopDiscovery();
}
