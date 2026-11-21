using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace CraftPanel.Cluster.Discovery;

/// <summary>Reads the machine's real IPv4 interfaces (up, multicast-capable, not loopback).</summary>
public sealed class SystemLocalNetwork : ILocalNetwork
{
    public IReadOnlyList<LocalAddress> Addresses()
    {
        var list = new List<LocalAddress>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback || !nic.SupportsMulticast) continue;
                foreach (var ua in nic.GetIPProperties().UnicastAddresses)
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork && ua.PrefixLength > 0) list.Add(new LocalAddress(ua.Address, ua.PrefixLength));
            }
        }
        catch (NetworkInformationException) { }
        return list;
    }
}

/// <summary>
/// mDNS over real UDP: one socket on 5353 shared with whatever else listens there (Windows' own DNS client, Bonjour…),
/// joined to 224.0.0.251 on every interface, sending out of each interface in turn.
/// </summary>
public sealed class UdpMulticastTransport(ILocalNetwork? network = null, int port = 5353) : IMulticastTransport
{
    static readonly IPAddress Group = IPAddress.Parse("224.0.0.251");
    readonly ILocalNetwork _net = network ?? new SystemLocalNetwork();
    readonly object _lock = new();
    Socket? _socket;
    readonly HashSet<IPAddress> _joined = [];
    CancellationTokenSource? _cts;

    public event Action<byte[], IPAddress>? Received;

    public void Start()
    {
        lock (_lock)
        {
            if (_socket is not null) return;
            var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try
            {
                s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                TryReusePort(s);
                s.Bind(new IPEndPoint(IPAddress.Any, port));
                s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
                s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastLoopback, true);
            }
            catch { s.Dispose(); throw; }
            _socket = s;
            _cts = new CancellationTokenSource();
            Rejoin();
            NetworkChange.NetworkAddressChanged += OnNetworkChanged;
            _ = Task.Run(() => ReceiveLoop(s, _cts.Token));
        }
    }

    /// <summary>macOS and Linux need SO_REUSEPORT as well for several listeners (this app, Bonjour, a second CraftPanel) to all hear the group.</summary>
    static void TryReusePort(Socket s)
    {
        try
        {
            var name = RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? 0x200 : RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ? 15 : 0;
            if (name != 0) s.SetRawSocketOption((int)SocketOptionLevel.Socket, name, BitConverter.GetBytes(1));
        }
        catch { /* best effort */ }
    }

    void OnNetworkChanged(object? sender, EventArgs e) { try { Rejoin(); } catch { } }

    /// <summary>Joins the group on every current interface (and notices interfaces that have appeared or gone).</summary>
    void Rejoin()
    {
        lock (_lock)
        {
            if (_socket is null) return;
            var now = _net.Addresses().Select(a => a.Address).ToList();
            foreach (var gone in _joined.Where(j => !now.Contains(j)).ToList()) _joined.Remove(gone);
            foreach (var addr in now.Where(a => !_joined.Contains(a)))
            {
                try { _socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership, new MulticastOption(Group, addr)); _joined.Add(addr); }
                catch (SocketException) { /* an interface that can't do multicast: skip it */ }
            }
        }
    }

    async Task ReceiveLoop(Socket s, CancellationToken ct)
    {
        var buf = new byte[DnsMessage.MaxPacket + 1];
        EndPoint any = new IPEndPoint(IPAddress.Any, 0);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var r = await s.ReceiveFromAsync(buf, SocketFlags.None, any, ct).ConfigureAwait(false);
                if (r.ReceivedBytes is 0 or > DnsMessage.MaxPacket || r.RemoteEndPoint is not IPEndPoint from) continue;
                var data = buf.AsSpan(0, r.ReceivedBytes).ToArray();
                Received?.Invoke(data, from.Address);
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { if (ct.IsCancellationRequested) return; await Task.Delay(250, CancellationToken.None).ConfigureAwait(false); }
            catch (Exception) { /* a listener must outlive a bad packet handler */ }
        }
    }

    public void Send(byte[] packet)
    {
        Socket? s; List<IPAddress> ifaces;
        lock (_lock) { s = _socket; ifaces = [.. _joined]; }
        if (s is null) return;
        var dest = new IPEndPoint(Group, port);
        foreach (var a in ifaces)
        {
            try
            {
                lock (_lock) { s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, a.GetAddressBytes()); s.SendTo(packet, dest); }
            }
            catch (SocketException) { /* this interface is down right now */ }
            catch (ObjectDisposedException) { return; }
        }
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        lock (_lock)
        {
            _cts?.Cancel();
            try { _socket?.Dispose(); } catch { }
            _socket = null;
            _joined.Clear();
        }
    }
}
