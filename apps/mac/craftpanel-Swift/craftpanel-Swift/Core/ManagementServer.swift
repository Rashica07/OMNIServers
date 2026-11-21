import Foundation
import Darwin

/// The native Minecraft **Management Server** (JSON-RPC over WebSocket),
/// added in MC 1.21.9 / the 26.x line. Direct port of `mgmt.rs`: doesn't
/// speak the full protocol yet — detects support, reports config, and
/// can turn it on, writing only `management-server-*` keys,
/// line-preserving, never touching `online-mode` — same hard constraint
/// every `Properties` write in this app follows.
nonisolated struct MgmtStatus: Sendable, Equatable {
    /// this MC version ships the management server
    var supported: Bool
    var enabled: Bool
    var host: String
    var port: UInt16
    var tls: Bool
    var secretSet: Bool
    /// the port is actually accepting connections
    var reachable: Bool
}

nonisolated enum ManagementServer {
    /// MC 1.21.9+ or the 26.x year scheme.
    static func supports(_ mcVersion: String?) -> Bool {
        guard let v = mcVersion else { return false }
        let parts = v.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { UInt32($0) }
        guard let major = parts.first else { return false }
        if major >= 22, major <= 99 { return true } // year scheme (26.x …)
        if parts.count >= 3, parts[0] == 1, parts[1] == 21 { return parts[2] >= 9 }
        if parts.count >= 2, parts[0] == 1 { return parts[1] >= 22 }
        return false
    }

    /// Loopback TCP probe with a 300 ms bound — plain non-blocking
    /// `connect` + `poll` (the old NWConnection version mutated a captured
    /// var from another queue and force-unwrapped the port).
    static func portOpen(_ port: UInt16) -> Bool {
        guard port != 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 300) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    static func status(serverDir: URL, mcVersion: String?) -> MgmtStatus {
        let p = Properties.load(dir: serverDir)
        let port = UInt16(p.getOr("management-server-port", "0")) ?? 0
        return MgmtStatus(
            supported: supports(mcVersion),
            enabled: p.getOr("management-server-enabled", "false") == "true" && port != 0,
            host: p.getOr("management-server-host", "localhost"),
            port: port,
            tls: p.getOr("management-server-tls-enabled", "false") == "true",
            secretSet: !(p.get("management-server-secret") ?? "").isEmpty,
            reachable: portOpen(port)
        )
    }

    /// Turn the management server on. Writes only `management-server-*` keys.
    static func enable(serverDir: URL, preferredPort: UInt16) throws -> MgmtStatus {
        var p = Properties.load(dir: serverDir)
        guard p.existed else {
            throw RconServiceError.message("Start the server once so it writes server.properties first.")
        }
        p.set("management-server-enabled", "true")
        p.set("management-server-host", "localhost")
        let cur = UInt16(p.getOr("management-server-port", "0")) ?? 0
        if cur == 0 {
            p.set("management-server-port", String(preferredPort))
        }
        if (p.get("management-server-secret") ?? "").isEmpty {
            p.set("management-server-secret", genSecret())
        }
        // keep it local-only; TLS off is fine for a loopback socket
        if p.get("management-server-tls-enabled") == nil {
            p.set("management-server-tls-enabled", "false")
        }
        try p.save()
        return status(serverDir: serverDir, mcVersion: nil)
    }

    static func disable(serverDir: URL) throws {
        var p = Properties.load(dir: serverDir)
        p.set("management-server-enabled", "false")
        try p.save()
    }

    private static func genSecret() -> String {
        let a = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let b = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String((a + b).prefix(40))
    }
}
