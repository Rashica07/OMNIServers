import Foundation
import Darwin
import Network

/// "How do my friends join?" — LAN address, public IP, and a CGNAT check.
/// Direct port of `net.rs`'s `NetInfo`/`info()`.
///
/// UPnP automatic port-forwarding isn't ported (`net.rs`'s `upnp_*`
/// functions, backed by the `igd_next` crate's full SSDP-discovery +
/// UPnP-IGD SOAP client) — there's no macOS framework for this, and a
/// hand-rolled implementation with no real router to test against is a
/// worse outcome than an honest gap. `NetworkView` says so directly
/// rather than pretending to forward a port and silently doing nothing.
nonisolated struct NetInfo: Sendable {
    var port: UInt16
    var lanIP: String?
    var lanAddress: String?
    var publicIP: String?
    var publicAddress: String?
    /// public IP is carrier-grade NAT (100.64/10) — forwarding won't help
    var likelyCGNAT: Bool
}

nonisolated enum NetworkInfo {
    static func port(serverDir: URL) -> UInt16 {
        if let p = PumpkinConfig.javaPort(serverDir: serverDir) { return p }
        let props = Properties.load(dir: serverDir)
        guard let raw = props.get("server-port"), let p = UInt16(raw), p != 0 else { return 25565 }
        return p
    }

    /// `connect()` on a UDP socket sends nothing — it just makes the
    /// kernel pick the route, so `getsockname` afterward reports this
    /// machine's real outbound LAN address. Same trick `net.rs` uses via
    /// `std::net::UdpSocket`, here via the raw BSD socket calls Darwin
    /// exposes directly — no extra dependency either way.
    static func lanIP() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(80).bigEndian
        remote.sin_addr.s_addr = inet_addr("8.8.8.8")
        let connected = withUnsafePointer(to: &remote) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard got == 0 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        let ip = String(cString: buf)
        return (ip == "0.0.0.0" || ip.hasPrefix("127.")) ? nil : ip
    }

    static func publicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidIPv4(ip) ? ip : nil
    }

    static func isCGNAT(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    static func info(serverDir: URL) async -> NetInfo {
        let p = port(serverDir: serverDir)
        let lan = lanIP()
        let pub = await publicIP()
        return NetInfo(
            port: p,
            lanIP: lan,
            lanAddress: lan.map { "\($0):\(p)" },
            publicIP: pub,
            publicAddress: pub.map { "\($0):\(p)" },
            likelyCGNAT: pub.map(isCGNAT) ?? false
        )
    }

    /// A small, local reachability check for the Network screen.  This
    /// distinguishes a stopped server from one that is up but unreachable
    /// through this Mac's LAN address (usually a firewall or client-isolation
    /// policy).  It never contacts the public internet.
    static func canConnect(host: String, port: UInt16, timeout: TimeInterval = 2) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let completion = ConnectionCompletion()
            @Sendable func finish(_ result: Bool) {
                guard completion.take() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "CraftPanel.LANCheck"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// `NWConnection` reports state and the timeout fires on separate queues.
/// The one-shot guard keeps those callbacks from resuming the continuation
/// twice while remaining explicit about its locking boundary.
nonisolated private final class ConnectionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// The ready-to-paste invite and the plain request a student can hand to an
/// IT administrator. Keeping this text outside the view makes the visible
/// promise testable and keeps Java/Bedrock wording consistent everywhere.
nonisolated enum NetworkInvite {
    static func text(serverName: String, address: String, serverType: ServerType, mcVersion: String?, worksAnywhere: Bool) -> String {
        let game: String
        if serverType.isBedrock {
            let port = address.split(separator: ":").last.map(String.init) ?? "19132"
            game = "Minecraft Bedrock (port \(port))"
        } else if let mcVersion, !mcVersion.isEmpty {
            game = "Minecraft Java Edition \(mcVersion)"
        } else {
            game = "Minecraft Java Edition"
        }
        let reach = worksAnywhere
            ? "Works from anywhere while this address is available."
            : "Works when you're on the same Wi-Fi or local network as me."
        return "Join my Minecraft server \"\(serverName)\"!\nAddress: \(address)\nGame: \(game)\n\(reach)\nIn Minecraft: Multiplayer → Add Server → paste the address."
    }

    static func schoolNetworkRequest(port: UInt16, udp: Bool, bothProtocols: Bool = false) -> String {
        let protocolName = bothProtocols ? "TCP and UDP" : (udp ? "UDP" : "TCP")
        return "Could you allow devices on this network to connect to my Mac on \(protocolName) port \(port) for a Minecraft server? Please disable client/AP isolation for this connection if it is enabled. I do not need administrator access or an internet port forward."
    }
}
