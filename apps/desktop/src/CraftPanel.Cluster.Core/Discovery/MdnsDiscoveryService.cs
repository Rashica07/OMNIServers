using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace CraftPanel.Cluster.Discovery;

/// <summary>
/// Advertises this PC as <c>_craftpanel-cluster._tcp</c> over mDNS and keeps a list of the other CraftPanel PCs heard on the
/// same subnet. Wire format: see docs/cluster/PROTOCOL.md. Everything heard is untrusted: it's parsed defensively, limited
/// to the local subnet, and capped in size. Discovery only says "a CraftPanel PC is here"; it grants nothing (pairing does).
/// </summary>
public sealed partial class MdnsDiscoveryService : IDiscoveryService
{
    public const string ServiceType = "_craftpanel-cluster._tcp.local";
    public const string ProtocolVersion = "1";
    public const int MaxPeers = 64;
    public static readonly TimeSpan RecordTtl = TimeSpan.FromSeconds(120);
    public static readonly TimeSpan QueryEvery = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan MinResponseGap = TimeSpan.FromSeconds(1);

    readonly IMulticastTransport _transport;
    readonly ILocalNetwork _net;
    readonly Func<DateTimeOffset> _now;
    readonly object _lock = new();
    readonly Dictionary<string, PeerState> _peers = [];
    readonly Dictionary<string, Partial> _partial = [];
    Timer? _timer;
    LocalAdvert? _self;
    DateTimeOffset _lastAdvert = DateTimeOffset.MinValue, _lastQuery = DateTimeOffset.MinValue, _announceAgainAt = DateTimeOffset.MaxValue;

    sealed class PeerState { public required DiscoveredPeer Peer; public DateTimeOffset ExpiresAt; }
    sealed class Partial { public SrvRecord? Srv; public TxtRecord? Txt; public DateTimeOffset At; }

    public MdnsDiscoveryService(IMulticastTransport transport, ILocalNetwork network, Func<DateTimeOffset>? clock = null, bool autoTimer = true)
    {
        _transport = transport; _net = network; _now = clock ?? (() => DateTimeOffset.UtcNow);
        _autoTimer = autoTimer;
    }
    readonly bool _autoTimer;

    public event Action<DiscoveredPeer>? PeerChanged;
    public event Action<DiscoveredPeer>? PeerLost;
    public bool IsRunning { get; private set; }
    /// <summary>When discovery started, for "has it heard anything yet?" checks.</summary>
    public DateTimeOffset? StartedAt { get; private set; }
    /// <summary>Every mDNS packet that reached us, ours included. Zero for a while after start usually means a firewall is dropping them.</summary>
    public int PacketsHeard => Volatile.Read(ref _packets);
    int _packets;

    public IReadOnlyList<DiscoveredPeer> Peers { get { lock (_lock) return _peers.Values.Select(p => p.Peer).OrderBy(p => p.Hostname, StringComparer.OrdinalIgnoreCase).ToList(); } }

    // ---- lifecycle -------------------------------------------------------------------------------

    public void Start(LocalAdvert advert)
    {
        lock (_lock)
        {
            if (IsRunning) { _self = advert; return; }
            _self = advert;
            _transport.Received += OnReceived;
            try { _transport.Start(); }
            catch { _transport.Received -= OnReceived; throw; }
            IsRunning = true; StartedAt = _now(); Volatile.Write(ref _packets, 0);
            _announceAgainAt = _now() + TimeSpan.FromSeconds(1);   // RFC 6762: announce twice, a second apart
            if (_autoTimer) _timer = new Timer(_ => Tick(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        }
        SendQuery();
        SendAdvertisement(RecordTtl, force: true);
    }

    public void Update(LocalAdvert advert)
    {
        lock (_lock) { if (!IsRunning) { _self = advert; return; } _self = advert; _announceAgainAt = _now() + TimeSpan.FromSeconds(1); }
        SendAdvertisement(RecordTtl, force: true);
    }

    public void Stop()
    {
        List<DiscoveredPeer> gone;
        lock (_lock)
        {
            if (!IsRunning) return;
            IsRunning = false;
            _timer?.Dispose(); _timer = null;
            gone = _peers.Values.Select(p => p.Peer).ToList();
            _peers.Clear(); _partial.Clear();
        }
        SendAdvertisement(TimeSpan.Zero, force: true);      // goodbye: peers drop us at once instead of waiting out the TTL
        _transport.Received -= OnReceived;
        _transport.Dispose();
        foreach (var p in gone) PeerLost?.Invoke(p);
    }

    public void Dispose() => Stop();

    // ---- timer -----------------------------------------------------------------------------------

    /// <summary>Called every couple of seconds: drops peers that went quiet, re-asks, and sends the second announcement.</summary>
    internal void Tick()
    {
        List<DiscoveredPeer> expired = [];
        bool query, announce;
        lock (_lock)
        {
            if (!IsRunning) return;
            var now = _now();
            foreach (var (id, st) in _peers.ToList()) if (st.ExpiresAt <= now) { expired.Add(st.Peer); _peers.Remove(id); }
            foreach (var k in _partial.Where(kv => now - kv.Value.At > TimeSpan.FromMinutes(5)).Select(kv => kv.Key).ToList()) _partial.Remove(k);
            query = now - _lastQuery >= QueryEvery;
            announce = now >= _announceAgainAt;
            if (announce) _announceAgainAt = DateTimeOffset.MaxValue;
        }
        foreach (var p in expired) PeerLost?.Invoke(p);
        if (query) SendQuery();
        if (announce) SendAdvertisement(RecordTtl, force: true);
    }

    // ---- sending ---------------------------------------------------------------------------------

    string? InstanceName() => _self is null ? null : $"CraftPanel-{_self.InstanceId[..Math.Min(8, _self.InstanceId.Length)]}.{ServiceType}";

    void SendQuery()
    {
        lock (_lock) _lastQuery = _now();
        var q = new DnsMessage { IsResponse = false };
        q.Questions.Add(new DnsQuestion(ServiceType, (ushort)DnsType.Ptr));
        Send(q);
    }

    void SendAdvertisement(TimeSpan ttl, bool force)
    {
        DnsMessage m;
        lock (_lock)
        {
            if (_self is null) return;
            var now = _now();
            if (!force && now - _lastAdvert < MinResponseGap) return;      // a flood of queries can't make us flood the network
            _lastAdvert = now;
            m = BuildAdvertisement(_self, (uint)ttl.TotalSeconds);
        }
        Send(m);
    }

    DnsMessage BuildAdvertisement(LocalAdvert self, uint ttl)
    {
        var instance = InstanceName()!;
        var host = HostLabel(self.Hostname) + ".local";
        var m = new DnsMessage { IsResponse = true };
        m.Records.Add(new PtrRecord(ServiceType, instance, ttl));
        m.Records.Add(new SrvRecord(instance, (ushort)self.AgentPort, host, ttl) { CacheFlush = true });
        m.Records.Add(new TxtRecord(instance, new Dictionary<string, string>
        {
            ["proto"] = ProtocolVersion, ["id"] = self.InstanceId, ["host"] = Truncate(self.Hostname, 63),
            ["role"] = self.Role == ClusterRole.Node ? "node" : "primary", ["ver"] = Truncate(self.AppVersion, 32),
        }, ttl) { CacheFlush = true });
        foreach (var a in _net.Addresses()) m.Records.Add(new ARecord(host, a.Address, ttl) { CacheFlush = true });
        return m;
    }

    void Send(DnsMessage m)
    {
        try { _transport.Send(m.Write()); } catch (Exception) { /* a send that fails is the same as a packet lost: the next announcement covers it */ }
    }

    // ---- receiving -------------------------------------------------------------------------------

    void OnReceived(byte[] data, IPAddress from)
    {
        try
        {
            Interlocked.Increment(ref _packets);
            if (!Subnets.IsOnLocalSubnet(from, _net.Addresses())) return;           // not the same LAN: never even parsed
            if (!DnsMessage.TryParse(data, out var m)) return;
            if (m.IsResponse) HandleResponse(m, from); else HandleQuery(m);
        }
        catch (Exception) { /* nothing a stranger sends may take discovery down */ }
    }

    void HandleQuery(DnsMessage m)
    {
        string? instance;
        lock (_lock) instance = InstanceName();
        if (instance is null) return;
        foreach (var q in m.Questions)
        {
            var ours = (q.Type is (ushort)DnsType.Ptr or 255 && Same(q.Name, ServiceType))
                    || (q.Type is (ushort)DnsType.Srv or (ushort)DnsType.Txt or 255 && Same(q.Name, instance));
            if (ours) { SendAdvertisement(RecordTtl, force: false); return; }
        }
    }

    void HandleResponse(DnsMessage m, IPAddress from)
    {
        var instances = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var goodbyes = new List<string>();
        lock (_lock)
        {
            if (!IsRunning) return;
            var now = _now();
            foreach (var r in m.Records)
            {
                switch (r)
                {
                    case PtrRecord p when Same(p.Name, ServiceType) && EndsWithService(p.Target):
                        if (p.Ttl == 0) goodbyes.Add(p.Target); else instances.Add(p.Target);
                        break;
                    case SrvRecord s when EndsWithService(s.Name):
                        GetPartial(s.Name, now).Srv = s; instances.Add(s.Name); break;
                    case TxtRecord t when EndsWithService(t.Name):
                        GetPartial(t.Name, now).Txt = t; instances.Add(t.Name); break;
                }
            }
        }
        foreach (var g in goodbyes) RemoveByInstance(g);
        foreach (var i in instances) TryMakePeer(i, from);
    }

    Partial GetPartial(string instance, DateTimeOffset now)
    {
        if (!_partial.TryGetValue(instance, out var p))
        {
            if (_partial.Count >= MaxPeers * 4) return new Partial();   // a flood of made-up instances can't grow memory
            _partial[instance] = p = new Partial();
        }
        p.At = now;
        return p;
    }

    void RemoveByInstance(string instance)
    {
        DiscoveredPeer? gone = null;
        lock (_lock)
        {
            _partial.Remove(instance);
            var hit = _peers.FirstOrDefault(kv => Same(InstanceNameFor(kv.Key), instance));
            if (hit.Value is not null) { gone = hit.Value.Peer; _peers.Remove(hit.Key); }
        }
        if (gone is not null) PeerLost?.Invoke(gone);
    }

    static string InstanceNameFor(string id) => $"CraftPanel-{id[..Math.Min(8, id.Length)]}.{ServiceType}";

    void TryMakePeer(string instance, IPAddress from)
    {
        DiscoveredPeer? changed = null;
        lock (_lock)
        {
            if (_self is null || !_partial.TryGetValue(instance, out var part) || part.Srv is not { } srv || part.Txt is not { } txt) return;
            var v = txt.Values;
            if (!v.TryGetValue("proto", out var proto) || proto != ProtocolVersion) return;              // a version we can't speak
            if (!v.TryGetValue("id", out var id) || !IdPattern().IsMatch(id) || id == _self.InstanceId) return;   // malformed, or our own packet coming back
            if (!Same(instance, InstanceNameFor(id))) return;                                            // the name has to match the id it claims
            var role = v.GetValueOrDefault("role") switch { "primary" => ClusterRole.Primary, "node" => ClusterRole.Node, _ => ClusterRole.Off };
            if (role == ClusterRole.Off || srv.Ttl == 0) return;
            if (!_peers.ContainsKey(id) && _peers.Count >= MaxPeers) return;
            var addr = from.IsIPv4MappedToIPv6 ? from.MapToIPv4() : from;                               // the address the packet really came from, not one it claims
            var peer = new DiscoveredPeer(id, CleanText(v.GetValueOrDefault("host"), 63, srv.Target), role, CleanText(v.GetValueOrDefault("ver"), 32, "?"), addr, srv.Port, _now());
            var ttl = TimeSpan.FromSeconds(Math.Min(srv.Ttl, 4500));
            if (_peers.TryGetValue(id, out var existing))
            {
                var same = existing.Peer with { LastSeen = peer.LastSeen } == peer;
                existing.Peer = peer; existing.ExpiresAt = _now() + ttl;
                if (same) return;
            }
            else _peers[id] = new PeerState { Peer = peer, ExpiresAt = _now() + ttl };
            changed = peer;
        }
        if (changed is not null) PeerChanged?.Invoke(changed);
    }

    // ---- helpers ---------------------------------------------------------------------------------

    static bool Same(string a, string b) => string.Equals(a.TrimEnd('.'), b.TrimEnd('.'), StringComparison.OrdinalIgnoreCase);
    static bool EndsWithService(string name) => name.TrimEnd('.').EndsWith("." + ServiceType, StringComparison.OrdinalIgnoreCase);
    static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    /// <summary>Text from the network is shown to the user: no control characters, bounded length.</summary>
    static string CleanText(string? s, int max, string fallback)
    {
        if (string.IsNullOrWhiteSpace(s)) return fallback;
        var sb = new StringBuilder();
        foreach (var c in s) { if (!char.IsControl(c)) sb.Append(c); if (sb.Length >= max) break; }
        return sb.Length == 0 ? fallback : sb.ToString();
    }

    /// <summary>A DNS-safe host label (letters, digits, hyphen) from the machine name.</summary>
    internal static string HostLabel(string hostname)
    {
        var sb = new StringBuilder();
        foreach (var c in hostname) sb.Append(char.IsAsciiLetterOrDigit(c) ? c : '-');
        var s = sb.ToString().Trim('-');
        return s.Length == 0 ? "craftpanel-pc" : s.Length > 60 ? s[..60] : s;
    }

    [GeneratedRegex("^[0-9a-f]{8,64}$")] private static partial Regex IdPattern();
}
