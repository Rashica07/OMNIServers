using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;

namespace CraftPanel.Core.Network;

/// <summary>A small UPnP Internet Gateway client: find the router (SSDP), then add/remove/check a port mapping over SOAP. No dependencies.</summary>
public static class UPnP
{
    public sealed record Gateway(Uri ControlUrl, string ServiceType);

    public sealed class UPnPException(string message) : Exception(message);

    static readonly string[] ServiceTypes =
    [
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ];

    // ---- discovery -------------------------------------------------------------------

    public static async Task<Gateway?> DiscoverAsync(TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var location = await Task.Run(() => SsdpSearch(timeout ?? TimeSpan.FromSeconds(3)), ct);
        if (location is null || !Uri.TryCreate(location, UriKind.Absolute, out var uri)) return null;
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct); cts.CancelAfter(TimeSpan.FromSeconds(4));
            return ParseDescription(await Http.Client.GetStringAsync(uri, cts.Token), uri);
        }
        catch { return null; }
    }

    static string? SsdpSearch(TimeSpan timeout)
    {
        using var udp = new UdpClient(AddressFamily.InterNetwork);
        udp.Client.ReceiveTimeout = 250;
        var target = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
        foreach (var st in new[] { "urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2" })
        {
            var msg = Encoding.ASCII.GetBytes($"M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {st}\r\n\r\n");
            try { udp.Send(msg, msg.Length, target); } catch (SocketException) { return null; }
        }
        var end = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < end)
        {
            try
            {
                IPEndPoint? from = null;
                var data = udp.Receive(ref from);
                if (ParseSsdpLocation(Encoding.UTF8.GetString(data)) is { } loc) return loc;
            }
            catch (SocketException) { }
        }
        return null;
    }

    public static string? ParseSsdpLocation(string response)
    {
        foreach (var line in response.Split("\r\n"))
        {
            var i = line.IndexOf(':');
            if (i > 0 && line[..i].Trim().Equals("location", StringComparison.OrdinalIgnoreCase))
            {
                var v = line[(i + 1)..].Trim();
                return v.StartsWith("http://") || v.StartsWith("https://") ? v : null;
            }
        }
        return null;
    }

    public static Gateway? ParseDescription(string xml, Uri location)
    {
        XDocument doc;
        try { doc = XDocument.Parse(xml); } catch { return null; }
        static IEnumerable<XElement> Named(XContainer c, string n) => c.Descendants().Where(e => e.Name.LocalName == n);
        var baseUri = Named(doc, "URLBase").FirstOrDefault()?.Value.Trim() is { Length: > 0 } b && Uri.TryCreate(b, UriKind.Absolute, out var bu) ? bu : location;
        var services = Named(doc, "service").ToList();
        foreach (var wanted in ServiceTypes)
            foreach (var svc in services)
            {
                if (svc.Elements().FirstOrDefault(e => e.Name.LocalName == "serviceType")?.Value.Trim() != wanted) continue;
                var ctrl = svc.Elements().FirstOrDefault(e => e.Name.LocalName == "controlURL")?.Value.Trim();
                if (ctrl is null || !Uri.TryCreate(baseUri, ctrl, out var url)) continue;
                return new Gateway(url, wanted);
            }
        return null;
    }

    // ---- SOAP ------------------------------------------------------------------------

    public static string Envelope(string action, string serviceType, IEnumerable<(string, string)> args)
    {
        static string Esc(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
        var body = string.Concat(args.Select(a => $"<{a.Item1}>{Esc(a.Item2)}</{a.Item1}>"));
        return $"<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{action} xmlns:u=\"{serviceType}\">{body}</u:{action}></s:Body></s:Envelope>";
    }

    static async Task<XDocument> CallAsync(Gateway gw, string action, IEnumerable<(string, string)>? args = null, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, gw.ControlUrl)
        {
            Content = new StringContent(Envelope(action, gw.ServiceType, args ?? []), Encoding.UTF8, "text/xml"),
        };
        req.Headers.TryAddWithoutValidation("SOAPAction", $"\"{gw.ServiceType}#{action}\"");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct); cts.CancelAfter(TimeSpan.FromSeconds(6));
        using var resp = await Http.Client.SendAsync(req, cts.Token);
        var text = await resp.Content.ReadAsStringAsync(cts.Token);
        XDocument doc;
        try { doc = XDocument.Parse(text); } catch { throw new UPnPException($"Router replied HTTP {(int)resp.StatusCode}"); }
        if (!resp.IsSuccessStatusCode) throw new UPnPException("Router refused the port-forward: " + (Value(doc, "errorDescription") ?? $"HTTP {(int)resp.StatusCode}"));
        return doc;
    }

    public static string? Value(XDocument doc, string name) => doc.Descendants().FirstOrDefault(e => e.Name.LocalName == name)?.Value.Trim();

    // ---- high level ------------------------------------------------------------------

    /// <summary>Forwards <paramref name="port"/> to this PC; returns the public "ip:port".</summary>
    public static async Task<string> ForwardAsync(int port, bool udp = false, string description = "OMNIServers Minecraft server", CancellationToken ct = default)
    {
        var lan = Net.LanIp() ?? throw new UPnPException("Couldn't find this PC's LAN address.");
        var gw = await DiscoverAsync(null, ct) ?? throw new UPnPException("No UPnP router found on this network.");
        await CallAsync(gw, "AddPortMapping",
        [
            ("NewRemoteHost", ""), ("NewExternalPort", port.ToString()), ("NewProtocol", udp ? "UDP" : "TCP"), ("NewInternalPort", port.ToString()),
            ("NewInternalClient", lan), ("NewEnabled", "1"), ("NewPortMappingDescription", description), ("NewLeaseDuration", "86400"),
        ], ct);
        var ext = Value(await CallAsync(gw, "GetExternalIPAddress", null, ct), "NewExternalIPAddress") ?? "?";
        return $"{ext}:{port}";
    }

    /// <summary>Forwards each (protocol, port) pair; returns the public address of the first. One UPnP call per pair.</summary>
    public static async Task<string> ForwardRulesAsync(IEnumerable<PortRule> rules, string description, CancellationToken ct = default)
    {
        string? addr = null;
        foreach (var (proto, port) in PortRules.Expand(rules).Distinct())
        {
            var a = await ForwardAsync(port, proto == PortProtocol.Udp, $"{description} ({proto.ToString().ToUpperInvariant()})", ct);
            addr ??= a;
        }
        return addr ?? throw new UPnPException("There are no ports to forward.");
    }

    public static async Task RemoveRulesAsync(IEnumerable<PortRule> rules, CancellationToken ct = default)
    {
        foreach (var (proto, port) in PortRules.Expand(rules).Distinct()) await RemoveAsync(port, proto == PortProtocol.Udp, ct);
    }

    /// <summary>True only when every (protocol, port) pair is mapped.</summary>
    public static async Task<(bool Available, bool Mapped)> StatusRulesAsync(IEnumerable<PortRule> rules, CancellationToken ct = default)
    {
        var all = true; var available = true;
        foreach (var (proto, port) in PortRules.Expand(rules).Distinct())
        {
            var (a, m) = await StatusAsync(port, proto == PortProtocol.Udp, ct);
            available &= a; all &= m;
            if (!a) break;
        }
        return (available, available && all);
    }

    public static async Task RemoveAsync(int port, bool udp = false, CancellationToken ct = default)
    {
        var gw = await DiscoverAsync(null, ct) ?? throw new UPnPException("No UPnP router found on this network.");
        await CallAsync(gw, "DeletePortMapping", [("NewRemoteHost", ""), ("NewExternalPort", port.ToString()), ("NewProtocol", udp ? "UDP" : "TCP")], ct);
    }

    public static async Task<(bool Available, bool Mapped)> StatusAsync(int port, bool udp = false, CancellationToken ct = default)
    {
        var gw = await DiscoverAsync(null, ct);
        if (gw is null) return (false, false);
        for (var i = 0; i < 64; i++)
        {
            XDocument doc;
            try { doc = await CallAsync(gw, "GetGenericPortMappingEntry", [("NewPortMappingIndex", i.ToString())], ct); } catch { break; }
            if (Value(doc, "NewExternalPort") == port.ToString() && string.Equals(Value(doc, "NewProtocol"), udp ? "UDP" : "TCP", StringComparison.OrdinalIgnoreCase)) return (true, true);
        }
        return (true, false);
    }
}
