import Foundation

/// Everything OMNIServers knows about Bedrock 26.60 networking. Since 26.60 Bedrock clients only speak NetherNet: a TCP
/// sign-in (HTTP signaling) on the Bedrock port, then the game itself over WebRTC on UDP. Sources: GeyserMC's "Preparing
/// for NetherNet" post and system-properties page, and Mojang's NetherNet onboarding guide. The Mac app only runs
/// Bedrock through Geyser (Mojang ships no macOS Bedrock server). Mirrors `BedrockNetwork.cs` on Windows/Linux.
nonisolated enum BedrockNetwork {
    /// Geyser build 1273 (Geyser 2.12.1, 2026-10-26) is the first with Bedrock 26.60 support.
    static let minGeyserBuild = 1273
    /// Geyser system property that turns NetherNet on. It overrides config.yml, so old RakNet configs are fixed too.
    static let geyserTransportFlag = "-DgeyserTransport=nethernet"

    /// JVM args for a server with Geyser: adds `-DgeyserTransport=nethernet` unless the user already chose a transport
    /// (a `-DgeyserTransport` flag of their own, or `transport: both|nethernet` in Geyser's config).
    static func withGeyserFlags(_ jvmArgs: String?, geyserInstalled: Bool, configTransport: String?) -> String? {
        guard geyserInstalled else { return jvmArgs }
        if (jvmArgs ?? "").contains("-DgeyserTransport") { return jvmArgs }
        let t = configTransport?.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "both" || t == "nethernet" { return jvmArgs }
        let trimmed = (jvmArgs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? geyserTransportFlag : "\(trimmed) \(geyserTransportFlag)"
    }

    /// Geyser's one port: TCP for sign-in and UDP for the game, same number.
    static func geyserRules(bedrockPort: Int) -> [PortRule] {
        [PortRule(proto: .both, port: bedrockPort, label: "Bedrock sign-in (TCP) + game (UDP)")]
    }

    /// Port rules that fit this server: Java port plus Geyser's port when Geyser is installed, else nil.
    static func defaultGeyserRules(serverDir: URL, serverType: ServerType) -> [PortRule]? {
        let xp = CrossplayManager.status(serverDir: serverDir, serverType: serverType)
        guard xp.geyser else { return nil }
        return [PortRule(proto: .tcp, port: Int(NetworkInfo.port(serverDir: serverDir)), label: "Java game")]
            + geyserRules(bedrockPort: Int(xp.bedrockPort))
    }

    static func geyserNeedsUpdate(geyserInstalled: Bool, installedBuild: Int?) -> Bool {
        geyserInstalled && (installedBuild == nil || installedBuild! < minGeyserBuild)
    }

    /// Reads `build` and `version` from GeyserMC's build JSON.
    static func parseGeyserBuild(_ json: [String: Any]?) -> (build: Int, version: String)? {
        guard let json, let version = json["version"] as? String else { return nil }
        if let b = json["build"] as? Int { return (b, version) }
        return nil
    }

    /// The address a Bedrock friend types: the public IP and the Bedrock port when known, else the LAN address. Never
    /// the free tunnel's address, which only carries Java (TCP).
    static func bedrockAddress(publicIP: String?, lanIP: String?, port: Int) -> String {
        let pub = publicIP?.trimmingCharacters(in: .whitespaces) ?? ""
        var host = pub.isEmpty ? (lanIP?.trimmingCharacters(in: .whitespaces) ?? "") : pub
        if host.isEmpty { return "" }
        if let i = host.lastIndex(of: ":"), i > host.startIndex, !host.contains("::"), Int(host[host.index(after: i)...]) != nil {
            host = String(host[..<i])
        }
        return "\(host):\(port)"
    }

    /// "TCP 19132 and UDP 19132": what to say to a person about a set of rules.
    static func describe(_ rules: [PortRule]) -> String {
        var seen = Set<String>()
        let parts = PortRules.expand(rules).map { "\($0.proto.label) \($0.port)" }.filter { seen.insert($0).inserted }
        switch parts.count {
        case 0: return "no ports"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }

    /// Only the `bedrock:` section's own keys (port, transport, clone-remote-port); nested blocks such as `signaling:`
    /// are ignored so their `port:` never leaks in.
    static func readBedrockSection(_ lines: [String]) -> (port: Int?, transport: String?, clone: Bool) {
        var port: Int?; var transport: String?; var clone = false
        var inBedrock = false
        var childIndent: Int?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if indent == 0 { inBedrock = trimmed.hasPrefix("bedrock:"); childIndent = nil; continue }
            guard inBedrock else { continue }
            if childIndent == nil { childIndent = indent }
            guard indent == childIndent, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "port": port = Int(value)
            case "transport": transport = value.isEmpty ? nil : value
            case "clone-remote-port": clone = value.lowercased() == "true"
            default: break
            }
        }
        return (port, transport, clone)
    }

    static let tunnelNote = "The free tunnel can't carry Bedrock: Bedrock 26.60 needs a TCP sign-in plus a UDP game connection, and the tunnel only carries TCP. For friends outside your home, forward TCP and UDP on your router."
    static let trustPromptNote = "Players see a one-time “trust this server” question the first time they join by IP address."
}
