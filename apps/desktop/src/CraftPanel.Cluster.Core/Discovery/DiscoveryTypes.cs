using System.Net;

namespace CraftPanel.Cluster.Discovery;

public enum ClusterRole { Off, Primary, Node }

/// <summary>What this PC tells the network about itself. Nothing else is ever advertised: no server names, no paths, no user names.</summary>
public sealed record LocalAdvert(string InstanceId, string Hostname, ClusterRole Role, string AppVersion, int AgentPort);

/// <summary>Another CraftPanel PC seen on the local network.</summary>
public sealed record DiscoveredPeer(string InstanceId, string Hostname, ClusterRole Role, string AppVersion, IPAddress Address, int AgentPort, DateTimeOffset LastSeen);

/// <summary>Finds other CraftPanel PCs on the local subnet and lets them find this one. No internet traffic.</summary>
public interface IDiscoveryService : IDisposable
{
    IReadOnlyList<DiscoveredPeer> Peers { get; }
    /// <summary>A peer appeared or changed (role, address, version…).</summary>
    event Action<DiscoveredPeer>? PeerChanged;
    event Action<DiscoveredPeer>? PeerLost;
    bool IsRunning { get; }
    void Start(LocalAdvert advert);
    /// <summary>Re-announce after something advertised changed (the role, mostly).</summary>
    void Update(LocalAdvert advert);
    void Stop();
}

/// <summary>The multicast pipe under discovery, so the logic can be tested without a network.</summary>
public interface IMulticastTransport : IDisposable
{
    event Action<byte[], IPAddress>? Received;
    /// <summary>Starts listening; throws if the port can't be used.</summary>
    void Start();
    /// <summary>Sends one packet to the mDNS group on every usable interface.</summary>
    void Send(byte[] packet);
}

public readonly record struct LocalAddress(IPAddress Address, int PrefixLength);

/// <summary>What the PC's own network looks like; the subnet check that keeps discovery local lives here.</summary>
public interface ILocalNetwork
{
    IReadOnlyList<LocalAddress> Addresses();
}

public static class Subnets
{
    /// <summary>
    /// True only for an IPv4 address that shares a subnet with one of this PC's own addresses. Public addresses, other
    /// subnets, loopback and IPv6 all return false: discovery is for the same ethernet/LAN and nothing wider.
    /// </summary>
    public static bool IsOnLocalSubnet(IPAddress candidate, IEnumerable<LocalAddress> local)
    {
        if (candidate.IsIPv4MappedToIPv6) candidate = candidate.MapToIPv4();
        if (candidate.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork || IPAddress.IsLoopback(candidate)) return false;
        var c = candidate.GetAddressBytes();
        foreach (var l in local)
        {
            if (l.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork || l.PrefixLength is < 1 or > 32) continue;
            var a = l.Address.GetAddressBytes();
            var bits = l.PrefixLength;
            var match = true;
            for (var i = 0; i < 4 && bits > 0; i++, bits -= 8)
            {
                var mask = bits >= 8 ? 0xFF : (0xFF << (8 - bits)) & 0xFF;
                if ((a[i] & mask) != (c[i] & mask)) { match = false; break; }
            }
            if (match) return true;
        }
        return false;
    }
}
