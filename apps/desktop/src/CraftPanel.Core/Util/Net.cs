using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace CraftPanel.Core;

public static class Net
{
    /// <summary>Can we bind this TCP port right now?</summary>
    public static bool PortFree(int port)
    {
        try { var l = new TcpListener(IPAddress.Any, port); l.Start(); l.Stop(); return true; }
        catch (SocketException) { return false; }
    }

    /// <summary>Can we bind this port for this protocol right now? (TCP and UDP are checked separately.)</summary>
    public static bool PortFreeFor(CraftPanel.Core.Network.PortProtocol protocol, int port)
    {
        try
        {
            if (protocol == CraftPanel.Core.Network.PortProtocol.Udp) { using var u = new System.Net.Sockets.UdpClient(new IPEndPoint(IPAddress.Any, port)); return true; }
            return PortFree(port);
        }
        catch (SocketException) { return false; }
    }

    /// <summary>This PC's LAN address: the source address the OS would use for an outbound route.</summary>
    public static string? LanIp()
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            s.Connect("8.8.8.8", 80);
            return (s.LocalEndPoint as IPEndPoint)?.Address.ToString();
        }
        catch
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork)?.Address.ToString();
        }
    }
}
