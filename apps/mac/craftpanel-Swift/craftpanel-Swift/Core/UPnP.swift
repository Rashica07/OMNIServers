import Foundation
import Darwin

/// Automatic router port-forwarding (UPnP IGD) — port of `net.rs`'s
/// `upnp_forward` / `upnp_remove` / `has_mapping`, which used the
/// `igd-next` crate. Native, dependency-free: SSDP discovery over a UDP
/// socket, the router's device description over HTTP, SOAP control calls.
/// Leases last 24 h (same as Rust); Java = TCP, Bedrock/Geyser = UDP.
nonisolated enum UPnP {
    struct Gateway: Sendable, Equatable {
        var controlURL: URL
        var serviceType: String
    }

    enum UPnPError: LocalizedError {
        case noRouter, noLAN, refused(String)
        var errorDescription: String? {
            switch self {
            case .noRouter: "No UPnP router found on this network."
            case .noLAN: "Couldn't find this Mac's LAN address."
            case .refused(let m): "Router refused the port-forward: \(m)"
            }
        }
    }

    static let serviceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    // MARK: Discovery

    static func discover(timeout: TimeInterval = 3) async -> Gateway? {
        guard let location = await Task.detached(operation: { ssdpSearch(timeout: timeout) }).value,
              let url = URL(string: location) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4)) else { return nil }
        return parseDescription(data, location: url)
    }

    /// Blocking SSDP M-SEARCH; returns the first IGD LOCATION header.
    private static func ssdpSearch(timeout: TimeInterval) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        for st in ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2"] {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
            _ = msg.withCString { p in
                withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, p, strlen(p), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                } }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            if let loc = parseSSDPLocation(String(decoding: buf[0..<n], as: UTF8.self)) { return loc }
        }
        return nil
    }

    static func parseSSDPLocation(_ response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                return v.hasPrefix("http://") || v.hasPrefix("https://") ? v : nil
            }
        }
        return nil
    }

    /// Find the WAN connection service's controlURL in the device XML.
    static func parseDescription(_ xml: Data, location: URL) -> Gateway? {
        guard let doc = try? XMLDocument(data: xml) else { return nil }
        let base = (try? doc.nodes(forXPath: "//*[local-name()='URLBase']").first?.stringValue)
            .flatMap { $0.flatMap(URL.init(string:)) } ?? location
        guard let services = try? doc.nodes(forXPath: "//*[local-name()='service']") else { return nil }
        for wanted in serviceTypes {
            for svc in services {
                let type = (try? svc.nodes(forXPath: "*[local-name()='serviceType']").first?.stringValue) ?? nil
                guard type?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted,
                      let ctrl = (try? svc.nodes(forXPath: "*[local-name()='controlURL']").first?.stringValue) ?? nil,
                      let url = URL(string: ctrl.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL
                else { continue }
                return Gateway(controlURL: url, serviceType: wanted)
            }
        }
        return nil
    }

    // MARK: SOAP

    static func envelope(action: String, serviceType: String, args: [(String, String)]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = args.map { "<\($0.0)>\(esc($0.1))</\($0.0)>" }.joined()
        return """
        <?xml version="1.0"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(serviceType)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
    }

    @discardableResult
    static func call(_ gw: Gateway, _ action: String, _ args: [(String, String)] = []) async throws -> XMLDocument {
        var req = URLRequest(url: gw.controlURL, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(gw.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(envelope(action: action, serviceType: gw.serviceType, args: args).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let doc = try XMLDocument(data: data)
        if (resp as? HTTPURLResponse)?.statusCode != 200 {
            let desc = (try? doc.nodes(forXPath: "//*[local-name()='errorDescription']").first?.stringValue) ?? nil
            throw UPnPError.refused(desc ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return doc
    }

    static func value(_ doc: XMLDocument, _ name: String) -> String? {
        ((try? doc.nodes(forXPath: "//*[local-name()='\(name)']").first?.stringValue) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: High level (mirrors net.rs)

    /// Forward `port` to this Mac for 24 h; returns "publicIP:port".
    static func forward(port: UInt16, udp: Bool, description: String = "OMNIServers Minecraft server") async throws -> String {
        guard let lan = NetworkInfo.lanIP() else { throw UPnPError.noLAN }
        guard let gw = await discover() else { throw UPnPError.noRouter }
        try await call(gw, "AddPortMapping", [
            ("NewRemoteHost", ""), ("NewExternalPort", "\(port)"), ("NewProtocol", udp ? "UDP" : "TCP"),
            ("NewInternalPort", "\(port)"), ("NewInternalClient", lan), ("NewEnabled", "1"),
            ("NewPortMappingDescription", description), ("NewLeaseDuration", "86400"),
        ])
        let ext = value(try await call(gw, "GetExternalIPAddress"), "NewExternalIPAddress") ?? "?"
        return "\(ext):\(port)"
    }

    static func remove(port: UInt16, udp: Bool) async throws {
        guard let gw = await discover() else { throw UPnPError.noRouter }
        try await call(gw, "DeletePortMapping", [("NewRemoteHost", ""), ("NewExternalPort", "\(port)"), ("NewProtocol", udp ? "UDP" : "TCP")])
    }

    /// (router found, port currently mapped)
    static func status(port: UInt16, udp: Bool) async -> (available: Bool, mapped: Bool) {
        guard let gw = await discover() else { return (false, false) }
        for i in 0..<64 {
            guard let doc = try? await call(gw, "GetGenericPortMappingEntry", [("NewPortMappingIndex", "\(i)")]) else { break }
            if value(doc, "NewExternalPort") == "\(port)", value(doc, "NewProtocol")?.uppercased() == (udp ? "UDP" : "TCP") {
                return (true, true)
            }
        }
        return (true, false)
    }

    // MARK: Several ports at once (Bedrock 26.60 needs TCP and UDP on the same port)

    /// Forwards every (protocol, port) in `rules`; returns "publicIP:firstPort".
    static func forward(rules: [PortRule], description: String = "OMNIServers Minecraft server") async throws -> String {
        guard let lan = NetworkInfo.lanIP() else { throw UPnPError.noLAN }
        guard let gw = await discover() else { throw UPnPError.noRouter }
        let pairs = PortRules.expand(rules)
        for p in pairs {
            try await call(gw, "AddPortMapping", [
                ("NewRemoteHost", ""), ("NewExternalPort", "\(p.port)"), ("NewProtocol", p.proto == .udp ? "UDP" : "TCP"),
                ("NewInternalPort", "\(p.port)"), ("NewInternalClient", lan), ("NewEnabled", "1"),
                ("NewPortMappingDescription", description), ("NewLeaseDuration", "86400"),
            ])
        }
        let ext = value(try await call(gw, "GetExternalIPAddress"), "NewExternalIPAddress") ?? "?"
        return "\(ext):\(pairs.first?.port ?? 0)"
    }

    static func remove(rules: [PortRule]) async throws {
        guard let gw = await discover() else { throw UPnPError.noRouter }
        for p in PortRules.expand(rules) {
            try await call(gw, "DeletePortMapping", [("NewRemoteHost", ""), ("NewExternalPort", "\(p.port)"), ("NewProtocol", p.proto == .udp ? "UDP" : "TCP")])
        }
    }

    /// (router found, EVERY port currently mapped)
    static func status(rules: [PortRule]) async -> (available: Bool, mapped: Bool) {
        guard let gw = await discover() else { return (false, false) }
        var found = Set<String>()
        for i in 0..<64 {
            guard let doc = try? await call(gw, "GetGenericPortMappingEntry", [("NewPortMappingIndex", "\(i)")]) else { break }
            if let port = value(doc, "NewExternalPort"), let proto = value(doc, "NewProtocol") { found.insert("\(proto.uppercased())\(port)") }
        }
        let need = PortRules.expand(rules).map { "\($0.proto == .udp ? "UDP" : "TCP")\($0.port)" }
        return (true, !need.isEmpty && need.allSatisfy(found.contains))
    }
}
