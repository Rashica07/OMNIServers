import Foundation
import Darwin

nonisolated enum PortProtocol: String, Codable, Sendable, CaseIterable { case tcp, udp, both
    var label: String { switch self { case .tcp: "TCP"; case .udp: "UDP"; case .both: "TCP + UDP" } }
}

/// One port a server needs open. `.both` means the same number for TCP and UDP.
nonisolated struct PortRule: Codable, Equatable, Hashable, Sendable {
    var proto: PortProtocol
    var port: Int
    var label: String = ""
}

nonisolated struct PortPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var note: String
    var rules: [PortRule]
    var builtIn: Bool = true
}

nonisolated struct RuleIssue: Equatable, Sendable {
    enum Level: Sendable { case error, warning }
    let level: Level
    let message: String
}

/// Port rules and game presets. This is OMNIServers' own list of what a server needs; the macOS firewall (per app),
/// the router (UPnP) and tunnels are separate layers that change only when you set them up.
nonisolated enum PortRules {
    static let builtIn: [PortPreset] = [
        PortPreset(id: "minecraft-java", name: "Minecraft Java", note: "The default Java server port.", rules: [PortRule(proto: .tcp, port: 25565, label: "Game")]),
        PortPreset(id: "minecraft-bedrock", name: "Minecraft Bedrock", note: "Bedrock 26.60 signs in over TCP and plays over UDP, both on the same port. The free tunnel can't carry it.",
                   rules: [PortRule(proto: .both, port: 19132, label: "Sign-in (TCP) + game (UDP)")]),
        PortPreset(id: "minecraft-geyser", name: "Bedrock on Java (Geyser)", note: "Java players on the Java port; Bedrock players on Geyser's port over TCP and UDP.",
                   rules: [PortRule(proto: .tcp, port: 25565, label: "Java game"), PortRule(proto: .both, port: 19132, label: "Bedrock sign-in (TCP) + game (UDP)")]),
        PortPreset(id: "fivem", name: "FiveM", note: "The standard FiveM game endpoint.", rules: [PortRule(proto: .both, port: 30120, label: "Game")]),
        PortPreset(id: "cs2", name: "Counter-Strike 2", note: "Dedicated server default. Check your launch options if you changed the port.", rules: [PortRule(proto: .both, port: 27015, label: "Game and query")]),
        PortPreset(id: "terraria", name: "Terraria", note: "Default multiplayer port.", rules: [PortRule(proto: .tcp, port: 7777, label: "Game")]),
        PortPreset(id: "ark-sa", name: "ARK: Survival Ascended", note: "Common defaults. ARK setups vary, so check your launch settings.",
                   rules: [PortRule(proto: .udp, port: 7777, label: "Game"), PortRule(proto: .udp, port: 7778, label: "Raw UDP"), PortRule(proto: .udp, port: 27015, label: "Query")]),
        PortPreset(id: "custom", name: "Custom", note: "Start empty and add your own TCP or UDP ports.", rules: []),
    ]

    static let adminPorts: [Int: String] = [
        22: "SSH remote login", 23: "Telnet", 3389: "Windows Remote Desktop", 5900: "VNC remote screen", 445: "Windows file sharing",
        25575: "Minecraft RCON, the remote console", 3306: "a MySQL database", 5432: "a PostgreSQL database", 6379: "a Redis database", 27017: "a MongoDB database",
    ]

    /// Every concrete (protocol, port) pair, with `.both` split into TCP and UDP.
    static func expand(_ rules: [PortRule]) -> [(proto: PortProtocol, port: Int)] {
        rules.flatMap { r -> [(PortProtocol, Int)] in
            switch r.proto { case .tcp: [(.tcp, r.port)]; case .udp: [(.udp, r.port)]; case .both: [(.tcp, r.port), (.udp, r.port)] }
        }
    }

    static func validate(_ rules: [PortRule]) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        for r in rules where !(1...65535).contains(r.port) {
            issues.append(RuleIssue(level: .error, message: "\(r.port) isn't a valid port. Use a number from 1 to 65535."))
        }
        var seen = Set<String>()
        for p in expand(rules.filter { (1...65535).contains($0.port) }) {
            if !seen.insert("\(p.proto.rawValue)\(p.port)").inserted {
                issues.append(RuleIssue(level: .error, message: "\(p.proto.label) \(p.port) is listed twice."))
            }
        }
        var warned = Set<Int>()
        for r in rules where warned.insert(r.port).inserted {
            if let what = adminPorts[r.port] {
                issues.append(RuleIssue(level: .warning, message: "Port \(r.port) is \(what). Opening it to the internet lets anyone try to log in. Keep it closed unless you need it, and use a strong password."))
            }
        }
        return issues
    }

    static func findConflicts(_ rules: [PortRule], portsOfOtherServers: Set<Int>, isFree: (PortProtocol, Int) -> Bool = portFree) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        var seen = Set<String>()
        for p in expand(rules.filter { (1...65535).contains($0.port) }) where seen.insert("\(p.proto.rawValue)\(p.port)").inserted {
            if portsOfOtherServers.contains(p.port) {
                issues.append(RuleIssue(level: .warning, message: "Another OMNIServers server already uses port \(p.port)."))
            } else if !isFree(p.proto, p.port) {
                issues.append(RuleIssue(level: .warning, message: "\(p.proto.label) \(p.port) is already in use by another program on this Mac."))
            }
        }
        return issues
    }

    /// Plain list to paste to whoever runs the router or network.
    static func summary(name: String, rules: [PortRule]) -> String {
        "Please allow these inbound ports to my Mac for \(name):\n" + expand(rules).map { "- \($0.proto.label) \($0.port)" }.joined(separator: "\n")
    }

    /// Can we bind this port for this protocol right now?
    static func portFree(_ proto: PortProtocol, _ port: Int) -> Bool {
        let type = proto == .udp ? SOCK_DGRAM : SOCK_STREAM
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return rc == 0
    }

    // MARK: saved custom presets

    static func loadSaved(_ file: URL) -> [PortPreset] {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([PortPreset].self, from: data) else { return [] }
        return list.map { var p = $0; p.builtIn = false; return p }
    }

    static func save(_ file: URL, _ presets: [PortPreset]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(presets.filter { !$0.builtIn }) { try? data.write(to: file) }
    }

    static var savedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "CraftPanel/port-presets.json")
    }
}
